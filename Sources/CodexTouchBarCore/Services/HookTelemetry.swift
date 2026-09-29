import Foundation
import Darwin

public enum HookTelemetry {
    public static let events: Set<String> = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt"]
    public static func sanitized(_ input: Data, now: Date = Date()) throws -> (String, Data)? {
        guard input.count <= 2 * 1024 * 1024,
              let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let name = payload["hook_event_name"] as? String, events.contains(name),
              let id = payload["session_id"] as? String,
              !id.isEmpty, id.count <= 120,
              id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        // Codex can report the parent's session_id for a subagent. Do not mix its events into the parent.
        if let transcript = payload["transcript_path"] as? String,
           URL(fileURLWithPath: transcript).lastPathComponent.hasPrefix("rollout-"),
           !URL(fileURLWithPath: transcript).lastPathComponent.contains(id) { return nil }
        var allowed: [String: Any] = [:]
        for key in ["hook_event_name", "session_id", "transcript_path", "cwd", "model", "turn_id", "tool_name", "tool_use_id"] {
            if let value = payload[key] as? String { allowed[key] = String(value.prefix(4096)) }
        }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelope: [String: Any] = ["type": "codex_touchbar_hook", "timestamp": format.string(from: now), "payload": allowed]
        var line = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]); line.append(10)
        return (id, line)
    }
    public static func append(_ input: Data, directory: URL = MonitorPaths.hookDirectory, now: Date = Date()) throws {
        guard let (id, data) = try sanitized(input, now: now) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileWriteNoPermission) }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(directoryFD) }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0, directoryStat.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        _ = fchmod(directoryFD, 0o700)
        let fd = openat(directoryFD, id + ".jsonl", O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        _ = fchmod(fd, 0o600)
        if info.st_size > 2 * 1024 * 1024 { guard ftruncate(fd, 0) == 0 else { return } }
        _ = data.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
    }
}
