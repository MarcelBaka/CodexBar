import SwiftUI
import AppKit
import ServiceManagement
import CodexTouchBarCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: SessionManager
    @State private var hookStatus = "Optional. Requires a Codex version with lifecycle hooks."
    @State private var installing = false
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginMessage = ""
    let onReload: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle").font(.system(size: 30)).foregroundColor(.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Codex Touch Bar").font(.title2).fontWeight(.semibold)
                        Text("A quiet companion for your work.").foregroundColor(.secondary)
                    }
                }
                GroupBox("Appearance & behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Appearance", selection: $settings.appearance) {
                            Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
                        }.pickerStyle(.segmented)
                        Toggle("Keep Floating Bar above other windows", isOn: $settings.pinned)
                        Toggle("Show automatically when Codex starts working", isOn: $settings.autoShow)
                        Toggle("Hide after a completed task", isOn: $settings.autoHide)
                        HStack {
                            Text("Hide after \(Int(settings.hideDelay)) seconds").foregroundColor(.secondary)
                            Slider(value: $settings.hideDelay, in: 3...60, step: 1).frame(width: 180)
                        }.disabled(!settings.autoHide)
                        Toggle("Show subagent sessions", isOn: $settings.showSubagents)
                    }.padding(10)
                }
                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Codex data folder").fontWeight(.medium)
                        HStack {
                            TextField("~/.codex", text: $settings.codexPath)
                            Button("Browse…") { chooseFolder() }
                            Button("Apply", action: onReload)
                        }
                        Text("Local sessions are detected automatically. No API key or change to your Codex configuration is needed for basic monitoring.")
                            .font(.caption).foregroundColor(.secondary)
                        Divider()
                        Text("Approval alerts").fontWeight(.medium)
                        Text("Optional hooks report approval requests. Installing preserves other hooks and creates a backup.")
                            .font(.caption).foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Review and answer approvals in this app", isOn: $settings.approvalUI)
                            Text("Off by default. Reinstall hooks after changing this option. Review shows the complete tool input before a one-time decision; a closed app or timeout returns control to Codex.").font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            Button("Install hooks") { manageHooks("install") }
                            Button("Remove hooks") { manageHooks("uninstall") }
                        }.disabled(installing)
                        Text(hookStatus).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        Text("After installation, restart Codex and use /hooks to review and trust the observer. Hook support depends on your Codex version.")
                            .font(.caption).foregroundColor(.secondary)
                    }.padding(10)
                }
                GroupBox("Notifications & startup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Notify when completed, waiting, or an error occurs", isOn: $settings.notifications)
                            .onChange(of: settings.notifications) { value in
                                if value { manager.notifications.requestAuthorization() }
                                else { manager.notificationStatus = "Notifications are off" }
                            }
                        Text(manager.notificationStatus).font(.caption).foregroundColor(.secondary)
                        Toggle("Launch at Login", isOn: Binding(get: { login }, set: { value in
                            do {
                                if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                login = SMAppService.mainApp.status == .enabled
                                loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Allow this app in System Settings → General → Login Items." : ""
                            } catch { loginMessage = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                        }))
                        if !loginMessage.isEmpty { Text(loginMessage).font(.caption).foregroundColor(.secondary) }
                    }.padding(10)
                }
                GroupBox("About this connection") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Progress measures completed plan steps, not elapsed time. Missing plans show activity. Git totals cover the whole worktree; context is a raw estimate from the last reported token usage.")
                        Text("No recent events means activity is unconfirmed. The public Touch Bar is available while this app is active; Floating Bar works across apps.")
                        Text("Local telemetry only · No analytics · macOS 13+")
                    }.font(.caption).foregroundColor(.secondary).padding(10)
                }
            }.padding(24)
        }.frame(width: 560, height: 710)
            .preferredColorScheme(settings.appearance == "system" ? nil : settings.appearance == "light" ? .light : .dark)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSString(string: settings.codexPath).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { settings.codexPath = url.path; onReload() }
    }
    private func manageHooks(_ action: String) {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("scripts/manage-hooks.py").path) else {
            hookStatus = "Run the built .app bundle, or use scripts/install-hooks.sh from the source folder."; return
        }
        installing = true
        let path = settings.codexPath, approvalUI = settings.approvalUI
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [resources.appendingPathComponent("scripts/manage-hooks.py").path, action, "--app", Bundle.main.bundleURL.path, "--codex-home", NSString(string: path).expandingTildeInPath] + (approvalUI ? ["--approval-ui"] : [])
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
            var result: String
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                result = String(decoding: data, as: UTF8.self)
                if task.terminationStatus != 0 && result.isEmpty { result = "Could not update hooks. Use the installer script in the source folder." }
            } catch { result = "Python 3 is required for hook installation. Install Apple's Command Line Tools, or merge hooks manually as described in README." }
            DispatchQueue.main.async { hookStatus = result; installing = false }
        }
    }
}
