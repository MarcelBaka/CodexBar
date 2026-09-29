import Foundation

/// Keeps byte offsets, handles a newline split across writes, and detects replacement/truncation.
public final class JSONLTailer {
    public private(set) var offset: UInt64 = 0
    public private(set) var reset = false
    public private(set) var caughtUp = true
    private var inode: UInt64?
    private var pending = Data()
    private var droppingOversize = false
    public init() {}
    public func read(_ url: URL, budget: Int = 8 * 1024 * 1024) throws -> [Data] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        reset = (inode != nil && inode != currentInode) || size < offset
        if reset { offset = 0; pending.removeAll(); droppingOversize = false }
        inode = currentInode
        guard size > offset else { caughtUp = true; return [] }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: min(budget, Int(min(UInt64(Int.max), size - offset)))) ?? Data()
        offset += UInt64(data.count); caughtUp = offset >= size
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if !droppingOversize && line.count <= 4 * 1024 * 1024 && !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(...end); droppingOversize = false
        }
        if pending.count > 4 * 1024 * 1024 { pending.removeAll(); droppingOversize = true }
        return lines
    }
}

public final class CodexProvider: AgentProvider {
    private struct FileState {
        let url: URL
        var reader = JSONLTailer()
        var reducer: RolloutReducer
        init(url: URL) {
            self.url = url
            self.reducer = RolloutReducer(id: url.deletingPathExtension().lastPathComponent)
        }
    }
    private let codexHome: URL
    private let hookDirectory: URL
    private let staleInterval: TimeInterval
    private var files: [String: FileState] = [:]
    private var hookFiles: [String: FileState] = [:]
    private var lastDiscovery = Date.distantPast
    private var initial = true
    private var discoveryError: String?
    public init(codexHome: URL = MonitorPaths.codexHome, hookDirectory: URL = MonitorPaths.hookDirectory, staleInterval: TimeInterval = 120) {
        self.codexHome = codexHome; self.hookDirectory = hookDirectory; self.staleInterval = staleInterval
    }
    public func poll(now: Date = Date()) -> ProviderSnapshot {
        if now.timeIntervalSince(lastDiscovery) >= 3 || files.isEmpty {
            discover(); lastDiscovery = now
        }
        var diagnostic = discoveryError
        var rebuilding = false
        for key in Array(files.keys) {
            guard var state = files[key] else { continue }
            do {
                let lines = try state.reader.read(state.url)
                if state.reader.reset { state.reducer = RolloutReducer(id: state.url.lastPathComponent) }
                for line in lines { state.reducer.consume(line) }
                rebuilding = rebuilding || !state.reader.caughtUp
                files[key] = state
            } catch { diagnostic = "Some session files cannot be read. Check folder permissions in Settings." }
        }
        for key in Array(hookFiles.keys) {
            guard var state = hookFiles[key] else { continue }
            do {
                let lines = try state.reader.read(state.url, budget: 1024 * 1024)
                if state.reader.reset { state.reducer = RolloutReducer(id: state.url.deletingPathExtension().lastPathComponent) }
                for line in lines { state.reducer.consume(line) }
                hookFiles[key] = state
            } catch { diagnostic = "Optional hook telemetry is unreadable." }
        }
        var sessions: [String: AgentSession] = [:]
        for state in files.values {
            var session = state.reducer.session
            guard session.sessionStartedAt != nil else { continue }
            session.transcriptPath = state.url.path
            if let previous = sessions[session.id], previous.updatedAt > session.updatedAt { continue }
            sessions[session.id] = session
        }
        for state in hookFiles.values {
            let hook = state.reducer.session
            guard hook.updatedAt > .distantPast else { continue }
            var session = sessions[hook.id] ?? hook
            session.hasApprovalHooks = true
            session.source = sessions[hook.id] == nil ? .hooks : .rolloutWithHooks
            let startsNewTurn = (hook.startedAt ?? .distantPast) > (session.endedAt ?? .distantFuture)
            if hook.activityUpdatedAt > session.activityUpdatedAt && (session.endedAt == nil || startsNewTurn) {
                session.status = hook.status; session.activity = hook.activity; session.updatedAt = max(hook.updatedAt, session.updatedAt)
                session.activityUpdatedAt = hook.activityUpdatedAt
                if hook.startedAt != nil && hook.turnID != session.turnID {
                    session.turnID = hook.turnID; session.startedAt = hook.startedAt; session.endedAt = hook.endedAt
                    session.steps = []; session.tools = []; session.toolCallCount = 0; session.changedFiles = []
                }
                if hook.endedAt != nil { session.endedAt = hook.endedAt }
                if session.projectPath.isEmpty { session.projectPath = hook.projectPath }
                session.model = hook.model ?? session.model
            }
            sessions[session.id] = session
        }
        var list = Array(sessions.values)
        for index in list.indices {
            list[index].isStale = now.timeIntervalSince(list[index].updatedAt) > staleInterval && [.working, .waiting].contains(list[index].status)
        }
        list.sort {
            if $0.displayStatus.priority != $1.displayStatus.priority { return $0.displayStatus.priority < $1.displayStatus.priority }
            return $0.updatedAt > $1.updatedAt
        }
        if rebuilding { diagnostic = "Loading session history…" }
        else if !files.isEmpty && list.isEmpty && diagnostic == nil {
            diagnostic = "Session files found, but their format is not recognized. See README compatibility notes."
        }
        let snapshot = ProviderSnapshot(sessions: list, diagnostic: diagnostic, isInitial: initial || rebuilding)
        if !rebuilding { initial = false }
        return snapshot
    }
    private func discover() {
        let fm = FileManager.default
        let root = codexHome.appendingPathComponent("sessions", isDirectory: true)
        discoveryError = nil
        var candidates: [(URL, Date)] = []
        if !fm.fileExists(atPath: root.path) {
            discoveryError = "No local Codex sessions yet. Start Codex, or choose its data folder in Settings."
        } else if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                candidates.append((url, values.contentModificationDate ?? .distantPast))
            }
        } else { discoveryError = "Cannot read the Codex sessions folder. Check access in Settings." }
        let selected = candidates.sorted { $0.1 > $1.1 }.prefix(30).map { $0.0 }
        let paths = Set(selected.map { $0.path })
        files = files.filter { paths.contains($0.key) }
        for url in selected where files[url.path] == nil { files[url.path] = FileState(url: url) }
        if let urls = try? fm.contentsOfDirectory(at: hookDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) {
            let hooks = urls.filter { $0.pathExtension == "jsonl" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(30)
            let hookPaths = Set(hooks.map { $0.path })
            hookFiles = hookFiles.filter { hookPaths.contains($0.key) }
            for url in hooks where hookFiles[url.path] == nil { hookFiles[url.path] = FileState(url: url) }
        }
    }
}
