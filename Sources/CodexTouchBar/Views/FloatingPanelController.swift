import AppKit
import SwiftUI
import Combine
import CodexTouchBarCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FloatingPanelController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel
    private let manager: SessionManager
    private let settings: AppSettings
    private var hosting: NSHostingView<FloatingBarView>!
    private var subscriptions = Set<AnyCancellable>()
    private(set) var expanded = false
    var onSettings: (() -> Void)?
    private var hideWork: DispatchWorkItem?
    init(manager: SessionManager, settings: AppSettings) {
        self.manager = manager; self.settings = settings
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 66), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = settings.pinned ? .floating : .normal
        hosting = NSHostingView(rootView: makeView()); panel.contentView = hosting
        if let screen = NSScreen.main {
            let saved = settings.savedPanelPosition
            let x = CGFloat(saved?.0 ?? Double(screen.visibleFrame.midX - 210))
            let y = CGFloat(saved?.1 ?? Double(screen.visibleFrame.maxY - 24)) - 66
            panel.setFrameOrigin(NSPoint(x: max(screen.visibleFrame.minX, min(x, screen.visibleFrame.maxX - 420)),
                                         y: max(screen.visibleFrame.minY, min(y, screen.visibleFrame.maxY - 66))))
        }
        settings.$pinned.receive(on: RunLoop.main).sink { [weak self] in self?.panel.level = $0 ? .floating : .normal }.store(in: &subscriptions)
    }
    private func makeView() -> FloatingBarView {
        FloatingBarView(manager: manager, settings: settings, expanded: expanded,
                        onExpand: { [weak self] in self?.toggle() }, onHide: { [weak self] in self?.hide() },
                        onSettings: { [weak self] in self?.onSettings?() })
    }
    func show(expanded: Bool? = nil) {
        hideWork?.cancel()
        if let expanded = expanded, self.expanded != expanded { setExpanded(expanded) }
        panel.orderFrontRegardless()
    }
    func hide() { hideWork?.cancel(); panel.orderOut(nil) }
    func toggle() { setExpanded(!expanded) }
    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        let old = panel.frame
        let height: CGFloat = expanded ? 590 : 66
        var frame = NSRect(x: old.minX, y: old.maxY - height, width: 420, height: height)
        if let screen = panel.screen ?? NSScreen.main {
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - height))
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - frame.width))
        }
        hosting.rootView = makeView()
        panel.setFrame(frame, display: true, animate: false)
    }
    func transition(_ session: AgentSession) {
        if session.displayStatus == .working || session.displayStatus == .waiting {
            hideWork?.cancel()
            if settings.autoShow { show() }
        } else if session.displayStatus == .completed && settings.autoHide {
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if !self.manager.visibleSessions.contains(where: { $0.displayStatus == .working || $0.displayStatus == .waiting }) { self.panel.orderOut(nil) }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.hideDelay, execute: work)
        }
    }
    func windowDidMove(_ notification: Notification) {
        settings.savePanelPosition(x: Double(panel.frame.minX), top: Double(panel.frame.maxY))
    }
    func saveSnapshot(to url: URL) throws {
        panel.displayIfNeeded(); hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
