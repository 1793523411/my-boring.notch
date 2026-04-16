import AppKit
import Combine
import SQLite3
import SwiftUI

class AIActivityManager: ObservableObject {
    static let shared = AIActivityManager()
    
    @Published var toolStatuses: [AIToolStatus] = AITool.allCases.map { tool in
        AIToolStatus(tool: tool, isRunning: false, taskState: .idle, currentTask: "", pendingApprovals: 0)
    }
    
    @Published var projects: [AIProject] = []
    @Published var approvalRequests: [AIApprovalRequest] = []
    @Published var conversations: [AIConversation] = []
    
    private var pollTimer: Timer?
    private var isRefreshing = false
    private let bgQueue = DispatchQueue(label: "ai.activity.refresh", qos: .utility)
    
    var totalPendingApprovals: Int {
        approvalRequests.filter { $0.state == .waitingApproval }.count
    }
    
    var hasActiveTools: Bool {
        !projects.isEmpty
    }
    
    var activeToolCount: Int {
        toolStatuses.filter { $0.isRunning }.count
    }
    
    var activeProjectCount: Int {
        projects.filter { $0.isActive }.count
    }

    var totalConversationCount: Int {
        projects.reduce(0) { $0 + $1.conversationCount }
    }

    var totalPendingInteractions: Int {
        projects.reduce(0) { $0 + $1.pendingInteractionCount }
    }
    
    private init() {
        startPolling()
        setupWorkspaceObservers()
    }
    
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshProcessStatuses()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshProcessStatuses()
        }
    }
    
    private func setupWorkspaceObservers() {
        let workspace = NSWorkspace.shared
        
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshProcessStatuses()
        }
        
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshProcessStatuses()
        }
    }
    
    func refreshProcessStatuses() {
        guard !isRefreshing else { return }
        isRefreshing = true
        
        let runningApps = NSWorkspace.shared.runningApplications
        let bundleIds = Set(runningApps.compactMap { $0.bundleIdentifier })
        let appNames = Set(runningApps.compactMap { $0.localizedName })
        let oldStatuses = toolStatuses
        let approvals = approvalRequests
        
        bgQueue.async { [weak self] in
            let cliRunning = Self.detectCLIViaAppleScript()
            
            var statuses = oldStatuses
            for i in statuses.indices {
                let tool = statuses[i].tool
                let bid = tool.bundleIdentifier
                let byBundle = !bid.isEmpty && bundleIds.contains(bid)
                let byApp = tool.processNames.contains { appNames.contains($0) }
                let byCLI = cliRunning.contains(tool)
                
                statuses[i].isRunning = byBundle || byApp || byCLI
                
                if statuses[i].isRunning {
                    statuses[i].taskState = .running
                    statuses[i].currentTask = "Active"
                } else {
                    statuses[i].taskState = .idle
                    statuses[i].currentTask = ""
                }
                
                statuses[i].pendingApprovals = approvals.filter {
                    $0.tool == tool && $0.state == .waitingApproval
                }.count
            }
            
            let result = Self.discoverAllSessions()
            let sessions = result.sessions
            let traeWS = result.traeWorkspaces
            
            var allSessions = sessions
            if allSessions.isEmpty {
                for status in statuses where status.isRunning {
                    let fallbackSession = AISession(
                        tool: status.tool,
                        pid: 0,
                        projectPath: status.tool.rawValue,
                        projectName: status.tool.rawValue,
                        taskState: .running,
                        lastActivity: Date()
                    )
                    allSessions.append(fallbackSession)
                }
            }
            
            var grouped: [String: [AISession]] = [:]
            for s in allSessions {
                let key = s.tool.rawValue + "|" + s.projectPath
                grouped[key, default: []].append(s)
            }
            
            let projects = grouped.map { key, sess -> AIProject in
                let path = sess.first?.projectPath ?? key
                var proj = AIProject(projectPath: path, sessions: sess)
                if let tool = sess.first?.tool, tool == .traeCN,
                   let ws = traeWS[path] {
                    proj.conversationCount = ws.conversationCount
                    if ws.hasPendingDiff {
                        proj.pendingInteractionCount += 1
                    }
                }
                return proj
            }.sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
            }
            
            DispatchQueue.main.async {
                self?.toolStatuses = statuses
                self?.projects = projects
                self?.updateConversations(from: allSessions)
                self?.isRefreshing = false
            }
        }
    }
    
    private static func detectCLIViaAppleScript() -> Set<AITool> {
        let script = """
        tell application "System Events"
            set resultList to {}
            set allProcs to name of every process
            repeat with procName in allProcs
                if procName as text is "claude" then
                    set end of resultList to "claude"
                else if procName as text is "codex" then
                    set end of resultList to "codex"
                end if
            end repeat
            return resultList
        end tell
        """
        let results = runAppleScript(script)
        var tools = Set<AITool>()
        for name in results {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed == "claude" { tools.insert(.claudeCode) }
            else if trimmed == "codex" { tools.insert(.codex) }
        }
        return tools
    }
    
    private static func discoverAllSessions() -> (sessions: [AISession], traeWorkspaces: [String: TraeWorkspaceInfo]) {
        var sessions: [AISession] = []
        let wsInfo = scanTraeWorkspaces()
        discoverEditorSessions(into: &sessions, workspaceInfo: wsInfo)
        let knownPaths = sessions.map { $0.projectPath }
        discoverCLISessions(into: &sessions, knownPaths: knownPaths)
        return (sessions, wsInfo)
    }
    
    private static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    private static func discoverEditorSessions(into sessions: inout [AISession], workspaceInfo: [String: TraeWorkspaceInfo]) {
        let storagePath = realHomeDirectory + "/Library/Application Support/Trae CN/User/globalStorage/storage.json"
        
        guard FileManager.default.fileExists(atPath: storagePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        guard let windowsState = json["windowsState"] as? [String: Any] else { return }
        
        var folderURIs: [String] = []
        
        if let lastActive = windowsState["lastActiveWindow"] as? [String: Any],
           let folder = lastActive["folder"] as? String {
            folderURIs.append(folder)
        }
        
        if let opened = windowsState["openedWindows"] as? [[String: Any]] {
            for win in opened {
                if let folder = win["folder"] as? String {
                    if !folderURIs.contains(folder) {
                        folderURIs.append(folder)
                    }
                }
            }
        }
        
        for uri in folderURIs {
            let path = uri.replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding ?? uri
            let projectName = URL(fileURLWithPath: path).lastPathComponent

            let wsData = workspaceInfo[path]
            let taskState: AITaskState
            if wsData?.isActive == true {
                taskState = .running
            } else if wsData?.hasPendingDiff == true {
                taskState = .waitingApproval
            } else {
                taskState = .idle
            }
            
            let session = AISession(
                tool: .traeCN,
                pid: 0,
                projectPath: path,
                projectName: projectName,
                taskState: taskState,
                lastActivity: Date()
            )
            sessions.append(session)
        }
    }
    
    enum TraeWorkStatus: String {
        case generating = "WORK_STATUS_GENERATING"
        case hasDiff = "WORK_STATUS_HAS_DIFF"
        case idle = ""
    }

    struct TraeWorkspaceInfo {
        let conversationCount: Int
        let workStatus: TraeWorkStatus
        var isActive: Bool { workStatus == .generating }
        var hasPendingDiff: Bool { workStatus == .hasDiff }
    }

    private static func scanTraeWorkspaces() -> [String: TraeWorkspaceInfo] {
        let wsBase = realHomeDirectory + "/Library/Application Support/Trae CN/User/workspaceStorage"
        let fm = FileManager.default
        guard let hashes = try? fm.contentsOfDirectory(atPath: wsBase) else { return [:] }

        var result: [String: TraeWorkspaceInfo] = [:]

        for hash in hashes {
            let wsDir = wsBase + "/" + hash
            let wsJson = wsDir + "/workspace.json"
            let dbPath = wsDir + "/state.vscdb"
            guard fm.fileExists(atPath: wsJson),
                  fm.fileExists(atPath: dbPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: wsJson)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = json["folder"] as? String else { continue }

            let path = folder.replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding ?? folder

            let workStatus = queryTraeWorkStatus(dbPath: dbPath)
            let sessCount = queryTraeSessionCount(dbPath: dbPath)

            result[path] = TraeWorkspaceInfo(
                conversationCount: sessCount,
                workStatus: workStatus
            )
        }
        return result
    }

    private static func queryTraeWorkStatus(dbPath: String) -> TraeWorkStatus {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return .idle }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'workbench.compositebar.builtinPanelWorkStatus';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .idle }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return .idle }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return .idle }
        let value = String(cString: cStr)
        return TraeWorkStatus(rawValue: value) ?? .idle
    }

    private static func queryTraeSessionCount(dbPath: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'memento/icube-ai-agent-storage';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return 0 }
        let jsonStr = String(cString: cStr)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [[String: Any]] else { return 0 }

        return list.count
    }

    private static func discoverCLISessions(into sessions: inout [AISession], knownPaths: [String]) {
        discoverClaudeCodeProjects(into: &sessions, knownPaths: knownPaths)
        discoverCodexProjects(into: &sessions)
    }

    private static func discoverClaudeCodeProjects(into sessions: inout [AISession], knownPaths: [String]) {
        let projectsDir = realHomeDirectory + "/.claude/projects"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        struct CandidateProject {
            let entry: String
            let fullDir: String
            let latestDate: Date
            let latestFile: String?
        }

        var candidates: [CandidateProject] = []

        for entry in entries {
            guard entry.hasPrefix("-") else { continue }
            let fullDir = projectsDir + "/" + entry

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: fullDir) else { continue }
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }
            guard !jsonlFiles.isEmpty else { continue }

            var latestDate = Date.distantPast
            var latestFile: String?
            for file in jsonlFiles {
                let filePath = fullDir + "/" + file
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > latestDate {
                    latestDate = modDate
                    latestFile = filePath
                }
            }
            candidates.append(CandidateProject(entry: entry, fullDir: fullDir, latestDate: latestDate, latestFile: latestFile))
        }

        candidates.sort { $0.latestDate > $1.latestDate }

        let recentThreshold: TimeInterval = 3600
        let selected = candidates.filter { $0.latestDate.timeIntervalSinceNow > -recentThreshold }

        for candidate in selected {
            var projectPath = ""
            var projectName = ""

            if let filePath = candidate.latestFile,
               let fh = FileHandle(forReadingAtPath: filePath) {
                let chunk = fh.readData(ofLength: 4096)
                fh.closeFile()
                if let line = String(data: chunk, encoding: .utf8)?.components(separatedBy: "\n").first,
                   let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cwd = json["cwd"] as? String {
                    projectPath = cwd
                    projectName = URL(fileURLWithPath: cwd).lastPathComponent
                }
            }

            if projectPath.isEmpty {
                projectPath = Self.matchKnownPath(encoded: candidate.entry, knownPaths: knownPaths)
                    ?? Self.decodeCLIProjectPath(candidate.entry)
                projectName = URL(fileURLWithPath: projectPath).lastPathComponent
            }

            let isRecentlyActive = candidate.latestDate.timeIntervalSinceNow > -120

            sessions.append(AISession(
                tool: .claudeCode,
                pid: 0,
                projectPath: projectPath,
                projectName: projectName,
                taskState: isRecentlyActive ? .running : .idle,
                lastActivity: candidate.latestDate
            ))
        }
    }
    
    private static func discoverCodexProjects(into sessions: inout [AISession]) {
        let statePath = realHomeDirectory + "/.codex/.codex-global-state.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let activeRoots = json["active-workspace-roots"] as? [String] ?? []
        let savedRoots = json["electron-saved-workspace-roots"] as? [String] ?? []

        let runningApps = NSWorkspace.shared.runningApplications
        let codexRunning = runningApps.contains { $0.bundleIdentifier == AITool.codex.bundleIdentifier }

        let roots = codexRunning ? (activeRoots.isEmpty ? savedRoots : activeRoots) : []

        for path in roots {
            let projectName = URL(fileURLWithPath: path).lastPathComponent

            sessions.append(AISession(
                tool: .codex,
                pid: 0,
                projectPath: path,
                projectName: projectName,
                taskState: .running,
                lastActivity: Date()
            ))
        }
    }

    private static func matchKnownPath(encoded: String, knownPaths: [String]) -> String? {
        for path in knownPaths {
            let normalized = path.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "_", with: "-")
            if normalized == encoded { return path }
        }
        return nil
    }

    static func decodeCLIProjectPath(_ encoded: String) -> String {
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = stripped.components(separatedBy: "-")
        guard parts.count > 1 else { return "/" + stripped }

        let fm = FileManager.default
        var current = "/" + parts[0]

        for i in 1..<parts.count {
            let seg = parts[i]
            let withSlash = current + "/" + seg
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: withSlash, isDirectory: &isDir) {
                current = withSlash
                continue
            }
            let withUnderscore = current + "_" + seg
            if fm.fileExists(atPath: withUnderscore, isDirectory: &isDir) {
                current = withUnderscore
                continue
            }
            let withDash = current + "-" + seg
            if fm.fileExists(atPath: withDash, isDirectory: &isDir) {
                current = withDash
                continue
            }
            current = withSlash
        }
        return current
    }

    private static func extractProjectName(from windowTitle: String) -> String? {
        if windowTitle.isEmpty || windowTitle == "missing value" { return nil }
        
        let separators = [" — ", " - "]
        for sep in separators {
            let parts = windowTitle.components(separatedBy: sep)
            if parts.count >= 2 {
                return parts.last?.trimmingCharacters(in: .whitespaces)
            }
        }
        
        return windowTitle
    }
    
    private static func runAppleScript(_ script: String) -> [String] {
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        
        guard let result = result else { return [] }
        
        let count = result.numberOfItems
        if result.descriptorType == typeAEList && count > 0 {
            var items: [String] = []
            for i in 1...count {
                if let item = result.atIndex(i)?.stringValue {
                    items.append(item)
                }
            }
            return items
        } else if let stringVal = result.stringValue {
            return [stringVal]
        }
        
        return []
    }
    
    func simulateApprovalRequest(tool: AITool, projectName: String, summary: String, detail: String) {
        let request = AIApprovalRequest(
            tool: tool,
            projectName: projectName,
            summary: summary,
            detail: detail,
            timestamp: Date(),
            state: .waitingApproval
        )
        approvalRequests.insert(request, at: 0)
    }
    
    func approveRequest(_ request: AIApprovalRequest) {
        guard let index = approvalRequests.firstIndex(where: { $0.id == request.id }) else { return }
        approvalRequests[index].state = .approved
    }
    
    func rejectRequest(_ request: AIApprovalRequest) {
        guard let index = approvalRequests.firstIndex(where: { $0.id == request.id }) else { return }
        approvalRequests[index].state = .rejected
    }
    
    func clearCompletedRequests() {
        approvalRequests.removeAll { $0.state == .approved || $0.state == .rejected }
    }
    
    private func updateConversations(from sessions: [AISession]) {
        var updated = conversations
        
        for session in sessions {
            let convId = "\(session.tool.rawValue)-\(session.projectPath)"
            if let idx = updated.firstIndex(where: { $0.id == convId }) {
                updated[idx].isActive = session.taskState == .running
            } else {
                let conv = AIConversation(
                    id: convId,
                    tool: session.tool,
                    projectName: session.projectName,
                    projectPath: session.projectPath,
                    title: session.projectName,
                    lastMessage: "Active session",
                    timestamp: session.lastActivity,
                    messageCount: 0,
                    isActive: session.taskState == .running
                )
                updated.insert(conv, at: 0)
            }
        }
        
        let activePaths = Set(sessions.map { "\($0.tool.rawValue)-\($0.projectPath)" })
        for i in updated.indices {
            if !activePaths.contains(updated[i].id) {
                updated[i].isActive = false
            }
        }
        
        conversations = updated.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.timestamp > b.timestamp
        }
    }
    
    func conversations(for projectPath: String) -> [AIConversation] {
        conversations.filter { $0.projectPath == projectPath }
    }
    
    deinit {
        pollTimer?.invalidate()
    }
}
