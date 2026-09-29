import AppKit
import SwiftUI
import CodexTouchBarCore

struct TouchStatusView: View {
    @ObservedObject var manager: SessionManager
    let open: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkle").foregroundColor(manager.selected?.displayStatus.color ?? .white)
            Text("Codex").fontWeight(.semibold)
            StatusDot(status: manager.selected?.displayStatus ?? .idle)
            Divider().frame(height: 16)
            Text(manager.selected?.displayStatus.title ?? "Ready").lineLimit(1)
            Text(manager.selected?.activity ?? "Start a task in Codex").foregroundColor(.gray).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let progress = manager.selected?.progressFraction {
                ProgressView(value: progress).tint(.mint).frame(width: 65)
                Text("\(manager.selected?.completedSteps ?? 0)/\(manager.selected?.steps.count ?? 0)").font(.system(size: 11, design: .monospaced))
            } else if manager.selected?.displayStatus == .working {
                ProgressView().controlSize(.small)
            }
            Text(AgentSession.durationText(manager.selected?.elapsed(at: manager.now))).monospacedDigit()
            if manager.currentApproval != nil {
                Button("Review approval") { manager.reviewApproval() }.tint(.orange)
            }
            Button(action: open) { Image(systemName: "arrow.up.forward.app") }.help("Show Floating Bar")
        }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 30).background(Color.black).foregroundColor(.white).preferredColorScheme(.dark)
    }
}

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private let manager: SessionManager
    private let open: () -> Void
    private let itemID = NSTouchBarItem.Identifier("com.codextouchbar.status")
    private var window: NSWindow?
    lazy var bar: NSTouchBar = {
        let bar = NSTouchBar(); bar.delegate = self; bar.defaultItemIdentifiers = [itemID]; return bar
    }()
    init(manager: SessionManager, open: @escaping () -> Void) { self.manager = manager; self.open = open; super.init() }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == itemID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let host = NSHostingView(rootView: TouchStatusView(manager: manager, open: open))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 30); item.view = host
        return item
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Codex Touch Bar"; window.isReleasedWhenClosed = false; window.touchBar = bar
            window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
                TouchStatusView(manager: manager, open: open).frame(height: 40).cornerRadius(8)
                Text("The Touch Bar follows Codex while this app is active. Use the Floating Bar to follow activity in other apps, or on a Mac without a Touch Bar.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }.padding(20).frame(width: 650, height: 160))
            window.center(); self.window = window
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}
