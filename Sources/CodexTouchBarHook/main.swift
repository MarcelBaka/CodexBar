import Foundation
import CodexTouchBarCore

// Default: observer only. Opt-in approval UI returns only explicit, request-specific decisions.
var response = "{}"
defer { print(response) }
do {
    var input = Data()
    let limit = 2 * 1024 * 1024
    while input.count <= limit {
        let chunk = try FileHandle.standardInput.read(upToCount: min(65536, limit + 1 - input.count)) ?? Data()
        if chunk.isEmpty { break }
        input.append(chunk)
    }
    let directory = ProcessInfo.processInfo.environment["CODEX_TOUCH_BAR_HOOK_DIR"].map { URL(fileURLWithPath: $0) } ?? MonitorPaths.hookDirectory
    try HookTelemetry.append(input, directory: directory)
    if CommandLine.arguments.contains("--approval-ui") {
        let approvalDirectory = ProcessInfo.processInfo.environment["CODEX_TOUCH_BAR_APPROVAL_DIR"].map { URL(fileURLWithPath: $0) } ?? ApprovalStore.directory
        let result = try ApprovalStore.requestAndWait(input, directory: approvalDirectory)
        response = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }
} catch {
    // Never include the input or exception (which may contain private paths) in logs.
    fputs("Codex Touch Bar: telemetry unavailable.\n", stderr)
}
