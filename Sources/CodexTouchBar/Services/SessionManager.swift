import Foundation
import Combine
import CodexTouchBarCore

final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedID: String?
    @Published var diagnostic: String?
    @Published var now = Date()
    @Published var demoMode = false
    @Published var approvals: [ApprovalRequest] = []
    var onReviewApproval: ((ApprovalRequest) -> Void)?
    @Published var git: GitSnapshot?
    @Published var notificationStatus = "Notifications are off"
    let approvalDirectory: URL
    let settings: AppSettings
    let notifications = NotificationManager()
    var onTransition: ((AgentSession) -> Void)?
    private let queue = DispatchQueue(label: "CodexTouchBar.monitor", qos: .utility)
    private let gitQueue = DispatchQueue(label: "CodexTouchBar.git", qos: .utility)
    private var provider: CodexProvider
    private var timer: Timer?
    private var polling = false
    private var gitPolling = false
    private var generation = 0
    private var manualSelection = false
    private var started = Date()
    private var demoStarted = Date()
    private var lastGit = Date.distantPast
    private var gitProject = ""
    var selected: AgentSession? { sessions.first { $0.id == selectedID } ?? sessions.first }
    var visibleSessions: [AgentSession] { settings.showSubagents ? sessions : sessions.filter { !$0.isSubagent } }
    init(settings: AppSettings, approvalDirectory: URL = ApprovalStore.directory) {
        self.approvalDirectory = approvalDirectory
        self.settings = settings
        provider = CodexProvider(codexHome: URL(fileURLWithPath: NSString(string: settings.codexPath).expandingTildeInPath))
        notifications.onPermission = { [weak self] in self?.notificationStatus = $0 }
    }
    func start() {
        tick()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil; ApprovalStore.deactivate(directory: approvalDirectory) }
    func reload() {
        generation += 1; started = Date()
        provider = CodexProvider(codexHome: URL(fileURLWithPath: NSString(string: settings.codexPath).expandingTildeInPath))
        sessions = []; selectedID = nil; diagnostic = nil; manualSelection = false
        git = nil; lastGit = .distantPast; tick()
    }
    func select(_ id: String) {
        selectedID = id; manualSelection = true; lastGit = .distantPast; updateGit()
    }
    var currentApproval: ApprovalRequest? { approvals.first { $0.sessionID == selected?.id } }
    func reviewApproval() { if let request = currentApproval { onReviewApproval?(request) } }
    func setDemo(_ value: Bool) {
        guard value != demoMode else { return }
        ApprovalStore.deactivate(directory: approvalDirectory); approvals = []
        demoMode = value; generation += 1; demoStarted = Date(); selectedID = nil
        manualSelection = false; git = nil; sessions = []; lastGit = .distantPast
        if value { updateDemo() } else { reload() }
    }
    func tick() {
        now = Date()
        if demoMode { updateDemo(); return }
        guard !polling else { return }
        polling = true
        let token = generation, source = provider, date = now, approvalEnabled = settings.approvalUI, approvalPath = approvalDirectory
        queue.async { [weak self] in
            if approvalEnabled { try? ApprovalStore.heartbeat(directory: approvalPath) } else { ApprovalStore.deactivate(directory: approvalPath) }
            let requests = approvalEnabled ? ApprovalStore.pending(directory: approvalPath) : []
            let result = source.poll(now: date)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                guard token == self.generation && !self.demoMode else { return }
                self.approvals = requests
                self.apply(result); self.updateGit()
                if let request = requests.first, self.sessions.contains(where: { $0.id == request.sessionID }) {
                    self.selectedID = request.sessionID
                }
            }
        }
    }
    private func apply(_ snapshot: ProviderSnapshot) {
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = snapshot.sessions; diagnostic = snapshot.diagnostic
        let eligible = visibleSessions
        var newlyWaiting: AgentSession?
        for session in eligible {
            let before = previous[session.id]
            let changed = before?.status != session.status || before?.turnID != session.turnID
            if changed && session.displayStatus == .waiting && !session.isStale { newlyWaiting = session }
            if changed && !snapshot.isInitial && session.updatedAt >= started {
                if settings.notifications { notifications.notify(session) }
                onTransition?(session)
            }
        }
        if let waiting = newlyWaiting { selectedID = waiting.id; manualSelection = false }
        else if !manualSelection || !eligible.contains(where: { $0.id == selectedID }) {
            selectedID = eligible.first?.id
        }
        if previous.isEmpty, let session = selected, session.displayStatus == .working || session.displayStatus == .waiting { onTransition?(session) }
    }
    private func updateGit() {
        guard !demoMode, let session = selected, !session.projectPath.isEmpty, !gitPolling else { return }
        if gitProject != session.projectPath { git = nil; lastGit = .distantPast }
        guard now.timeIntervalSince(lastGit) >= 10 else { return }
        let path = session.projectPath; gitProject = path; lastGit = now; gitPolling = true
        gitQueue.async { [weak self] in
            let result = GitMonitor.read(projectPath: path)
            DispatchQueue.main.async {
                guard let self = self else { return }; self.gitPolling = false
                if !self.demoMode && self.selected?.projectPath == path { self.git = result }
            }
        }
    }
    private func updateDemo() {
        let phase = min(6, Int(now.timeIntervalSince(demoStarted) / 5))
        let names = ["Analyze project", "Read source files", "Implement the interface", "Run tests", "Verify changes", "Ready to ship"]
        let activities = ["Analyzing project…", "Reading files…", "Writing code…", "Running tests…", "Waiting for approval…", "Finishing…", "All changes verified"]
        var session = AgentSession(id: "demo-current")
        session.source = .demo; session.projectPath = "/Demo/Orbit"; session.branch = "feature/native-ui"; session.model = "Codex · demo"
        session.sessionStartedAt = demoStarted; session.startedAt = demoStarted.addingTimeInterval(-128)
        session.updatedAt = now; session.turnID = "demo-turn"; session.taskTitle = "Build a thoughtful native experience"
        session.status = phase == 4 ? .waiting : phase == 6 ? .completed : .working
        session.activity = activities[phase]
        let done = phase == 6 ? 6 : phase == 5 ? 4 : min(phase, 4)
        session.steps = names.enumerated().map { i, title in PlanStep(id: "\(i)", title: title, status: i < done ? .completed : i == done ? .inProgress : .pending) }
        session.toolCallCount = 3 + phase * 4; session.contextUsedTokens = 41000; session.contextWindow = 100000
        session.hasApprovalHooks = true
        if phase == 6 { session.endedAt = demoStarted.addingTimeInterval(30) }
        let before = selected
        sessions = [session]; selectedID = session.id; diagnostic = nil
        if before?.status != session.status { onTransition?(session) }
    }
    // Deterministic showcase for offscreen native snapshots and smoke verification.
    func setDemoSnapshot() {
        demoMode = true; demoStarted = Date().addingTimeInterval(-15); now = Date(); updateDemo()
    }
}
