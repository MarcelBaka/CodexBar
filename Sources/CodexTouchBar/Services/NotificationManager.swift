import Foundation
import UserNotifications
import CodexTouchBarCore

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var sent = Set<String>()
    var onSelectSession: ((String) -> Void)?
    var onPermission: ((String) -> Void)?
    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    func requestAuthorization() {
        guard available else { onPermission?("Run the .app bundle to enable notifications."); return }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async { self?.onPermission?(granted ? "Notifications enabled" : (error?.localizedDescription ?? "Enable notifications for Codex Touch Bar in System Settings.")) }
        }
    }
    func notify(_ session: AgentSession) {
        guard available, [.completed, .waiting, .error].contains(session.displayStatus), session.source != .demo else { return }
        let key = "\(session.id):\(session.turnID ?? "session"):\(session.status.rawValue)"
        guard sent.insert(key).inserted else { return }
        if sent.count > 1000 { sent = [key] }
        let content = UNMutableNotificationContent()
        content.title = session.status == .waiting ? "Codex · attention requested" : session.status == .error ? "Codex · task error" : "Codex · task completed"
        content.body = session.projectName + (session.status == .completed ? " · Finished in \(AgentSession.durationText(session.elapsed()))" : " · \(session.activity)")
        content.sound = .default
        content.userInfo = ["sessionID": session.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionID"] as? String {
            DispatchQueue.main.async { [weak self] in self?.onSelectSession?(id) }
        }
        completion()
    }
}
