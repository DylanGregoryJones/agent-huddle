import Foundation

enum AgentState: Int, Comparable {
  case needsYou = 0, working, idle
  static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }
}

struct StepLine: Equatable {
  let age: String
  let text: String
}

struct AgentRow: Equatable, Identifiable {
  let id: String
  let pid: Int32
  let name: String
  let folder: String
  let state: AgentState
  let doing: String
  let colorIndex: Int
  let pending: PendingRequest?
  let cardText: String?
  /// Everything the pending request asks, for the expanded row; nil when there's nothing to show.
  let fullRequest: String?
  let answerInTerminal: Bool
  let runningFor: String
  let youAsked: String?
  let steps: [StepLine]
  let claudeSaid: String?
  /// Claude Code's title for the session, if it has one yet (unlike `name`, never the folder).
  let title: String?
  /// What the goal writer shows Claude (see `goalMessages`), and how many distinct messages there are.
  let goalMessages: [String]
  let messageCount: Int
}

struct RowInputs {
  var records: [SessionRecord]
  var isTerminal: (Int32) -> Bool
  var isAlive: (Int32) -> Bool
  var summaries: [String: TranscriptSummary]
  var pending: [PendingRequest]
  /// sessionId -> the decision just sent from the panel (the app keeps them about 2 s). The registry
  /// still says "waiting" for a moment after a click; these rows read "Allowed" / "Denied" instead.
  var recentDecisions: [String: Decision] = [:]
  var now: Date
}

private func startedBefore(_ a: SessionRecord, _ b: SessionRecord) -> Bool {
  switch (a.startedAt, b.startedAt) {
  case let (x?, y?) where x != y: return x < y
  case (_?, nil): return true
  case (nil, _?): return false
  default: return a.pid < b.pid
  }
}

func buildRows(_ i: RowInputs, colours: inout ColourAssigner) -> [AgentRow] {
  let kept = i.records
    .filter { $0.entrypoint == "cli" && i.isAlive($0.pid) && i.isTerminal($0.pid) }
    .sorted(by: startedBefore)

  let colourOf = colours.assign(kept.map { (sessionId: $0.sessionId, folder: Paths.abbreviate($0.cwd)) })

  var seen: [String: Int] = [:]
  var rows: [(AgentRow, SessionRecord)] = []
  for r in kept {
    let summary = i.summaries[r.sessionId] ?? TranscriptSummary()
    let base = summary.title ?? (r.cwd as NSString).lastPathComponent
    let n = (seen[base] ?? 0) + 1
    seen[base] = n
    let name = n == 1 ? base : base + " · \(n)"

    let pending = i.pending.filter { $0.sessionId == r.sessionId }.max { $0.receivedAt < $1.receivedAt }
    let decided = pending == nil ? i.recentDecisions[r.sessionId] : nil   // a newer request wins
    let waiting = r.status == "waiting" && decided == nil
    let state: AgentState
    if pending != nil || waiting { state = .needsYou }
    else if r.status == "busy" || (r.status == "waiting" && decided == .allow) { state = .working }
    else { state = .idle }
    let doing = decided.map { $0 == .allow ? "Allowed" : "Denied" }
      ?? doingLine(status: r.status, waitingFor: r.waitingFor, pending: pending, latest: summary.latest,
                   hasPrompt: summary.lastPrompt != nil, statusSince: r.statusUpdatedAt, now: i.now)

    rows.append((AgentRow(
      id: r.sessionId, pid: r.pid, name: name, folder: Paths.abbreviate(r.cwd), state: state,
      doing: doing,
      colorIndex: colourOf[r.sessionId] ?? 0,
      pending: pending,
      cardText: pending.map { cardText($0.toolName, $0.toolInput) },
      fullRequest: pending.map { fullRequestText($0.toolName, $0.toolInput) }.flatMap { $0.isEmpty ? nil : $0 },
      answerInTerminal: waiting && pending == nil,
      runningFor: runningFor(since: r.startedAt, now: i.now),
      youAsked: summary.lastPrompt.map { oneLine($0, max: 140) },
      steps: summary.steps.map { StepLine(age: relativeAge($0.at, now: i.now), text: describeTool($0.name, $0.input)) },
      claudeSaid: summary.lastText.map { oneLine($0, max: 200) },
      title: summary.title,
      goalMessages: goalMessages(summary),
      messageCount: summary.messageCount), r))
  }
  // `kept` is already oldest-first; a stable sort by state keeps that within each group.
  return rows.enumerated()
    .sorted { ($0.element.0.state, $0.offset) < ($1.element.0.state, $1.offset) }
    .map { $0.element.0 }
}

/// What decides where each row, and so each Allow button, sits on screen: the order, which rows
/// show a card (and for which request), which doing lines take two lines, and what the expanded
/// row's detail holds.
private struct RowLayout: Equatable {
  let id: String
  let cardId: String?
  let twoLines: Bool
  let detail: [String?]?
}

private func layout(_ rows: [AgentRow], expandedId: String?) -> [RowLayout] {
  rows.map { r in
    RowLayout(id: r.id, cardId: r.pending?.id, twoLines: r.answerInTerminal,
              detail: r.id == expandedId ? [r.fullRequest, r.youAsked, r.claudeSaid, String(r.steps.count)] : nil)
  }
}

/// True when going from `old` to `new` may move rows on screen, so an Allow button under the
/// pointer could now belong to a different request.
func rowLayoutChanged(_ old: [AgentRow], _ new: [AgentRow], expandedId: String?) -> Bool {
  layout(old, expandedId: expandedId) != layout(new, expandedId: expandedId)
}

func headerCount(_ rows: [AgentRow]) -> String {
  if rows.isEmpty { return "No agents running" }
  if rows.count == 1 { return "1 agent" }
  let needs = rows.filter { $0.state == .needsYou }.count
  return needs > 0 ? "\(rows.count) agents · \(needs) needs you" : "\(rows.count) agents"
}
