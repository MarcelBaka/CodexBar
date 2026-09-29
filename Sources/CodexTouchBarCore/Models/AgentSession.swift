import Foundation

public enum AgentStatus: String, CaseIterable, Codable {
    case idle, working, waiting, completed, error, unknown
    public var title: String {
        switch self {
        case .idle: return "Ready"
        case .working: return "Working"
        case .waiting: return "Needs your attention"
        case .completed: return "Completed"
        case .error: return "Error"
        case .unknown: return "Activity unconfirmed"
        }
    }
    public var priority: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .error: return 2
        case .completed: return 3
        case .unknown: return 4
        case .idle: return 5
        }
    }
}

public enum SessionSource: String, Codable {
    case rollout, hooks, rolloutWithHooks, demo
    public var title: String {
        switch self {
        case .rollout: return "Local session"
        case .hooks: return "Lifecycle hooks"
        case .rolloutWithHooks: return "Local session + hooks"
        case .demo: return "Demo · simulated data"
        }
    }
}

public struct PlanStep: Identifiable, Equatable, Codable {
    public enum Status: String, Codable { case pending, inProgress, completed }
    public var id: String
    public var title: String
    public var status: Status
    public init(id: String = UUID().uuidString, title: String, status: Status = .pending) {
        self.id = id; self.title = title; self.status = status
    }
}

public struct ToolActivity: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var detail: String?
    public var timestamp: Date
    public var completed: Bool
    public var succeeded: Bool?
    public init(id: String, name: String, detail: String? = nil, timestamp: Date, completed: Bool = false, succeeded: Bool? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.timestamp = timestamp
        self.completed = completed; self.succeeded = succeeded
    }
}

public struct UsageLimit: Identifiable, Equatable {
    public var id: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?
    public init(id: String, usedPercent: Double, windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id; self.usedPercent = usedPercent; self.windowMinutes = windowMinutes; self.resetsAt = resetsAt
    }
}

public struct AgentSession: Identifiable, Equatable {
    public var id: String
    public var projectPath: String = ""
    public var branch: String?
    public var model: String?
    public var source: SessionSource = .rollout
    public var status: AgentStatus = .idle
    public var activity: String = "Waiting for a task"
    public var taskTitle: String?
    public var sessionStartedAt: Date?
    public var startedAt: Date?
    public var endedAt: Date?
    public var updatedAt: Date = .distantPast
    public var activityUpdatedAt: Date = .distantPast
    public var turnID: String?
    public var steps: [PlanStep] = []
    public var tools: [ToolActivity] = []
    public var toolCallCount: Int = 0
    public var changedFiles: [String] = []
    public var lastError: String?
    public var contextUsedTokens: Int?
    public var contextWindow: Int?
    public var totalTokens: Int?
    public var rateLimits: [UsageLimit] = []
    public var hasApprovalHooks: Bool = false
    public var isStale: Bool = false
    public var transcriptPath: String?
    public var isSubagent: Bool = false
    public init(id: String) { self.id = id }
    public var projectName: String {
        projectPath.isEmpty ? "Codex session" : URL(fileURLWithPath: projectPath).lastPathComponent
    }
    public var completedSteps: Int { steps.filter { $0.status == .completed }.count }
    public var progressFraction: Double? {
        steps.isEmpty ? nil : Double(completedSteps) / Double(steps.count)
    }
    public var contextFraction: Double? {
        guard let used = contextUsedTokens, let window = contextWindow, window > 0, used >= 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
    public var displayStatus: AgentStatus {
        isStale && (status == .working || status == .waiting) ? .unknown : status
    }
    public func elapsed(at now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt else { return nil }
        return max(0, (endedAt ?? now).timeIntervalSince(start))
    }
    public static func durationText(_ interval: TimeInterval?) -> String {
        guard let interval = interval, interval.isFinite, interval < Double(Int.max) else { return "—" }
        let seconds = max(0, Int(interval))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
