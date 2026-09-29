import Foundation
import CodexTouchBarCore

var passed = 0
func check(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { fputs("FAIL \(name): \(error)\n", stderr); exit(1) }
}
struct Failure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Assertion failed") throws {
    if try !condition() { throw Failure(description: message) }
}
check("progress only counts completed plan entries") {
    var s = AgentSession(id: "a")
    try expect(s.progressFraction == nil)
    s.steps = [.init(title: "Analysis", status: .completed), .init(title: "Build", status: .inProgress)]
    try expect(s.progressFraction == 0.5)
    s.status = .completed
    try expect(s.progressFraction == 0.5)
}
check("context uses last usage and duration freezes") {
    var s = AgentSession(id: "a")
    s.totalTokens = 99999
    try expect(s.contextFraction == nil)
    s.contextUsedTokens = 25; s.contextWindow = 100
    try expect(s.contextFraction == 0.25)
    s.startedAt = Date(timeIntervalSince1970: 10); s.endedAt = Date(timeIntervalSince1970: 70)
    try expect(s.elapsed() == 60)
    try expect(AgentSession.durationText(s.elapsed()) == "01:00")
}
check("silence cannot imply completion or approval") {
    var s = AgentSession(id: "a"); s.status = .working; s.isStale = true
    try expect(s.displayStatus == .unknown && s.status == .working)
}

let base = Date(timeIntervalSince1970: 1700000000)
let formatter = ISO8601DateFormatter()
func record(_ type: String, _ payload: [String: Any], seconds: Double = 0) -> [String: Any] {
    ["timestamp": formatter.string(from: base.addingTimeInterval(seconds)), "type": type, "payload": payload]
}
func line(_ record: [String: Any]) throws -> Data {
    var d = try JSONSerialization.data(withJSONObject: record); d.append(10); return d
}
func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-touchbar-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}
check("real lifecycle freezes time, rejects old-turn completion, resets plan") {
    var r = RolloutReducer(id: "a")
    r.consume(record("session_meta", ["id": "a", "cwd": "/tmp/Project"]))
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "1"]))
    r.consume(record("response_item", ["type": "function_call", "name": "update_plan", "call_id": "plan", "arguments": "{\"plan\":[{\"step\":\"Analyze\",\"status\":\"completed\"},{\"step\":\"Test\",\"status\":\"in_progress\"}]}"], seconds: 2))
    try expect(r.session.progressFraction == 0.5)
    r.consume(record("event_msg", ["type": "task_complete", "turn_id": "1"], seconds: 10))
    try expect(r.session.status == .completed && r.session.elapsed() == 10)
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "2"], seconds: 20))
    r.consume(record("event_msg", ["type": "task_complete", "turn_id": "1"], seconds: 21))
    try expect(r.session.status == .working && r.session.steps.isEmpty && r.session.endedAt == nil)
}
check("explicit question waits only until matching call output") {
    var r = RolloutReducer(id: "a")
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "1"]))
    r.consume(record("response_item", ["type": "function_call", "name": "request_user_input", "call_id": "q", "arguments": "{}"], seconds: 1))
    try expect(r.session.status == .waiting)
    r.consume(record("response_item", ["type": "function_call_output", "call_id": "another", "output": "ok"], seconds: 2))
    try expect(r.session.status == .waiting)
    r.consume(record("response_item", ["type": "function_call_output", "call_id": "q", "output": "ok"], seconds: 3))
    try expect(r.session.status == .working)
}
check("tool IDs deduplicate and recorded commands are not executed") {
    var r = RolloutReducer(id: "a")
    let call = record("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c", "arguments": "{\"cmd\":\"touch /never-run-from-telemetry\"}"])
    r.consume(call); r.consume(call)
    try expect(r.session.toolCallCount == 1)
    try expect(r.session.tools.first?.detail == "touch /never-run-from-telemetry")
    r.consume(record("response_item", ["type": "function_call_output", "call_id": "c", "output": "error is just quoted text"], seconds: 2))
    try expect(r.session.tools.first?.completed == true && r.session.status != .error)
}
check("context and rate limits use actual optional fields") {
    var r = RolloutReducer(id: "a")
    r.consume(record("event_msg", ["type": "token_count", "info": ["last_token_usage": ["total_tokens": 40], "total_token_usage": ["total_tokens": 99999], "model_context_window": 100] as [String: Any], "rate_limits": ["primary": ["used_percent": 23.0, "window_minutes": 300, "resets_at": 1700000300]]]))
    try expect(r.session.contextFraction == 0.4 && r.session.totalTokens == 99999)
    try expect(r.session.rateLimits.first?.usedPercent == 23)
}
check("invalid plan, unknown event and malformed line remain safe") {
    var r = RolloutReducer(id: "a")
    r.consume(Data("invalid JSON".utf8))
    r.consume(record("future_format", ["value": 1]))
    r.consume(record("response_item", ["type": "function_call", "name": "update_plan", "call_id": "p", "arguments": "{\"plan\":[{\"step\":\"Oops\",\"status\":\"invented\"}]}"]))
    try expect(r.session.progressFraction == nil)
}
check("aborted task is not successful; terminal error is preserved") {
    var r = RolloutReducer(id: "a")
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "1"]))
    r.consume(record("event_msg", ["type": "turn_aborted", "turn_id": "1"], seconds: 2))
    try expect(r.session.status == .idle && r.session.endedAt != nil)
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "2"], seconds: 3))
    r.consume(record("event_msg", ["type": "task_complete", "turn_id": "2", "error": ["message": "Connection lost"]], seconds: 4))
    try expect(r.session.status == .error && r.session.lastError == "Connection lost")
}
check("JSONL partial lines, incremental reads and truncation") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("stream.jsonl"); try Data("first\npar".utf8).write(to: url)
    let reader = JSONLTailer()
    try expect(try reader.read(url).map { String(decoding: $0, as: UTF8.self) } == ["first"])
    let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("tial\n".utf8)); try handle.close()
    try expect(try reader.read(url).map { String(decoding: $0, as: UTF8.self) } == ["partial"])
    try expect(try reader.read(url).isEmpty)
    try Data("new\n".utf8).write(to: url)
    try expect(try reader.read(url).count == 1 && reader.reset)
}
check("JSONL detects atomic file replacement") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("stream.jsonl"); try Data("old\n".utf8).write(to: url)
    let reader = JSONLTailer(); _ = try reader.read(url)
    try Data("replacement\n".utf8).write(to: url, options: .atomic)
    try expect(try reader.read(url).count == 1 && reader.reset)
}
check("provider discovers real sessions, appends, and marks stale honestly") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions/2026/09/29"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let url = sessions.appendingPathComponent("rollout-test.jsonl")
    var content = try line(record("session_meta", ["id": "thread-a", "cwd": "/tmp/App"]))
    content.append(try line(record("event_msg", ["type": "task_started", "turn_id": "turn-a"])))
    try content.write(to: url)
    let provider = CodexProvider(codexHome: dir, hookDirectory: dir.appendingPathComponent("hooks"))
    let initial = provider.poll(now: base.addingTimeInterval(2))
    try expect(initial.isInitial && initial.sessions.count == 1 && initial.sessions[0].status == .working)
    let stale = provider.poll(now: base.addingTimeInterval(200))
    try expect(stale.sessions[0].displayStatus == .unknown)
    let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    try handle.write(contentsOf: line(record("event_msg", ["type": "task_complete", "turn_id": "turn-a"], seconds: 210))); try handle.close()
    let done = provider.poll(now: base.addingTimeInterval(211))
    try expect(done.sessions[0].status == .completed && done.sessions[0].elapsed() == 210)
}
check("hook telemetry removes prompt, command and results") {
    let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "session_id": "safe-id", "cwd": "/tmp/App", "tool_input": ["command": "SECRET"], "prompt": "PRIVATE", "tool_response": "HIDDEN"] as [String: Any])
    let value = try HookTelemetry.sanitized(input, now: base)
    try expect(value?.0 == "safe-id")
    let text = String(decoding: value!.1, as: UTF8.self)
    try expect(!text.contains("SECRET") && !text.contains("PRIVATE") && !text.contains("HIDDEN"))
    var r = RolloutReducer(id: "safe-id"); r.consume(value!.1)
    try expect(r.session.status == .waiting && r.session.hasApprovalHooks)
}
check("hook path traversal and subagent mismatch are rejected") {
    for id in ["../escape", "foo/bar", ""] {
        let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": id])
        try expect(try HookTelemetry.sanitized(input) == nil)
    }
    let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "parent", "transcript_path": "/tmp/rollout-child.jsonl"])
    try expect(try HookTelemetry.sanitized(input) == nil)
}
check("Stop hook never proves task success") {
    var r = RolloutReducer(id: "a")
    r.consume(record("codex_touchbar_hook", ["hook_event_name": "UserPromptSubmit", "session_id": "a", "turn_id": "1"]))
    r.consume(record("codex_touchbar_hook", ["hook_event_name": "Stop", "session_id": "a", "turn_id": "1"], seconds: 1))
    try expect(r.session.status == .working && r.session.endedAt == nil)
}
check("hook writer uses private permissions and rejects symlink file") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart", "session_id": "a"])
    try HookTelemetry.append(input, directory: dir)
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("a.jsonl").path)
    try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("a.jsonl"))
    let destination = dir.appendingPathComponent("untouched"); try Data("original".utf8).write(to: destination)
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("a.jsonl"), withDestinationURL: destination)
    do { try HookTelemetry.append(input, directory: dir); throw Failure(description: "Accepted symlink") }
    catch is CocoaError { }
    try expect(try String(contentsOf: destination) == "original")
}

check("hooks merge with session without losing plan or clearing on token count") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let hooks = dir.appendingPathComponent("hooks")
    let url = sessions.appendingPathComponent("rollout-thread.jsonl")
    var data = try line(record("session_meta", ["id": "thread", "cwd": "/tmp/Project"]))
    data.append(try line(record("event_msg", ["type": "task_started", "turn_id": "t"], seconds: 1)))
    data.append(try line(record("response_item", ["type": "function_call", "name": "update_plan", "call_id": "p", "arguments": "{\"plan\":[{\"step\":\"Build\",\"status\":\"in_progress\"}]}"], seconds: 2)))
    data.append(try line(record("event_msg", ["type": "token_count", "info": ["model_context_window": 100]], seconds: 5)))
    try data.write(to: url)
    let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "session_id": "thread", "turn_id": "t"])
    try HookTelemetry.append(hook, directory: hooks, now: base.addingTimeInterval(3))
    let provider = CodexProvider(codexHome: dir, hookDirectory: hooks)
    let result = provider.poll(now: base.addingTimeInterval(7))
    try expect(result.sessions.count == 1 && result.sessions[0].status == .waiting)
    try expect(result.sessions[0].steps.count == 1 && result.sessions[0].contextWindow == 100)
    let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    try handle.write(contentsOf: line(record("response_item", ["type": "function_call_output", "call_id": "p", "output": "ok"], seconds: 8)))
    try handle.close()
    try expect(provider.poll(now: base.addingTimeInterval(10)).sessions[0].status == .working)
}
check("late Stop hook cannot override completed rollout") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    var data = try line(record("session_meta", ["id": "a"]))
    data.append(try line(record("event_msg", ["type": "task_started", "turn_id": "t"], seconds: 1)))
    data.append(try line(record("event_msg", ["type": "task_complete", "turn_id": "t"], seconds: 2)))
    try data.write(to: sessions.appendingPathComponent("a.jsonl"))
    let hooks = dir.appendingPathComponent("hooks")
    let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "a", "turn_id": "t"])
    try HookTelemetry.append(hook, directory: hooks, now: base.addingTimeInterval(3))
    let provider = CodexProvider(codexHome: dir, hookDirectory: hooks)
    try expect(provider.poll(now: base.addingTimeInterval(4)).sessions[0].status == .completed)
}
check("multiple sessions remain isolated and waiting is prioritized") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    for id in ["a", "b"] {
        var data = try line(record("session_meta", ["id": id, "cwd": "/tmp/" + id]))
        data.append(try line(record("event_msg", ["type": "task_started", "turn_id": id], seconds: 1)))
        if id == "b" { data.append(try line(record("response_item", ["type": "function_call", "name": "request_user_input", "call_id": "q", "arguments": "{}"], seconds: 2))) }
        try data.write(to: sessions.appendingPathComponent(id + ".jsonl"))
    }
    let provider = CodexProvider(codexHome: dir, hookDirectory: dir.appendingPathComponent("hooks"))
    let snapshot = provider.poll(now: base.addingTimeInterval(3))
    try expect(snapshot.sessions.map { $0.id } == ["b", "a"])
    try expect(snapshot.sessions[1].status == .working && snapshot.sessions[1].toolCallCount == 0)
}
check("JSONL bounded reads preserve data across budgets") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("partial.jsonl"); try Data("one\ntwo\nthree\n".utf8).write(to: url)
    let reader = JSONLTailer(); var lines: [Data] = []
    repeat { lines += try reader.read(url, budget: 3) } while !reader.caughtUp
    try expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
}
check("Git reports worktree changes including staged files and untracked entries") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    func git(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); try expect(p.terminationStatus == 0)
    }
    try git(["init"])
    try Data("first\nsecond\n".utf8).write(to: dir.appendingPathComponent("tracked.txt"))
    try git(["add", "tracked.txt"]); try git(["commit", "-m", "fixture"])
    try Data("first\nreplacement\nthird\n".utf8).write(to: dir.appendingPathComponent("tracked.txt"))
    try git(["add", "tracked.txt"])
    try Data("hello\n".utf8).write(to: dir.appendingPathComponent("untracked.txt"))
    let snapshot = GitMonitor.read(projectPath: dir.path)
    try expect(snapshot?.changedFiles == 2 && snapshot?.untrackedFiles == 1)
    try expect(snapshot?.linesAdded == 2 && snapshot?.linesRemoved == 1)
}
check("non-repository Git metadata is absent") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try expect(GitMonitor.read(projectPath: dir.path) == nil)
}

check("forked histories preserve child identity and ignore inherited parent activity") {
    var r = RolloutReducer(id: "filename")
    r.consume(record("session_meta", ["id": "child", "cwd": "/tmp/child", "source": ["subagent": ["parent_thread_id": "parent"]]], seconds: 10))
    r.consume(record("session_meta", ["id": "parent", "cwd": "/tmp/parent"], seconds: 0))
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "parent-turn"], seconds: 1))
    try expect(r.session.id == "child" && r.session.projectPath == "/tmp/child" && r.session.isSubagent)
    try expect(r.session.startedAt == nil)
    r.consume(record("event_msg", ["type": "task_started", "turn_id": "child-turn"], seconds: 11))
    try expect(r.session.turnID == "child-turn" && r.session.status == .working)
}
check("asynchronous custom question tool does not imply a blocked Codex turn") {
    var r = RolloutReducer(id: "a")
    r.consume(record("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "q", "arguments": "{}"], seconds: 1))
    try expect(r.session.status == .working)
}

check("Git observation cannot execute repository clean filters") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    func git(_ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); try expect(p.terminationStatus == 0)
    }
    try git(["init"])
    try Data("before\n".utf8).write(to: dir.appendingPathComponent("tracked.txt"))
    try git(["add", "tracked.txt"]); try git(["commit", "-m", "fixture"])
    try Data("after\n".utf8).write(to: dir.appendingPathComponent("tracked.txt"))
    try Data("tracked.txt filter=observer_test\n".utf8).write(to: dir.appendingPathComponent(".gitattributes"))
    try git(["config", "filter.observer_test.clean", "touch SHOULD_NOT_EXIST; cat"])
    try git(["config", "filter.observer_test.required", "true"])
    let snapshot = GitMonitor.read(projectPath: dir.path)
    try expect(snapshot != nil)
    try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("SHOULD_NOT_EXIST").path))
}

check("approval channel is inactive by default and never silently allows") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "echo example"]] as [String: Any])
    try expect(!ApprovalStore.isActive(directory: dir))
    try expect(try ApprovalStore.requestAndWait(input, directory: dir).isEmpty)
    try ApprovalStore.heartbeat(directory: dir)
    try expect(ApprovalStore.isActive(directory: dir))
    try expect(try ApprovalStore.requestAndWait(input, directory: dir, timeout: 0.01).isEmpty)
    try expect(ApprovalStore.pending(directory: dir).isEmpty)
    ApprovalStore.deactivate(directory: dir)
    try expect(!ApprovalStore.isActive(directory: dir))
}
check("approval heartbeat expires and cannot follow a symlink") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try ApprovalStore.heartbeat(directory: dir, now: Date().addingTimeInterval(-20))
    try expect(!ApprovalStore.isActive(directory: dir))
    try FileManager.default.removeItem(at: dir.appendingPathComponent("active.json"))
    let target = dir.appendingPathComponent("other.json")
    try JSONEncoder().encode(Date()).write(to: target)
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("active.json"), withDestinationURL: target)
    try expect(!ApprovalStore.isActive(directory: dir))
}

check("UI decisions require the unchanged, unexpired request") {
    let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(), id = UUID().uuidString
    let raw: [String: Any] = ["id": id, "sessionID": "session", "turnID": "turn", "tool": "Bash", "cwd": "/tmp", "inputJSON": "{\"command\":\"echo reviewed\"}", "createdAt": now.timeIntervalSinceReferenceDate, "expiresAt": now.addingTimeInterval(60).timeIntervalSinceReferenceDate]
    let data = try JSONSerialization.data(withJSONObject: raw)
    let request = try JSONDecoder().decode(ApprovalRequest.self, from: data)
    let url = dir.appendingPathComponent(id + ".request.json"); try data.write(to: url)
    try expect(ApprovalStore.pending(directory: dir).count == 1)
    var changed = raw; changed["inputJSON"] = "{\"command\":\"different command\"}"
    try JSONSerialization.data(withJSONObject: changed).write(to: url)
    do { try ApprovalStore.decide(.allow, request: request, directory: dir); throw Failure(description: "Approved a replaced request") }
    catch is CocoaError { }
    try data.write(to: url)
    do { try ApprovalStore.decide(.allow, request: request, directory: dir, now: now.addingTimeInterval(90)); throw Failure(description: "Approved an expired request") }
    catch is CocoaError { }
    try ApprovalStore.decide(.deny, request: request, directory: dir)
    do { try ApprovalStore.decide(.allow, request: request, directory: dir); throw Failure(description: "Overwrote a previous denial") }
    catch is CocoaError { }
    let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(id + ".reply.json"))) as! [String: Any]
    try expect(reply["id"] as? String == id && reply["decision"] as? String == "deny")
    try expect(ApprovalStore.pending(directory: dir).isEmpty)
}
print("\(passed) checks passed")
