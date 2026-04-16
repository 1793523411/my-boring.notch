import SwiftUI

struct AIStatusView: View {
    @ObservedObject var aiManager = AIActivityManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if !aiManager.projects.isEmpty {
                statsBar
            }

            if aiManager.totalPendingApprovals > 0 {
                approvalBanner
            }

            if aiManager.projects.isEmpty {
                emptyState
            } else {
                projectGrid
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var statsBar: some View {
        let generatingCount = aiManager.projects.filter { $0.sessions.contains { $0.taskState == .running } }.count
        let totalCount = aiManager.projects.count
        let pendingCount = aiManager.totalPendingInteractions
        return HStack(spacing: 12) {
            if generatingCount > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: .green)
                    Text("\(generatingCount) 对话进行中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                }
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text("\(totalCount) projects")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }

            if pendingCount > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: .yellow)
                    Text("\(pendingCount) 待交互")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.yellow)
                }
            }

            if aiManager.totalPendingApprovals > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: .orange)
                    Text("\(aiManager.totalPendingApprovals) pending")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                }
            }

            Spacer()
        }
        .padding(.bottom, 6)
    }

    private var approvalBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text("\(aiManager.totalPendingApprovals) pending approval\(aiManager.totalPendingApprovals > 1 ? "s" : "")")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.1)))
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundColor(.gray.opacity(0.25))
            Text("No AI tools running")
                .font(.system(size: 11))
                .foregroundColor(.gray.opacity(0.3))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var projectGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            ForEach(aiManager.projects) { project in
                ProjectCard(project: project) {
                    openProject(project)
                }
            }
        }
    }

    private func openProject(_ project: AIProject) {
        guard let tool = project.tools.first else { return }

        if tool == .traeCN {
            var components = URLComponents()
            components.scheme = tool.urlScheme
            components.host = "file"
            components.path = project.projectPath
            if let url = components.url {
                NSWorkspace.shared.open(url)
                return
            }
        }

        if tool == .claudeCode {
            var components = URLComponents()
            components.scheme = AITool.traeCN.urlScheme
            components.host = "file"
            components.path = project.projectPath
            if let url = components.url {
                NSWorkspace.shared.open(url)
                return
            }
        }

        let bid = tool.bundleIdentifier
        guard !bid.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
    }
}

struct ProjectCard: View {
    let project: AIProject
    let onTap: () -> Void

    private var borderColor: Color {
        if project.sessions.contains(where: { $0.taskState == .running }) {
            return .green.opacity(0.15)
        } else if project.hasWaitingApproval {
            return .yellow.opacity(0.15)
        }
        return .white.opacity(0.06)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    if project.sessions.contains(where: { $0.taskState == .running }) {
                        PulsingDot(color: .green)
                    } else if project.hasWaitingApproval {
                        PulsingDot(color: .yellow)
                    } else {
                        Circle()
                            .fill(.gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                    Text(project.projectName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 4) {
                    ForEach(project.tools, id: \.self) { tool in
                        HStack(spacing: 3) {
                            if let appIcon = tool.appIcon {
                                Image(nsImage: appIcon)
                                    .resizable()
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 8))
                            }
                            Text(tool.rawValue)
                                .font(.system(size: 8))
                        }
                        .foregroundColor(tool.brandColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(tool.brandColor.opacity(0.12))
                        )
                    }

                    if project.conversationCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 6))
                            Text("\(project.conversationCount)")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white.opacity(0.06))
                        )
                    }

                    if project.sessions.contains(where: { $0.taskState == .running }) {
                        HStack(spacing: 2) {
                            PulsingDot(color: .green)
                            Text("生成中")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundColor(.green)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.green.opacity(0.1))
                        )
                    } else if project.hasWaitingApproval {
                        HStack(spacing: 2) {
                            PulsingDot(color: .yellow)
                            Text("待处理")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.yellow.opacity(0.1))
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(ProjectCardButtonStyle())
    }
}

struct ProjectCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .overlay {
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: 1)
                    .frame(width: 9, height: 9)
                    .scaleEffect(isAnimating ? 1.5 : 1.0)
                    .opacity(isAnimating ? 0 : 0.7)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}
