import AppKit
import Foundation
import SwiftUI

enum AITool: String, CaseIterable, Identifiable {
    case traeCN = "Trae"
    case claudeCode = "Claude Code"
    case codex = "Codex"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .traeCN: return "sparkle"
        case .claudeCode: return "brain.head.profile"
        case .codex: return "terminal"
        }
    }

    var appIcon: NSImage? {
        let bid = bundleIdentifier
        guard !bid.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    
    var brandColor: Color {
        switch self {
        case .traeCN: return .cyan
        case .claudeCode: return .orange
        case .codex: return .green
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .traeCN: return "cn.trae.app"
        case .claudeCode: return ""
        case .codex: return "com.openai.codex"
        }
    }
    
    var processNames: [String] {
        switch self {
        case .traeCN: return ["TRAE CN", "Electron"]
        case .claudeCode: return ["claude"]
        case .codex: return ["codex"]
        }
    }

    var urlScheme: String {
        switch self {
        case .traeCN: return "trae-cn"
        case .claudeCode: return ""
        case .codex: return "codex"
        }
    }
}

enum AITaskState: String {
    case idle = "Idle"
    case running = "Running"
    case waitingApproval = "Waiting Approval"
    case approved = "Approved"
    case rejected = "Rejected"
    case completed = "Completed"
    case error = "Error"
}

struct AISession: Identifiable, Sendable {
    let id = UUID()
    let tool: AITool
    let pid: pid_t
    var projectPath: String
    var projectName: String
    var taskState: AITaskState
    var lastActivity: Date
    
    var timeAgo: String {
        let interval = Date().timeIntervalSince(lastActivity)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

struct AIProject: Identifiable, Sendable {
    let projectPath: String
    var sessions: [AISession]
    var conversationCount: Int = 0
    var pendingInteractionCount: Int = 0
    
    var id: String {
        let toolName = sessions.first?.tool.rawValue ?? ""
        return toolName + "|" + projectPath
    }
    
    var projectName: String {
        sessions.first?.projectName ?? URL(fileURLWithPath: projectPath).lastPathComponent
    }
    
    var tools: [AITool] {
        Array(Set(sessions.map { $0.tool })).sorted { $0.rawValue < $1.rawValue }
    }
    
    var hasWaitingApproval: Bool {
        sessions.contains { $0.taskState == .waitingApproval }
    }
    
    var isActive: Bool {
        sessions.contains { $0.taskState == .running || $0.taskState == .waitingApproval }
    }
}

struct AIApprovalRequest: Identifiable, Sendable {
    let id = UUID()
    let tool: AITool
    let projectName: String
    let summary: String
    let detail: String
    let timestamp: Date
    var state: AITaskState
    
    var timeAgo: String {
        let interval = Date().timeIntervalSince(timestamp)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

struct AIToolStatus: Identifiable, Sendable {
    let tool: AITool
    var isRunning: Bool
    var taskState: AITaskState
    var currentTask: String
    var pendingApprovals: Int
    
    var id: String { tool.id }
}

struct AIConversation: Identifiable, Sendable {
    let id: String
    let tool: AITool
    let projectName: String
    let projectPath: String
    let title: String
    let lastMessage: String
    let timestamp: Date
    var messageCount: Int
    var isActive: Bool
    
    var timeAgo: String {
        let interval = Date().timeIntervalSince(timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
