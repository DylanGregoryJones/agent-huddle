import Foundation

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let nowT = t0.addingTimeInterval(3600)

private func rec(_ pid: Int32, _ sid: String, cwd: String = "/Users/x/game-prototype", entry: String? = "cli",
                 status: String? = "idle", waitingFor: String? = nil, start: Double? = nil) -> SessionRecord {
  SessionRecord(pid: pid, sessionId: sid, cwd: cwd, name: nil, entrypoint: entry, status: status,
                waitingFor: waitingFor, startedAt: start.map { t0.addingTimeInterval($0) }, statusUpdatedAt: nil)
}

private func inputs(_ recs: [SessionRecord], summaries: [String: TranscriptSummary] = [:],
                    pending: [PendingRequest] = [], decisions: [String: Decision] = [:],
                    alive: @escaping (Int32) -> Bool = { _ in true },
                    terminal: @escaping (Int32) -> Bool = { _ in true }) -> RowInputs {
  RowInputs(records: recs, isTerminal: terminal, isAlive: alive, summaries: summaries, pending: pending,
            recentDecisions: decisions, now: nowT)
}

private func titled(_ t: String) -> TranscriptSummary { var s = TranscriptSummary(); s.title = t; return s }

func rowsTests() {
  test("only alive Terminal cli sessions") {
    var c = ColourAssigner()
    let recs = [rec(1, "a", start: 1), rec(2, "b", entry: "sdk-ts", start: 2), rec(3, "c", start: 3), rec(4, "d", start: 4)]
    let rows = buildRows(inputs(recs, alive: { $0 != 3 }, terminal: { $0 != 4 }), colours: &c)
    expectEqual(rows.map { $0.id }, ["a"])
  }

  test("title names rows, folder name until titled") {
    var c = ColourAssigner()
    let home = Paths.home
    let recs = [rec(1, "a", cwd: home, start: 1), rec(2, "b", cwd: home, start: 2), rec(3, "c", start: 3)]
    let sums = ["a": titled("Agent huddle corner widget"), "b": titled("Docs sync task")]
    let rows = buildRows(inputs(recs, summaries: sums), colours: &c)
    expectEqual(rows.map { $0.name }, ["Agent huddle corner widget", "Docs sync task", "game-prototype"])
  }

  test("rows carry what the goal writer needs: title, messages and their count") {
    var c = ColourAssigner()
    var s = titled("Pancake site")
    s.apply((1...9).map { .prompt("m\($0)") })
    let row = buildRows(inputs([rec(1, "a", start: 1), rec(2, "b", start: 2)], summaries: ["a": s]), colours: &c)
    expectEqual(row[0].title, "Pancake site")
    expectEqual(row[0].messageCount, 9)
    expectEqual(row[0].goalMessages, ["m1", "m2", "m3", "m5", "m6", "m7", "m8", "m9"])
    expectEqual(row[1].title, nil)
    expectEqual(row[1].messageCount, 0)
    expectEqual(row[1].goalMessages, [])
  }

  test("duplicate names get · 2") {
    var c = ColourAssigner()
    let rows = buildRows(inputs([rec(2, "b", start: 2), rec(1, "a", start: 1)]), colours: &c)
    expectEqual(rows.map { $0.name }, ["game-prototype", "game-prototype · 2"])
    expectEqual(rows.map { $0.id }, ["a", "b"])
  }

  test("order: needs you, working, idle; then oldest first") {
    var c = ColourAssigner()
    let recs = [rec(1, "idle1", start: 1), rec(2, "work1", status: "busy", start: 2),
                rec(3, "need1", status: "waiting", start: 3), rec(4, "work0", status: "busy", start: 0),
                rec(5, "need0", status: "waiting", start: 5), rec(6, "idleNil", start: nil), rec(7, "idle0", start: 0)]
    let rows = buildRows(inputs(recs), colours: &c)
    expectEqual(rows.map { $0.id }, ["need1", "need0", "work0", "work1", "idle0", "idle1", "idleNil"])
  }

  test("pending makes needsYou with cardText; registry waiting without pending sets answerInTerminal") {
    var c = ColourAssigner()
    let p = PendingRequest(id: "r1", sessionId: "a", toolName: "Bash",
                           toolInput: .object(["command": .string("ls -la")]), receivedAt: t0)
    let newer = PendingRequest(id: "r2", sessionId: "a", toolName: "Bash",
                               toolInput: .object(["command": .string("pwd")]), receivedAt: t0.addingTimeInterval(5))
    let recs = [rec(1, "a", status: "busy", start: 1), rec(2, "b", status: "waiting", waitingFor: "permission", start: 2)]
    let rows = buildRows(inputs(recs, pending: [p, newer]), colours: &c)
    let a = rows.first { $0.id == "a" }!, b = rows.first { $0.id == "b" }!
    expectEqual(a.state, .needsYou)
    expectEqual(a.pending?.id, "r2")
    expectEqual(a.cardText, "pwd")
    expectEqual(a.fullRequest, "pwd")
    expectEqual(a.answerInTerminal, false)
    expectEqual(a.doing, "Wants to run a command")
    expectEqual(b.state, .needsYou)
    expectEqual(b.answerInTerminal, true)
    expectEqual(b.cardText, nil)
    expectEqual(b.fullRequest, nil)
    expectEqual(b.doing, "Needs permission · answer in Terminal")
  }

  test("full request: the whole multi-line command; none for an input with nothing to show") {
    var c = ColourAssigner()
    let cmd = "a\nb\nc\nd\ne"
    let p = PendingRequest(id: "r1", sessionId: "a", toolName: "Bash", toolInput: .object(["command": .string(cmd)]), receivedAt: t0)
    let q = PendingRequest(id: "r2", sessionId: "b", toolName: "TodoWrite", toolInput: .object([:]), receivedAt: t0)
    let rows = buildRows(inputs([rec(1, "a", start: 1), rec(2, "b", start: 2)], pending: [p, q]), colours: &c)
    expectEqual(rows.map { $0.cardText }, ["a\nb\nc\n…", "TodoWrite"])
    expectEqual(rows.map { $0.fullRequest }, [cmd, nil])
  }

  test("just decided: Allowed / Denied, not amber, while the registry still says waiting") {
    var c = ColourAssigner()
    let recs = [rec(1, "a", status: "waiting", waitingFor: "permission prompt", start: 1),
                rec(2, "b", status: "waiting", waitingFor: "permission prompt", start: 2),
                rec(3, "c", status: "busy", start: 3), rec(4, "d", status: "waiting", waitingFor: "permission prompt", start: 4)]
    let newer = PendingRequest(id: "r9", sessionId: "d", toolName: "Bash", toolInput: .object(["command": .string("ls")]), receivedAt: t0)
    let rows = buildRows(inputs(recs, pending: [newer], decisions: ["a": .allow, "b": .deny, "c": .allow, "d": .allow]), colours: &c)
    func row(_ id: String) -> AgentRow { rows.first { $0.id == id }! }
    expectEqual(row("a").doing, "Allowed"); expectEqual(row("a").state, .working); expectEqual(row("a").answerInTerminal, false)
    expectEqual(row("b").doing, "Denied"); expectEqual(row("b").state, .idle); expectEqual(row("b").answerInTerminal, false)
    expectEqual(row("c").doing, "Allowed"); expectEqual(row("c").state, .working)
    expectEqual(row("d").doing, "Wants to run a command", "a newer request wins")
    expectEqual(row("d").state, .needsYou); expectEqual(row("d").pending?.id, "r9")
    expectEqual(rows.map { $0.id }, ["d", "a", "c", "b"])
    expectEqual(headerCount(rows), "4 agents · 1 needs you")
  }

  test("layout change: order, cards, two-line doing lines and the expanded row count; wording alone doesn't") {
    var c = ColourAssigner()
    func build(_ recs: [SessionRecord], said: String = "hi", aIsReading: Bool = false, pending: [PendingRequest] = []) -> [AgentRow] {
      var s = TranscriptSummary(); s.lastPrompt = "go"; s.lastText = said
      var sa = s
      if aIsReading { sa.apply([.toolUse(name: "Read", input: .object(["file_path": .string("/a/b.ts")]), at: nil)]) }
      return buildRows(inputs(recs, summaries: ["a": sa, "b": s], pending: pending), colours: &c)
    }
    let a = rec(1, "a", status: "busy", start: 1), b = rec(2, "b", status: "busy", start: 2)
    let base = build([a, b])
    let req = PendingRequest(id: "r1", sessionId: "b", toolName: "Bash", toolInput: .object(["command": .string("ls")]), receivedAt: t0)
    let req2 = PendingRequest(id: "r2", sessionId: "b", toolName: "Bash", toolInput: .object(["command": .string("ls")]), receivedAt: t0 + 1)
    let reqA = PendingRequest(id: "r3", sessionId: "a", toolName: "Bash", toolInput: .object(["command": .string("ls")]), receivedAt: t0)
    expect(!rowLayoutChanged(base, build([a, b]), expandedId: nil), "same rows")
    let reading = build([a, b], aIsReading: true)
    expect(reading[0].doing != base[0].doing, "test setup: a's doing line changed")
    expect(!rowLayoutChanged(base, reading, expandedId: nil), "a's wording changed, nothing moved")
    expect(!rowLayoutChanged(base, build([a, b], said: "longer reply"), expandedId: nil), "unexpanded detail changed")
    expect(rowLayoutChanged(base, build([a, b], said: "longer reply"), expandedId: "a"), "expanded detail changed")
    expect(rowLayoutChanged(base, build([a, rec(2, "b", status: "waiting", waitingFor: "permission prompt", start: 2)]), expandedId: nil), "re-sorted")
    expect(rowLayoutChanged(base, build([a]), expandedId: nil), "row gone")
    let withA = build([a, b], pending: [reqA])
    expect(rowLayoutChanged(base, withA, expandedId: nil), "card above appeared")
    expect(rowLayoutChanged(withA, build([a, b]), expandedId: nil), "card above went")
    let withB = build([a, b], pending: [req])
    expect(rowLayoutChanged(base, withB, expandedId: nil), "card appeared (and re-sorted)")
    expect(rowLayoutChanged(withB, build([a, b], pending: [req2]), expandedId: nil), "a different request's card")
    expect(!rowLayoutChanged(withB, build([a, b], pending: [req]), expandedId: nil), "same card")
    let idleA = rec(1, "a", start: 1)
    expect(rowLayoutChanged(build([idleA, b]), build([rec(1, "a", status: "waiting", waitingFor: "question", start: 1), b]), expandedId: nil),
           "a two-line answer-in-Terminal line")
  }

  test("colours unique, sticky across rebuilds, folder colour reused after restart") {
    var c = ColourAssigner()
    let m1 = c.assign([("a", "~/one"), ("b", "~/two"), ("c", "~/three")])
    expectEqual(Set(m1.values).count, 3)
    // a and c end; only e starts, in ~/three: it takes c's old colour, not the lowest free index (a's 0)
    let m2 = c.assign([("b", "~/two")])
    expectEqual(m2["b"], m1["b"])
    let m3 = c.assign([("b", "~/two"), ("e", "~/three")])
    expectEqual(m1["a"], 0)
    expectEqual(m1["c"], 2)
    expectEqual(m3["e"], 2)
    expectEqual(m3["b"], m1["b"])
  }

  test("equal or missing startedAt falls back to pid; rebuild keeps colours") {
    var c = ColourAssigner()
    let eq = buildRows(inputs([rec(9, "z", start: 5), rec(3, "y", start: 5)]), colours: &c)
    expectEqual(eq.map { $0.id }, ["y", "z"])
    var c2 = ColourAssigner()
    let nils = buildRows(inputs([rec(9, "z"), rec(3, "y")]), colours: &c2)
    expectEqual(nils.map { $0.id }, ["y", "z"])
    let again = buildRows(inputs([rec(9, "z"), rec(3, "y")]), colours: &c2)
    expectEqual(again.map { $0.colorIndex }, nils.map { $0.colorIndex })
    expectEqual(Set(again.map { $0.colorIndex }).count, 2)
  }

  test("nine sessions: first eight unique, ninth deterministic") {
    let ids = (1...9).map { ("s\($0)", "~/f\($0)") }
    var c1 = ColourAssigner(), c2 = ColourAssigner()
    let m1 = c1.assign(ids), m2 = c2.assign(ids)
    expectEqual(Set((1...8).map { m1["s\($0)"]! }).count, 8)
    expectEqual(m1["s9"], m2["s9"])
    expect((0..<8).contains(m1["s9"]!), "in range")
    expectEqual(stableHash(""), 0xcbf29ce484222325)
    expectEqual(stableHash("a"), 0xaf63dc4c8601ec8c)
  }

  test("headerCount strings") {
    var c = ColourAssigner()
    expectEqual(headerCount([]), "No agents running")
    let one = buildRows(inputs([rec(1, "a", start: 1)]), colours: &c)
    expectEqual(headerCount(one), "1 agent")
    let four = buildRows(inputs([rec(1, "a", start: 1), rec(2, "b", start: 2), rec(3, "c", start: 3),
                                 rec(4, "d", status: "waiting", start: 4)]), colours: &c)
    expectEqual(headerCount(four), "4 agents · 1 needs you")
    let calm = buildRows(inputs([rec(1, "a", start: 1), rec(2, "b", start: 2)]), colours: &c)
    expectEqual(headerCount(calm), "2 agents")
  }

  test("long multi-line prompt and reply become single lines within limits") {
    var c = ColourAssigner()
    var s = TranscriptSummary()
    s.lastPrompt = String(repeating: "line of pasted text\n", count: 150)
    s.lastText = String(repeating: "reply words ", count: 90)
    let rows = buildRows(inputs([rec(1, "a", start: 1)], summaries: ["a": s]), colours: &c)
    expectEqual(rows[0].youAsked?.count, 140)
    expect(!(rows[0].youAsked ?? "").contains("\n"), "no newline")
    expectEqual(rows[0].claudeSaid?.count, 200)
  }
}
