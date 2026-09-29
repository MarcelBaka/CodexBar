import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var approvalUI: Bool { didSet { defaults.set(approvalUI, forKey: "approvalUI") } }
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "pinned") } }
    @Published var autoShow: Bool { didSet { defaults.set(autoShow, forKey: "autoShow") } }
    @Published var autoHide: Bool { didSet { defaults.set(autoHide, forKey: "autoHide") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    @Published var hideDelay: Double { didSet { defaults.set(hideDelay, forKey: "hideDelay") } }
    @Published var showSubagents: Bool { didSet { defaults.set(showSubagents, forKey: "showSubagents") } }
    var savedPanelPosition: (Double, Double)? {
        guard defaults.object(forKey: "panelX") != nil else { return nil }
        return (defaults.double(forKey: "panelX"), defaults.double(forKey: "panelTop"))
    }
    func savePanelPosition(x: Double, top: Double) {
        defaults.set(x, forKey: "panelX"); defaults.set(top, forKey: "panelTop")
    }
    init(ephemeral: Bool = false) {
        defaults = ephemeral ? UserDefaults(suiteName: "CodexTouchBar.Smoke.\(UUID().uuidString)")! : .standard
        defaults.register(defaults: ["pinned": true, "autoShow": true, "autoHide": true, "notifications": false, "appearance": "dark", "hideDelay": 12.0, "showSubagents": false])
        approvalUI = defaults.bool(forKey: "approvalUI")
        pinned = defaults.bool(forKey: "pinned"); autoShow = defaults.bool(forKey: "autoShow")
        autoHide = defaults.bool(forKey: "autoHide"); notifications = defaults.bool(forKey: "notifications")
        appearance = defaults.string(forKey: "appearance") ?? "dark"
        codexPath = defaults.string(forKey: "codexPath") ?? MonitorPaths.codexHome.path
        hideDelay = defaults.double(forKey: "hideDelay"); showSubagents = defaults.bool(forKey: "showSubagents")
    }
}

import CodexTouchBarCore
