import Foundation
import Darwin

public struct GitSnapshot: Equatable {
    public var branch: String?
    public var changedFiles: Int
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var untrackedFiles: Int
}

public enum GitMonitor {
    public static func read(projectPath: String) -> GitSnapshot? {
        guard projectPath.hasPrefix("/"), FileManager.default.fileExists(atPath: projectPath) else { return nil }
        var filterOverrides: [String] = []
        func git(_ args: [String]) -> Data? {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", projectPath] + filterOverrides + args
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
            environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"; task.environment = environment
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return nil }
            let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            var output = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                if output.count < 2 * 1024 * 1024 { output.append(chunk) }
            }
            task.waitUntilExit(); timeout.cancel()
            guard task.terminationStatus == 0, output.count < 2 * 1024 * 1024 else { return nil }
            return output
        }
        // Worktree reads can otherwise execute arbitrary configured clean/process filters.
        if let names = git(["config", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"]) {
            for name in String(decoding: names, as: UTF8.self).split(separator: "\n") {
                filterOverrides += ["-c", String(name) + (name.hasSuffix(".required") ? "=false" : "=")]
            }
        }
        guard let status = git(["status", "--porcelain=v1", "-z", "--untracked-files=normal"]) else { return nil }
        let branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"]).flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let fields = status.split(separator: 0)
        var changed = 0, untracked = 0, index = 0
        while index < fields.count {
            let bytes = Array(fields[index].prefix(2)); changed += 1
            if bytes == [63, 63] { untracked += 1 }
            if bytes.contains(82) || bytes.contains(67) { index += 1 }
            index += 1
        }
        // HEAD includes staged + unstaged changes, but intentionally excludes untracked content.
        let hasHEAD = git(["rev-parse", "--verify", "HEAD"]) != nil
        let diff = git(["diff", "--no-ext-diff", "--no-textconv", "--numstat"] + (hasHEAD ? ["HEAD", "--"] : ["--cached", "--"]))
        var added = 0, removed = 0
        for line in String(decoding: diff ?? Data(), as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            if parts.count >= 2 { added += Int(parts[0]) ?? 0; removed += Int(parts[1]) ?? 0 }
        }
        return GitSnapshot(branch: branch, changedFiles: changed, linesAdded: diff == nil ? nil : added, linesRemoved: diff == nil ? nil : removed, untrackedFiles: untracked)
    }
}
