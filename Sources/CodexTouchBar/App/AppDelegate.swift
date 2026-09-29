import AppKit
import SwiftUI
import Combine
import ServiceManagement
import CodexTouchBarCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private let arguments = CommandLine.arguments
    private(set) var settings: AppSettings!
    private(set) var manager: SessionManager!
    private(set) var floating: FloatingPanelController!
    private var touch: TouchBarController!
    private var isSmoke: Bool { arguments.contains("--smoke-report") || arguments.contains("--snapshot") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = AppSettings(ephemeral: isSmoke)
        if let appearance = value(after: "--appearance") { settings.appearance = appearance }
        manager = SessionManager(settings: settings, approvalDirectory: isSmoke ? FileManager.default.temporaryDirectory.appendingPathComponent("CodexTouchBar-smoke-" + UUID().uuidString) : ApprovalStore.directory)
        floating = FloatingPanelController(manager: manager, settings: settings)
        touch = TouchBarController(manager: manager) { [weak self] in self?.floating.show(expanded: true) }
        floating.panel.touchBar = touch.bar
        floating.onSettings = { [weak self] in self?.showSettings() }
        manager.onReviewApproval = { [weak self] in self?.reviewApproval($0) }
        manager.onTransition = { [weak self] in self?.floating.transition($0) }
        manager.notifications.onSelectSession = { [weak self] id in self?.manager.select(id); self?.floating.show(expanded: true) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Codex Touch Bar")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        manager.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusItem() }.store(in: &subscriptions)
        if arguments.contains("--demo") { manager.setDemo(true) }
        if arguments.contains("--snapshot") { manager.setDemoSnapshot() }
        manager.start()
        if !isSmoke && settings.notifications { manager.notifications.requestAuthorization() }
        floating.show(expanded: arguments.contains("--expanded") || arguments.contains("--snapshot"))
        if isSmoke { runSmoke() }
    }
    func applicationWillTerminate(_ notification: Notification) { manager?.stop() }
    private func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    private func updateStatusItem() {
        let session = manager.selected
        statusItem.button?.toolTip = "Codex Touch Bar · \(session?.displayStatus.title ?? "Ready") · \(session?.projectName ?? "No session")"
        let waiting = manager.visibleSessions.filter { $0.displayStatus == .waiting }.count
        statusItem.button?.title = waiting > 0 ? " \(waiting)!" : ""
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Codex Touch Bar", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        menu.addItem(.separator())
        add("Current session: \(manager.selected?.projectName ?? "None")", to: menu, action: #selector(showCurrent))
        let sessionMenu = NSMenu()
        for session in manager.visibleSessions {
            let item = NSMenuItem(title: "\(session.projectName) · \(session.displayStatus.title)", action: #selector(selectSession(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = session.id; item.state = manager.selectedID == session.id ? .on : .off
            sessionMenu.addItem(item)
        }
        if sessionMenu.items.isEmpty { let item = NSMenuItem(title: "No local sessions", action: nil, keyEquivalent: ""); item.isEnabled = false; sessionMenu.addItem(item) }
        let sessions = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: ""); sessions.submenu = sessionMenu; menu.addItem(sessions)
        menu.addItem(.separator())
        add(floating.panel.isVisible ? "Hide Floating Bar" : "Show Floating Bar", to: menu, action: #selector(toggleFloating))
        add("Show Touch Bar", to: menu, action: #selector(showTouchBar))
        menu.addItem(.separator())
        add("Settings…", to: menu, action: #selector(showSettings), key: ",")
        let login = add("Launch at Login", to: menu, action: #selector(toggleLogin)); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let demo = add("Demo Mode", to: menu, action: #selector(toggleDemo)); demo.state = manager.demoMode ? .on : .off
        menu.addItem(.separator())
        add("Quit Codex Touch Bar", to: menu, action: #selector(quit), key: "q")
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }
    @objc private func showCurrent() { floating.show(expanded: true) }
    @objc private func toggleFloating() { if floating.panel.isVisible { floating.hide() } else { floating.show() } }
    @objc private func showTouchBar() { touch.show() }
    @objc private func toggleDemo() { manager.setDemo(!manager.demoMode); floating.show(expanded: true) }
    @objc private func selectSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { manager.select(id); floating.show(expanded: true) }
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codex Touch Bar · Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, manager: manager, onReload: { [weak self] in self?.manager.reload() }))
            window.touchBar = touch.bar; window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not change Launch at Login"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    private func reviewApproval(_ request: ApprovalRequest) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Review Codex approval"
        alert.informativeText = "Tool: \(request.tool)\nProject: \(request.cwd)\nApprove only this invocation after reviewing its complete input below."
        alert.addButton(withTitle: "Continue in Codex")
        alert.addButton(withTitle: "Deny")
        let approve = alert.addButton(withTitle: "Approve once"); approve.keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.isVerticallyResizable = true
        text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = request.inputJSON
        scroll.documentView = text; alert.accessoryView = scroll
        let approvalPath = manager.approvalDirectory
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        heartbeat.schedule(deadline: .now(), repeating: 1)
        heartbeat.setEventHandler { try? ApprovalStore.heartbeat(directory: approvalPath) }
        heartbeat.resume()
        let result = alert.runModal()
        heartbeat.cancel()
        let decision: ApprovalStore.Decision = result == .alertThirdButtonReturn ? .allow : result == .alertSecondButtonReturn ? .deny : .defer
        do {
            try ApprovalStore.decide(decision, request: request, directory: manager.approvalDirectory)
            manager.approvals.removeAll { $0.id == request.id }
        } catch {
            let expired = NSAlert(); expired.messageText = "This approval is no longer pending"
            expired.informativeText = "No decision was sent. Check the original Codex window."
            expired.runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func runSmoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            do {
                self.menuNeedsUpdate(self.statusItem.menu!)
                let touchItem = self.touch.touchBar(self.touch.bar, makeItemForIdentifier: NSTouchBarItem.Identifier("com.codextouchbar.status"))
                if let path = self.value(after: "--snapshot") {
                    try self.floating.saveSnapshot(to: URL(fileURLWithPath: path))
                }
                // Build all native view hierarchies without sending notifications or modifying login settings.
                self.showSettings(); self.settingsWindow?.displayIfNeeded(); self.settingsWindow?.orderOut(nil)
                self.floating.setExpanded(false); self.floating.setExpanded(true)
                let report: [String: Any] = [
                    "success": true, "menuItems": self.statusItem.menu?.items.count ?? 0,
                    "touchBarItemCreated": touchItem != nil, "sessions": self.manager.sessions.count,
                    "mode": self.manager.demoMode ? "demo" : "live", "status": self.manager.selected?.displayStatus.rawValue ?? "idle",
                    "floatingVisible": self.floating.panel.isVisible,
                    "settingsViewCreated": self.settingsWindow?.contentView != nil,
                    "diagnostic": self.manager.diagnostic ?? ""
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                if let path = self.value(after: "--smoke-report") { try data.write(to: URL(fileURLWithPath: path)) }
                print(String(decoding: data, as: UTF8.self))
                NSApp.terminate(nil)
            } catch { fputs("Native smoke check failed: \(error)\n", stderr); exit(1) }
        }
    }
}
