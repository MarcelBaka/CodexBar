import Foundation

public struct ProviderSnapshot {
    public var sessions: [AgentSession]
    public var diagnostic: String?
    public var isInitial: Bool
    public init(sessions: [AgentSession], diagnostic: String? = nil, isInitial: Bool = false) {
        self.sessions = sessions; self.diagnostic = diagnostic; self.isInitial = isInitial
    }
}

/// Poll on one serial background queue. Providers never mutate views or agent sessions on disk.
public protocol AgentProvider: AnyObject {
    func poll(now: Date) -> ProviderSnapshot
}

public enum MonitorPaths {
    public static var codexHome: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex", isDirectory: true)
    }
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Touch Bar", isDirectory: true)
    }
    public static var hookDirectory: URL { supportDirectory.appendingPathComponent("hooks", isDirectory: true) }
}
