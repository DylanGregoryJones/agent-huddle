import Foundation

/// The panel's state. Everything slow (registry, process environments, transcripts, building rows)
/// runs on a private serial queue; only the results are published, on the main thread.
@MainActor
final class HuddleStore: ObservableObject {
  @Published var rows: [AgentRow] = []
  @Published var expandedId: String? {
    didSet {
      guard expandedId != oldValue else { return }
      markLayoutChanged()
      requestGoal()
    }
  }
  /// sessionId -> its "Working towards" section, for rows that have been opened.
  @Published var goals: [String: GoalDisplay] = [:] { didSet { if goals != oldValue { markLayoutChanged() } } }
  @Published var hookInstalled = true { didSet { if hookInstalled != oldValue { markLayoutChanged() } } }
  /// The permission socket couldn't be opened, so no permission cards can appear.
  @Published var serverDown = false { didSet { if serverDown != oldValue { markLayoutChanged() } } }
  /// sessionId -> why the last jump to its Terminal tab failed, shown for a few seconds.
  @Published var jumpMessages: [String: String] = [:] { didSet { if jumpMessages != oldValue { markLayoutChanged() } } }
  /// When rows last moved or cards came or went. Cards keep their buttons off for 0.5 s after it,
  /// so a click can't land on an Allow that has just slid under the pointer.
  @Published private(set) var layoutChangedAt = Date.distantPast

  static let notFoundMessage = "Couldn't find its Terminal tab"
  static let notAuthorizedMessage = "Allow Agent Huddle to control Terminal in System Settings › Privacy & Security › Automation"
  /// How long a row reads "Allowed" / "Denied" after a click, while the registry catches up.
  private static let decisionShownFor: TimeInterval = 2

  private let server: PermissionServer
  /// nil in the render modes, which must never run Claude.
  private let goalWriter: GoalWriter?
  private let worker = DispatchQueue(label: "agent-huddle.store")
  private let watcher = SessionWatcher()   // only touched on `worker`
  private let jumpQueue = DispatchQueue(label: "agent-huddle.jump")
  private var timer: Timer?
  private var refreshing = false
  private var tickAgain = false
  private var nextHookCheck = Date.distantPast
  private var jumpMessageGeneration: [String: Int] = [:]
  private var jumping = false
  /// sessionId -> the decision just sent from this panel, and when.
  private var decisions: [String: (decision: Decision, at: Date)] = [:]

  init(server: PermissionServer, goalWriter: GoalWriter? = nil) {
    self.server = server
    self.goalWriter = goalWriter
    goalWriter?.onChange = { [weak self] id, display in self?.goals[id] = display }
  }

  /// Ticks now and then every second.
  func startTicking() {
    guard timer == nil else { return }
    tick()
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func tick() {
    if refreshing { tickAgain = true; return }
    refreshing = true
    let now = Date()
    let checkHook = now >= nextHookCheck
    if checkHook {
      nextHookCheck = now.addingTimeInterval(30)
      // X no longer quits, so "close and reopen" can't restart the socket: try again here instead.
      if serverDown, (try? server.start()) != nil { serverDown = false }
    }
    let pending = server.pending, watcher = self.watcher, decided = recentDecisions(now: now)
    worker.async {
      let rows = watcher.refresh(pending: pending, decisions: decided, now: Date())
      let hook = checkHook ? HuddleStore.readHookInstalled() : nil
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.finishTick(rows: rows, hook: hook) }
      }
    }
  }

  /// One refresh that waits for its result, for `--render-live`.
  func refreshNow() {
    let server = self.server, watcher = self.watcher, decided = recentDecisions(now: Date())
    let (rows, hook) = worker.sync {
      (watcher.refresh(pending: server.pending, decisions: decided, now: Date()), HuddleStore.readHookInstalled())
    }
    finishTick(rows: rows, hook: hook)
  }

  func allow(_ row: AgentRow) { decide(row, .allow) }
  func deny(_ row: AgentRow) { decide(row, .deny) }

  /// Clicks while a jump is still running are ignored, so they can't pile up and steal focus later.
  func jump(_ row: AgentRow) {
    guard !jumping else { return }
    jumping = true
    let pid = row.pid, id = row.id
    jumpQueue.async {
      let result = TerminalBridge.focus(tty: ProcessReader.tty(of: pid))
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.jumping = false
          switch result {
          case .focused: break
          case .notFound: self.showJumpMessage(id, HuddleStore.notFoundMessage, for: 3)
          case .notAuthorized: self.showJumpMessage(id, HuddleStore.notAuthorizedMessage, for: 8)
          }
        }
      }
    }
  }

  // MARK: private

  /// Only ever the id of the request shown on this row's card.
  private func decide(_ row: AgentRow, _ d: Decision) {
    guard let pending = row.pending else { return }
    if server.decide(id: pending.id, d) { decisions[row.id] = (d, Date()) }
    markLayoutChanged()
    tick()
  }

  /// Also called when the panel is shown again: a card that arrived while it was hidden must not be
  /// clickable the instant it appears.
  func markLayoutChanged() { layoutChangedAt = Date() }

  /// Shows what's remembered for the row just opened and asks for a new description if it's out of date.
  private func requestGoal() {
    guard let writer = goalWriter, let id = expandedId, let row = rows.first(where: { $0.id == id }) else { return }
    goals[id] = writer.display(id)
    writer.request(row)
  }

  /// Drops decisions older than `decisionShownFor` and returns the rest.
  private func recentDecisions(now: Date) -> [String: Decision] {
    decisions = decisions.filter { now.timeIntervalSince($0.value.at) < Self.decisionShownFor }
    return decisions.mapValues { $0.decision }
  }

  private func finishTick(rows newRows: [AgentRow], hook: Bool?) {
    if newRows != rows {
      if rowLayoutChanged(rows, newRows, expandedId: expandedId) { markLayoutChanged() }
      rows = newRows
    }
    if let hook, hook != hookInstalled { hookInstalled = hook }
    if let e = expandedId, !newRows.contains(where: { $0.id == e }) { expandedId = nil }
    refreshing = false
    if tickAgain { tickAgain = false; tick() }
  }

  private func showJumpMessage(_ id: String, _ message: String, for seconds: TimeInterval) {
    jumpMessages[id] = message
    let generation = (jumpMessageGeneration[id] ?? 0) + 1
    jumpMessageGeneration[id] = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      MainActor.assumeIsolated {
        guard self.jumpMessageGeneration[id] == generation else { return }
        self.jumpMessages[id] = nil
        self.jumpMessageGeneration[id] = nil
      }
    }
  }

  /// nil when settings.json can't be read or parsed (e.g. caught mid-write): keep the last answer.
  nonisolated private static func readHookInstalled() -> Bool? {
    (try? SettingsMerge.load(Paths.settingsPath)).map(SettingsMerge.hasHook)
  }
}

/// Per-session caches behind `HuddleStore.tick`. Unchecked Sendable: used only on the store's serial queue.
final class SessionWatcher: @unchecked Sendable {
  private static let scanRetry: TimeInterval = 5

  private var colours = ColourAssigner()
  /// sessionId -> TERM_PROGRAM is Apple_Terminal. Keyed by session, not pid, because pids get reused.
  private var isTerminal: [String: Bool] = [:]
  private var scanMissedAt: [String: Date] = [:]
  private var tails: [String: TranscriptTail] = [:]
  private var summaries: [String: TranscriptSummary] = [:]

  func refresh(pending: [PendingRequest], decisions: [String: Decision], now: Date) -> [AgentRow] {
    let records = loadRegistry()
    let kept = records.filter { $0.entrypoint == "cli" && ProcessReader.isAlive($0.pid) && terminal($0) }
    let keptPids = Set(kept.map { $0.pid })
    let keptIds = Set(kept.map { $0.sessionId })

    for r in kept {
      guard let tail = tail(for: r, now: now) else { continue }
      let events = tail.readNew()
      if !events.isEmpty { summaries[r.sessionId, default: TranscriptSummary()].apply(events) }
    }

    let present = Set(records.map { $0.sessionId })
    isTerminal = isTerminal.filter { present.contains($0.key) }
    scanMissedAt = scanMissedAt.filter { keptIds.contains($0.key) }
    tails = tails.filter { keptIds.contains($0.key) }
    summaries = summaries.filter { keptIds.contains($0.key) }

    let inputs = RowInputs(records: records, isTerminal: { keptPids.contains($0) }, isAlive: ProcessReader.isAlive,
                           summaries: summaries, pending: pending, recentDecisions: decisions, now: now)
    return buildRows(inputs, colours: &colours)
  }

  private func terminal(_ r: SessionRecord) -> Bool {
    if let known = isTerminal[r.sessionId] { return known }
    guard let env = ProcessReader.environment(of: r.pid) else { return false }   // unreadable: try again next tick
    let yes = env["TERM_PROGRAM"] == "Apple_Terminal"
    isTerminal[r.sessionId] = yes
    return yes
  }

  /// The tail doubles as the cache of the transcript's path. The usual place is checked every tick;
  /// the scan of every project folder runs at most every 5 s per session.
  private func tail(for r: SessionRecord, now: Date) -> TranscriptTail? {
    if let t = tails[r.sessionId] { return t }
    let direct = directTranscriptPath(cwd: r.cwd, sessionId: r.sessionId)
    let path: String?
    if FileManager.default.fileExists(atPath: direct) {
      path = direct
    } else {
      if let missed = scanMissedAt[r.sessionId], now.timeIntervalSince(missed) < Self.scanRetry { return nil }
      path = transcriptPath(cwd: r.cwd, sessionId: r.sessionId)
    }
    guard let found = path else {
      scanMissedAt[r.sessionId] = now
      return nil
    }
    scanMissedAt[r.sessionId] = nil
    let t = TranscriptTail(path: found)
    tails[r.sessionId] = t
    return t
  }
}
