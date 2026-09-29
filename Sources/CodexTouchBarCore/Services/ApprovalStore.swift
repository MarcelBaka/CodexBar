import Foundation
import Darwin

public struct ApprovalRequest: Codable, Identifiable, Equatable {
    public let id: String
    public let sessionID: String
    public let turnID: String?
    public let tool: String
    public let cwd: String
    public let inputJSON: String
    public let createdAt: Date
    public let expiresAt: Date
}

/// A local, request-specific channel for documented PermissionRequest hook results.
/// No decision is made without a reviewed, explicit UI action. Timeout defers to Codex.
public enum ApprovalStore {
    public enum Decision: String, Codable { case allow, deny, `defer` }
    private struct Reply: Codable { let id: String; let decision: Decision }
    public static var directory: URL { MonitorPaths.supportDirectory.appendingPathComponent("approvals", isDirectory: true) }
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
    private static func read(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 256 * 1024 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try? handle.readToEnd()
    }
    private static func write(_ data: Data, to url: URL) throws {
        // Atomic creation/replacement cannot follow an existing file symlink.
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
    public static func heartbeat(directory: URL = directory, now: Date = Date()) throws {
        try prepare(directory)
        try write(try JSONEncoder().encode(now), to: directory.appendingPathComponent("active.json"))
    }
    public static func isActive(directory: URL = directory, now: Date = Date()) -> Bool {
        guard let data = read(directory.appendingPathComponent("active.json")), let date = try? JSONDecoder().decode(Date.self, from: data) else { return false }
        return (0...8).contains(now.timeIntervalSince(date))
    }
    public static func deactivate(directory: URL = directory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("active.json"))
    }
    public static func pending(directory: URL = directory, now: Date = Date()) -> [ApprovalRequest] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".request.json") }.prefix(100).compactMap { url in
            guard let data = read(url), let request = try? JSONDecoder().decode(ApprovalRequest.self, from: data),
                  UUID(uuidString: request.id) != nil, url.lastPathComponent == request.id + ".request.json",
                  request.createdAt <= now else { return nil }
            if request.expiresAt <= now {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(request.id + ".reply.json"))
                return nil
            }
            if let replyData = read(directory.appendingPathComponent(request.id + ".reply.json")),
               let reply = try? JSONDecoder().decode(Reply.self, from: replyData), reply.id == request.id { return nil }
            return request
        }.sorted { $0.createdAt < $1.createdAt }
    }
    public static func decide(_ decision: Decision, request: ApprovalRequest, directory: URL = directory, now: Date = Date()) throws {
        try prepare(directory)
        guard request.expiresAt > now, UUID(uuidString: request.id) != nil,
              let data = read(directory.appendingPathComponent(request.id + ".request.json")),
              let current = try? JSONDecoder().decode(ApprovalRequest.self, from: data), current == request else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // UUID bound to an immutable request: an expired or replaced request cannot receive this response.
        let replyURL = directory.appendingPathComponent(request.id + ".reply.json")
        // One response only: another dialog/process cannot overwrite a previous denial.
        try JSONEncoder().encode(Reply(id: request.id, decision: decision)).write(to: replyURL, options: .withoutOverwriting)
        guard chmod(replyURL.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
    public static func requestAndWait(_ input: Data, directory: URL = directory, timeout: TimeInterval = 120) throws -> [String: Any] {
        guard isActive(directory: directory), input.count < 128 * 1024,
              let raw = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              raw["hook_event_name"] as? String == "PermissionRequest",
              let sessionID = raw["session_id"] as? String, let tool = raw["tool_name"] as? String,
              let toolInput = raw["tool_input"], JSONSerialization.isValidJSONObject(toolInput),
              try HookTelemetry.sanitized(input) != nil else { return [:] }
        try prepare(directory)
        let now = Date(), id = UUID().uuidString
        let serialized = try JSONSerialization.data(withJSONObject: toolInput, options: [.prettyPrinted, .sortedKeys])
        let request = ApprovalRequest(id: id, sessionID: sessionID, turnID: raw["turn_id"] as? String,
                                      tool: tool, cwd: raw["cwd"] as? String ?? "",
                                      inputJSON: String(decoding: serialized, as: UTF8.self), createdAt: now,
                                      expiresAt: now.addingTimeInterval(max(0, min(timeout, 120))))
        let requestURL = directory.appendingPathComponent(id + ".request.json")
        let replyURL = directory.appendingPathComponent(id + ".reply.json")
        try write(try JSONEncoder().encode(request), to: requestURL)
        defer { try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: replyURL) }
        while Date() < request.expiresAt && isActive(directory: directory) {
            if let data = read(replyURL), let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.id == id {
                if reply.decision == .defer { return [:] }
                var decision: [String: Any] = ["behavior": reply.decision.rawValue]
                if reply.decision == .deny { decision["message"] = "Declined by the user in Codex Touch Bar." }
                return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision] as [String: Any]]
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return [:]
    }
}
