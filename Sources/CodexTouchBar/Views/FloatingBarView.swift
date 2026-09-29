import SwiftUI
import AppKit
import CodexTouchBarCore

extension AgentStatus {
    var color: Color {
        switch self {
        case .working: return Color(red: 0.39, green: 0.89, blue: 0.72)
        case .waiting: return .orange
        case .completed: return .green
        case .error: return .red
        case .idle, .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .working: return "sparkles"
        case .waiting: return "exclamationmark.bubble.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "circle.dotted"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Circle().fill(status.color).frame(width: 7, height: 7)
            .shadow(color: status.color.opacity(0.35), radius: status == .working ? 5 : 0)
            .opacity(status == .working && !reduceMotion && pulse ? 0.45 : 1)
            .animation(status == .working && !reduceMotion ? .easeInOut(duration: 1.3).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel(status.title)
    }
}

struct FloatingBarView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: AppSettings
    let expanded: Bool
    let onExpand: () -> Void
    let onHide: () -> Void
    let onSettings: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var status: AgentStatus { manager.selected?.displayStatus ?? .idle }
    private var background: Color { colorScheme == .dark ? Color(red: 0.055, green: 0.062, blue: 0.073) : Color(red: 0.97, green: 0.98, blue: 0.99) }
    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider().opacity(0.4).padding(.horizontal, 20)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 19) {
                        if let session = manager.selected { sessionContent(session) } else { emptyState }
                    }.padding(22)
                }
                footer
            }
        }
        .frame(width: 420, height: expanded ? 590 : 66)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 25 : 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 25 : 24, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .preferredColorScheme(settings.appearance == "system" ? nil : settings.appearance == "light" ? .light : .dark)
    }
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(status.color.opacity(0.11))
                Image(systemName: "sparkle").font(.system(size: 22, weight: .medium)).foregroundColor(status == .idle ? .primary : status.color)
            }.frame(width: 36, height: 36).overlay(WindowDragRegion()).help("Drag to move")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Codex").font(.system(size: 14, weight: .semibold))
                    if manager.demoMode { Text("DEMO").font(.system(size: 8, weight: .bold)).tracking(1).foregroundColor(.secondary) }
                }
                HStack(spacing: 5) {
                    StatusDot(status: status)
                    Text(expanded ? "TOUCH BAR" : manager.selected?.activity ?? "Ready when you are")
                        .font(.system(size: expanded ? 8 : 10, weight: .medium)).tracking(expanded ? 1.6 : 0).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !expanded, let progress = manager.selected?.progressFraction {
                ProgressView(value: progress).progressViewStyle(.linear).tint(status.color).frame(width: 44)
                    .accessibilityLabel("Completed plan steps").accessibilityValue("\(Int(progress * 100)) percent")
            }
            Text(AgentSession.durationText(manager.selected?.elapsed(at: manager.now)))
                .font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.secondary)
                .help("Elapsed time since the observed task start, including waiting")
            Button(action: onExpand) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 28)
            }.buttonStyle(.plain).foregroundColor(.secondary).help(expanded ? "Collapse" : "Expand")
        }
        .padding(.horizontal, 17).frame(height: 66)
        .contentShape(Rectangle()).onTapGesture { onExpand() }
    }
    @ViewBuilder private func sessionContent(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(session.projectName, systemImage: "folder").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                if manager.visibleSessions.count > 1 {
                    Menu {
                        ForEach(manager.visibleSessions) { item in
                            Button("\(item.projectName) · \(item.displayStatus.title)") { manager.select(item.id) }
                        }
                    } label: { Text("\(manager.visibleSessions.count) sessions").font(.system(size: 10)) }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            Text(status.title).font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-0.8)
            Text(session.isStale ? "No recent event. Check Codex for the current state." : session.activity)
                .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if session.status == .waiting && !session.isStale {
                Label(manager.currentApproval == nil ? "Respond in your Codex window" : "Approval ready for review", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.orange).padding(.top, 3)
            }
        }
        if manager.currentApproval != nil {
            Button("Review approval…") { manager.reviewApproval() }.buttonStyle(.borderedProminent).tint(.orange)
        }
        if let fraction = session.progressFraction {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("PLAN PROGRESS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(status.color)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(status.color).frame(width: max(0, geometry.size.width * fraction))
                    }
                }.frame(height: 5)
                HStack {
                    Text("\(session.completedSteps) of \(session.steps.count) steps completed")
                    Spacer()
                    Text("\(session.steps.count - session.completedSteps) remaining")
                }.font(.system(size: 10)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(session.steps) { step in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: step.status == .completed ? "checkmark.circle.fill" : step.status == .inProgress ? "circle.inset.filled" : "circle")
                            .font(.system(size: 13)).foregroundColor(step.status == .pending ? .secondary.opacity(0.4) : status.color)
                            .frame(width: 15, height: 16)
                        Text(step.title).font(.system(size: 12, weight: step.status == .inProgress ? .medium : .regular))
                            .foregroundColor(step.status == .pending ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if step.status == .inProgress { Text("NOW").font(.system(size: 8, weight: .bold)).tracking(1).foregroundColor(status.color).padding(.top, 3) }
                    }.accessibilityElement(children: .combine).accessibilityLabel("\(step.title), \(step.status.rawValue)")
                }
            }
        } else {
            HStack(spacing: 10) {
                if status == .working { ProgressView().controlSize(.small) }
                else { Image(systemName: status.symbol).foregroundColor(status.color) }
                Text(status == .completed ? "Task finished" : "Following activity")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("No structured plan").font(.system(size: 10)).foregroundColor(.secondary)
            }.padding(13).background(Color.primary.opacity(0.04)).cornerRadius(12)
        }
        Divider().opacity(0.5)
        VStack(spacing: 8) {
            if let branch = manager.git?.branch ?? session.branch { metadata("Branch", branch, icon: "arrow.triangle.branch") }
            if let model = session.model { metadata("Model", model, icon: "cpu") }
            metadata("Tool calls this turn", "\(session.toolCallCount)", icon: "terminal")
            if let started = session.sessionStartedAt {
                metadata("Session age", AgentSession.durationText(manager.now.timeIntervalSince(started)), icon: "clock")
            }
            if let context = session.contextFraction {
                metadata("Context · raw estimate", "\(Int((context * 100).rounded()))%", icon: "circle.lefthalf.filled")
            }
            if let git = manager.git {
                metadata("Worktree changes", "\(git.changedFiles) files" + (git.linesAdded.flatMap { added in git.linesRemoved.map { " · +\(added) / −\($0)" } } ?? " · lines unavailable"), icon: "doc.badge.gearshape")
                if git.untrackedFiles > 0 { Text("Includes \(git.untrackedFiles) untracked entries; line totals cover tracked text.").font(.system(size: 9)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            } else if !session.changedFiles.isEmpty { metadata("Observed changed files", "\(session.changedFiles.count)", icon: "doc") }
            ForEach(session.rateLimits) { limit in
                metadata(limit.windowMinutes.map { "Usage · \($0) min window" } ?? "Usage · \(limit.id)", "\(Int(limit.usedPercent))% used", icon: "gauge")
            }
        }
        if let tool = session.tools.last {
            VStack(alignment: .leading, spacing: 6) {
                Text("LATEST TOOL").font(.system(size: 8, weight: .semibold)).tracking(1.3).foregroundColor(.secondary)
                Text(tool.detail ?? tool.name).font(.system(size: 10, design: .monospaced)).lineLimit(3).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.035)).cornerRadius(10)
        }
        if !session.hasApprovalHooks && session.source != .demo {
            Text("Approval alerts need optional hooks. Configure them in Settings.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        if let diagnostic = manager.diagnostic {
            Text(diagnostic).font(.system(size: 10)).foregroundColor(.secondary)
        }
        Text(session.source.title + " · Updated " + session.updatedAt.formatted(date: .omitted, time: .standard))
            .font(.system(size: 9)).foregroundColor(.secondary)
    }
    private func metadata(_ label: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon).frame(width: 12)
            Text(label)
            Spacer(minLength: 12)
            Text(value).foregroundColor(.primary).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 10)).foregroundColor(.secondary)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A little space\nfor your next big idea.")
                .font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.7)
            Text("Start a task in Codex. Its activity, plan and project will appear here automatically.")
                .font(.system(size: 13)).foregroundColor(.secondary).lineSpacing(5)
            if let diagnostic = manager.diagnostic { Text(diagnostic).font(.system(size: 11)).foregroundColor(.secondary) }
            Button("Try the demo") { manager.setDemo(true) }.buttonStyle(.borderedProminent).tint(.mint)
            Button("Connection settings", action: onSettings).buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
        }.padding(.top, 20).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack(spacing: 17) {
            Button { settings.pinned.toggle() } label: { Image(systemName: settings.pinned ? "pin.fill" : "pin") }.help("Keep above other windows")
            Button(action: onSettings) { Image(systemName: "slider.horizontal.3") }.help("Settings")
            Spacer()
            if manager.demoMode {
                Button("End demo") { manager.setDemo(false) }.font(.system(size: 10))
            } else if let session = manager.selected, !session.projectPath.isEmpty {
                Button("Open project") { NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath)) }.font(.system(size: 10))
            }
            Button(action: onHide) { Image(systemName: "xmark") }.help("Hide Floating Bar")
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
            .padding(.horizontal, 23).frame(height: 44).background(Color.primary.opacity(0.025))
    }
}

/// A dedicated AppKit drag surface keeps movement reliable inside a SwiftUI hosting view.
private struct WindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}
