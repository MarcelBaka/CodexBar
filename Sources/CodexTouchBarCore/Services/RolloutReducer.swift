import Foundation

/// Internal rollout format is deliberately contained here; unknown records are ignored.
public struct RolloutReducer {
    public private(set) var session: AgentSession
    private var seenCalls = Set<String>()
    private var pendingQuestion: String?
    private var activeTurn: String?
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let ordinary = ISO8601DateFormatter()

    public init(id: String) { session = AgentSession(id: id) }
    public static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? ordinary.date(from: text)
    }
    public mutating func consume(_ data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        consume(record)
    }
    public mutating func consume(_ record: [String: Any]) {
        guard let type = record["type"] as? String, let p = record["payload"] as? [String: Any] else { return }
        let time = Self.date(record["timestamp"]) ?? session.updatedAt
        // Forked rollouts can include a copy of the parent's earlier transcript after their own header.
        // Keep the child's identity and do not replay pre-creation parent activity into its state.
        if type != "session_meta", let created = session.sessionStartedAt, time < created { return }
        switch type {
        case "session_meta":
            if let id = p["id"] as? String {
                if session.sessionStartedAt != nil && session.id != id { return }
                session.id = id
            }
            session.projectPath = p["cwd"] as? String ?? session.projectPath
            session.sessionStartedAt = session.sessionStartedAt ?? Self.date(p["timestamp"]) ?? time
            session.branch = (p["git"] as? [String: Any])?["branch"] as? String ?? session.branch
            session.contextWindow = p["context_window"] as? Int ?? session.contextWindow
            if let source = p["source"] as? [String: Any], source["subagent"] != nil { session.isSubagent = true }
            session.updatedAt = max(time, session.updatedAt)
        case "turn_context":
            session.projectPath = p["cwd"] as? String ?? session.projectPath
            session.model = p["model"] as? String ?? session.model
        case "event_msg": event(p, at: time)
        case "response_item": response(p, at: time)
        case "codex_touchbar_hook": hook(p, at: time)
        default: break
        }
    }
    private mutating func begin(_ time: Date, turn: String?) {
        if let turn = turn, turn == activeTurn { return }
        activeTurn = turn
        session.turnID = turn; session.startedAt = time; session.endedAt = nil
        session.steps = []; session.tools = []; session.toolCallCount = 0; seenCalls = []
        session.changedFiles = []; session.lastError = nil; pendingQuestion = nil
        session.taskTitle = nil; session.status = .working; session.activity = "Starting task"
        session.isStale = false; session.updatedAt = time; session.activityUpdatedAt = time
    }
    private mutating func touch(_ time: Date, activity: String? = nil) {
        guard time >= session.updatedAt else { return }
        session.updatedAt = time; session.activityUpdatedAt = time; session.isStale = false
        if session.status != .completed && session.status != .idle {
            session.status = pendingQuestion == nil ? .working : .waiting
        }
        if let activity = activity { session.activity = activity }
    }
    private mutating func event(_ p: [String: Any], at time: Date) {
        guard let kind = p["type"] as? String else { return }
        switch kind {
        case "task_started", "turn_started":
            begin(time, turn: p["turn_id"] as? String)
            session.contextWindow = p["model_context_window"] as? Int ?? session.contextWindow
        case "task_complete", "turn_complete":
            if let turn = p["turn_id"] as? String, let current = session.turnID, turn != current { return }
            guard time >= session.updatedAt else { return }
            session.endedAt = time; session.updatedAt = time; session.activityUpdatedAt = time; pendingQuestion = nil
            if let error = p["error"], !(error is NSNull) {
                session.status = .error; session.lastError = Self.errorMessage(error); session.activity = session.lastError ?? "Task failed"
            } else { session.status = .completed; session.activity = "Task completed" }
        case "turn_aborted":
            if let turn = p["turn_id"] as? String, let current = session.turnID, turn != current { return }
            session.status = .idle; session.activity = "Task interrupted"; session.endedAt = time
            session.updatedAt = time; session.activityUpdatedAt = time; pendingQuestion = nil
        case "user_message":
            session.taskTitle = (p["message"] as? String).map { Self.short($0, 200) }
            touch(time)
        case "agent_message":
            touch(time)
            if let message = p["message"] as? String, p["phase"] as? String == "commentary" {
                session.activity = Self.short(message, 180)
            }
        case "token_count":
            if let info = p["info"] as? [String: Any] {
                session.contextWindow = info["model_context_window"] as? Int ?? session.contextWindow
                session.contextUsedTokens = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int ?? session.contextUsedTokens
                session.totalTokens = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int ?? session.totalTokens
            }
            if let limits = p["rate_limits"] as? [String: Any] {
                session.rateLimits = ["primary", "secondary"].compactMap { key in
                    guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double, used.isFinite, (0...100).contains(used) else { return nil }
                    return UsageLimit(id: key, usedPercent: used, windowMinutes: window["window_minutes"] as? Int,
                                      resetsAt: (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
                }
            }
            // Token updates do not prove that a pending question/approval was resolved.
            session.updatedAt = max(time, session.updatedAt)
        case "error":
            session.status = .error; session.lastError = Self.errorMessage(p); session.activity = session.lastError ?? "Codex error"
            session.updatedAt = time; session.activityUpdatedAt = time
        case "patch_apply_end":
            if p["success"] as? Bool == true, let changes = p["changes"] as? [String: Any] {
                session.changedFiles = Array(Set(session.changedFiles + changes.keys)).sorted()
            }
            touch(time)
        case "item_completed":
            if let item = p["item"] as? [String: Any] { paginatedItem(item, at: time) }
        default: break
        }
    }
    private mutating func response(_ p: [String: Any], at time: Date) {
        guard let kind = p["type"] as? String else { return }
        switch kind {
        case "function_call", "custom_tool_call":
            let rawName = p["name"] as? String ?? "Tool"
            let name = rawName.split(separator: ".").last.map(String.init) ?? rawName
            let call = p["call_id"] as? String ?? UUID().uuidString
            let raw = p["arguments"] as? String ?? p["input"] as? String ?? ""
            let args = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if name == "update_plan" { readPlan(args) }
            guard seenCalls.insert(call).inserted else { return }
            session.toolCallCount += 1
            let command = args["cmd"] as? String ?? args["command"] as? String
            let detail = command.map { Self.short($0, 500) }
            session.tools.append(ToolActivity(id: call, name: rawName, detail: detail, timestamp: time))
            if session.tools.count > 40 { session.tools.removeFirst(session.tools.count - 40) }
            if session.startedAt == nil { session.startedAt = time }
            session.status = .working
            touch(time, activity: Self.activity(name: name, command: command))
            if name == "request_user_input" {
                pendingQuestion = call; session.status = .waiting; session.activity = "Question requested in Codex"
            }
        case "function_call_output", "custom_tool_call_output":
            let call = p["call_id"] as? String ?? ""
            if let index = session.tools.firstIndex(where: { $0.id == call }) {
                session.tools[index].completed = true
                // Only explicit structured failure is evidence. Text can quote arbitrary failures.
                if let output = p["output"] as? [String: Any], let success = output["success"] as? Bool {
                    session.tools[index].succeeded = success
                    if !success { session.lastError = "Tool reported failure: \(session.tools[index].name)" }
                }
            }
            if pendingQuestion == call { pendingQuestion = nil; session.activity = "Continuing task" }
            touch(time)
        case "message":
            if p["role"] as? String == "user", session.taskTitle == nil,
               let content = p["content"] as? [[String: Any]] {
                session.taskTitle = content.compactMap { $0["text"] as? String }.first.map { Self.short($0, 200) }
            }
            if p["role"] as? String == "assistant" { touch(time) }
        case "web_search_call": touch(time, activity: "Searching the web")
        default: break
        }
    }
    private mutating func paginatedItem(_ p: [String: Any], at time: Date) {
        let kind = (p["type"] as? String ?? "").lowercased().replacingOccurrences(of: "_", with: "")
        if kind == "functioncalloutput" {
            var value = p; value["type"] = "function_call_output"; response(value, at: time)
        } else if kind == "usermessage" { touch(time) }
        // Prose plan items do not encode completed stages; never invent a percentage.
    }
    private mutating func readPlan(_ p: [String: Any]) {
        guard let entries = p["plan"] as? [[String: Any]], !entries.isEmpty, entries.count <= 100 else { return }
        var plan: [PlanStep] = []
        for (index, item) in entries.enumerated() {
            guard let title = item["step"] as? String, let raw = item["status"] as? String else { return }
            let status: PlanStep.Status
            switch raw {
            case "pending": status = .pending
            case "in_progress", "inProgress": status = .inProgress
            case "completed": status = .completed
            default: return
            }
            plan.append(PlanStep(id: String(index), title: Self.short(title, 300), status: status))
        }
        session.steps = plan
    }
    private mutating func hook(_ p: [String: Any], at time: Date) {
        guard let event = p["hook_event_name"] as? String, time >= session.updatedAt else { return }
        if let id = p["session_id"] as? String { session.id = id }
        if session.sessionStartedAt == nil { session.sessionStartedAt = time }
        session.source = session.source == .rollout || session.source == .rolloutWithHooks ? .rolloutWithHooks : .hooks
        session.hasApprovalHooks = true
        session.projectPath = p["cwd"] as? String ?? session.projectPath
        session.model = p["model"] as? String ?? session.model
        switch event {
        case "UserPromptSubmit": begin(time, turn: p["turn_id"] as? String)
        case "PermissionRequest":
            session.status = .waiting; session.activity = "Approval requested in Codex"
        case "PreToolUse":
            session.status = .working; session.activity = "Using \(p["tool_name"] as? String ?? "tool")"
            pendingQuestion = nil
        case "PostToolUse":
            session.status = .working; session.activity = "Continuing task"; pendingQuestion = nil
        case "Stop":
            if session.status != .completed && session.status != .error { session.activity = "Finishing task" }
        case "Interrupt", "SessionEnd":
            if session.status != .completed && session.status != .error {
                session.status = .idle; session.activity = event == "Interrupt" ? "Task interrupted" : "Session ended"
                session.endedAt = time
            }
            pendingQuestion = nil
        default: break
        }
        session.updatedAt = time; session.activityUpdatedAt = time
    }
    public static func short(_ text: String, _ length: Int) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        return clean.count > length ? String(clean.prefix(length)) + "…" : clean
    }
    private static func activity(name: String, command: String?) -> String {
        if name == "update_plan" { return "Updating task plan" }
        if name.contains("apply_patch") { return "Editing files" }
        if let command = command { return "Running: " + short(command, 160) }
        if name == "exec" { return "Running tools" }
        if name.contains("search") { return "Searching" }
        return "Using \(name)"
    }
    private static func errorMessage(_ value: Any) -> String {
        if let text = value as? String { return short(text, 300) }
        if let dict = value as? [String: Any], let message = dict["message"] as? String { return short(message, 300) }
        return "Task reported an error"
    }
}
