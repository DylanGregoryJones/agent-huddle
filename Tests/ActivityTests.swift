import Foundation

func activityTests() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  test("tool wording table") {
    expectEqual(describeTool("Bash", .object(["command": .string("npm test")])), "Running npm test")
    expectEqual(describeTool("Edit", .object(["file_path": .string("/a/b/SalesFilter.tsx")])), "Editing SalesFilter.tsx")
    expectEqual(describeTool("Write", .object(["file_path": .string("/a/new.md")])), "Creating new.md")
    expectEqual(describeTool("Read", .object(["file_path": .string("/a/dateRange.ts")])), "Reading dateRange.ts")
    expectEqual(describeTool("Grep", .object(["pattern": .string("dateRange")])), "Searching for \"dateRange\"")
    expectEqual(describeTool("WebSearch", .object([:])), "Searching the web")
    expectEqual(describeTool("WebFetch", .object(["url": .string("https://code.claude.com/docs/x")])), "Reading code.claude.com")
    expectEqual(describeTool("Agent", .object([:])), "Running a helper agent")
    expectEqual(describeTool("mcp__claude_ai_Miro__board_show", .object([:])), "Using claude_ai_Miro")
    expectEqual(describeTool("TodoWrite", .object([:])), "Using TodoWrite")
  }
  test("long multi-line command stays one line") {
    let cmd = "cat <<'EOF' > x\n" + String(repeating: "a", count: 5000) + "\nEOF"
    let s = describeTool("Bash", .object(["command": .string(cmd)]))
    expect(!s.contains("\n")); expectEqual(s.count, "Running ".count + 40); expect(s.hasSuffix("…"))
  }
  test("card shows at most 3 lines") {
    expectEqual(cardText("Bash", .object(["command": .string("a\nb\nc\nd")])), "a\nb\nc\n…")
  }
  test("doing line precedence") {
    let pr = PendingRequest(id: "1", sessionId: "S", toolName: "Bash", toolInput: .object([:]), receivedAt: now)
    expectEqual(doingLine(status: "waiting", waitingFor: "permission prompt", pending: pr, latest: nil, hasPrompt: true, statusSince: now, now: now), "Wants to run a command")
    expectEqual(doingLine(status: "waiting", waitingFor: "permission prompt", pending: nil, latest: nil, hasPrompt: true, statusSince: now, now: now), "Needs permission · answer in Terminal")
    expectEqual(doingLine(status: "waiting", waitingFor: "question", pending: nil, latest: nil, hasPrompt: true, statusSince: now, now: now), "Needs you · answer in Terminal")
    expectEqual(doingLine(status: "busy", waitingFor: nil, pending: nil, latest: .thinking(at: nil), hasPrompt: true, statusSince: now, now: now), "Thinking…")
    expectEqual(doingLine(status: "idle", waitingFor: nil, pending: nil, latest: nil, hasPrompt: false, statusSince: now, now: now), "Ready")
    expectEqual(doingLine(status: "idle", waitingFor: nil, pending: nil, latest: nil, hasPrompt: true, statusSince: now - 240, now: now), "Done · waiting for you (4 min)")
    expectEqual(doingLine(status: "idle", waitingFor: nil, pending: nil, latest: nil, hasPrompt: true, statusSince: now - 20, now: now), "Done · waiting for you")
    expectEqual(doingLine(status: "idle", waitingFor: nil, pending: nil, latest: nil, hasPrompt: true, statusSince: now - 7300, now: now), "Done · waiting for you (2 h)")
  }
  test("times") {
    expectEqual(relativeAge(now - 30, now: now), "now"); expectEqual(relativeAge(now - 120, now: now), "2m")
    expectEqual(runningFor(since: now - 8040, now: now), "running 2h 14m"); expectEqual(runningFor(since: now - 20, now: now), "running <1m")
  }
  test("missing and odd inputs") {
    expectEqual(describeTool("Edit", .object([:])), "Editing a file")
    expectEqual(describeTool("Bash", .object(["command": .number(5)])), "Running a command")
    expectEqual(describeTool("Bash", .object(["command": .string("  \n ")])), "Running a command")
    expectEqual(describeTool("Grep", .object([:])), "Searching files")
    expectEqual(describeTool("Task", .object([:])), "Running a helper agent")
    expectEqual(describeTool("WebFetch", .object([:])), "Reading a page")
    expectEqual(describeTool("WebFetch", .object(["url": .number(1)])), "Reading a page")
    expectEqual(describeTool("WebFetch", .object(["url": .string("not a url")])), "Reading not a url")
    let long = describeTool("WebFetch", .object(["url": .string("bad\nurl " + String(repeating: "x", count: 500))]))
    expect(!long.contains("\n")); expectEqual(long.count, "Reading ".count + 40)
    expect(!describeTool("Edit", .object(["file_path": .string("/a/x\ny.txt")])).contains("\n"))
  }
  test("oneLine") {
    expectEqual(oneLine("a\t b\r\n c", max: 40), "a b c")
    expectEqual(oneLine("abcde", max: 5), "abcde")
    expectEqual(oneLine("abcdef", max: 5), "abcd…")
    expectEqual(oneLine("abc", max: 0), "")
    expectEqual(oneLine("ab cd", max: 4), "ab …")
    expectEqual(oneLine(" \n\t ", max: 5), "")
    expectEqual(oneLine("  a  b  ", max: 3), "a b")
  }
  test("huge inputs: cards and full requests read only what they show") {
    let big = String(repeating: "word \n", count: 1_000_000)   // 6 MB
    let started = Date()
    expectEqual(cardText("Bash", .object(["command": .string("a\nb\nc\n" + big)])), "a\nb\nc\n…")
    let mcp = cardText("mcp__s__t", .object(["body": .string(big), "nested": .object(["x": .string(big)])]))
    expectEqual(mcp, "s · t\nbody: " + String(repeating: "word ", count: 19) + "word…, nested: {1 key}")
    let full = fullRequestText("mcp__s__t", .object(["nested": .object(["x": .string(big)]), "z": .array(Array(repeating: .number(1), count: 100_000))]))
    expectEqual(full.count, 2000); expect(full.hasPrefix("nested: {\"x\":\"word \\nword"), String(full.prefix(30))); expect(full.hasSuffix("…"))
    let write = fullRequestText("Write", .object(["file_path": .string("/a"), "content": .string(big)]))
    expectEqual(write.count, 2000); expect(write.hasPrefix("file_path: /a\ncontent: word \nword"))
    _ = describeTool("Bash", .object(["command": .string(big)]))
    let elapsed = Date().timeIntervalSince(started)
    expect(elapsed < 0.1, "took \(elapsed) s")
  }
  test("Bash card: blank lines count only when something follows them") {
    expectEqual(cardText("Bash", .object(["command": .string("a\n\n\nb")])), "a\n\n\n…")
    expectEqual(cardText("Bash", .object(["command": .string("a\n\n\n\n")])), "a")
    expectEqual(cardText("Bash", .object(["command": .string("a\n\nb\n\n\n")])), "a\n\nb")
    expectEqual(cardText("Bash", .object([:])), "")
  }
  test("describePending") {
    expectEqual(describePending("Edit", .object(["file_path": .string("/a/f.ts")])), "Wants to edit f.ts")
    expectEqual(describePending("Write", .object(["file_path": .string("/a/g.md")])), "Wants to edit g.md")
    expectEqual(describePending("WebFetch", .object([:])), "Wants to use WebFetch")
  }
  test("cardText") {
    expectEqual(cardText("Edit", .object(["file_path": .string(NSHomeDirectory() + "/x/y.swift")])), "~/x/y.swift")
    expectEqual(cardText("WebFetch", .object(["url": .string("https://a.b/c")])), "https://a.b/c")
    expectEqual(cardText("WebSearch", .object(["query": .string("swift")])), "swift")
    expectEqual(cardText("mcp__s__t", .object([:])), "s · t")
    expectEqual(cardText("TodoWrite", .object([:])), "TodoWrite")
    expectEqual(cardText("Bash", .object(["command": .string("a\r\nb\r\nc\r\n")])), "a\nb\nc")
    expectEqual(cardText("Bash", .object(["command": .string("a\nb\nc\n")])), "a\nb\nc")
    expectEqual(cardText("Bash", .object(["command": .string("a\nb")])), "a\nb")
  }
  test("describePending names an MCP tool's server") {
    expectEqual(describePending("mcp__claude_ai_Miro__board_show", .object([:])), "Wants to use claude_ai_Miro")
    expectEqual(describePending("Grep", .object(["pattern": .string("x")])), "Wants to use Grep")
  }
  test("cardText: MCP shows server · tool, then its input as key: value") {
    expectEqual(cardText("mcp__claude_ai_Supabase__execute_sql", .object(["query": .string("select *\n  from users")])),
                "claude_ai_Supabase · execute_sql\nquery: select * from users")
    let input: JSONValue = .object([
      "query": .string("sales\n figures"), "limit": .number(5), "ratio": .number(0.5), "deep": .bool(true), "none": .null,
      "filters": .object(["a": .number(1), "b": .number(2)]), "ids": .array([.string("x"), .string("y"), .string("z")]),
      "one": .array([.number(1)]), "empty": .object([:]),
    ])
    expectEqual(cardText("mcp__s__t", input),
                "s · t\nquery: sales figures, deep: true, empty: {}, filters: {2 keys}, ids: [3 items], limit: 5, none: null, one: [1 item], ratio: 0.5")
    let huge = cardText("mcp__s__t", .object(["body": .string(String(repeating: "word ", count: 1000)), "to": .string("x@y.z")]))
    let kv = huge.components(separatedBy: "\n")
    expectEqual(kv.count, 2)
    expect(kv[1].hasPrefix("body: word word"), kv[1]); expect(kv[1].contains("…, to: x@y.z"), "a long value does not hide the next key")
    var many: [String: JSONValue] = [:]
    for i in 10..<40 { many["k\(i)"] = .string(String(repeating: "v", count: 40)) }
    let capped = cardText("mcp__s__t", .object(many)).components(separatedBy: "\n")
    expectEqual(capped.count, 2); expectEqual(capped[1].count, 300); expect(capped[1].hasSuffix("…"))
  }
  test("cardText: Grep/Glob pattern and path, Agent description, Skill name") {
    let home = Paths.home
    expectEqual(cardText("Grep", .object(["pattern": .string("dateRange"), "path": .string(home + "/td/src")])), "dateRange\nin ~/td/src")
    expectEqual(cardText("Glob", .object(["pattern": .string("**/*.ts")])), "**/*.ts")
    expectEqual(cardText("Agent", .object(["description": .string("Review the diff"), "prompt": .string("long\nbrief")])), "Review the diff")
    expectEqual(cardText("Task", .object(["prompt": .string("do x\nthen y")])), "do x then y")
    expectEqual(cardText("Skill", .object(["skill": .string("superpowers:brainstorming")])), "superpowers:brainstorming")
  }
  test("cardText: any other tool shows its name and its main argument") {
    expectEqual(cardText("KillShell", .object(["shell_id": .string("bash_1")])), "KillShell\nshell_id: bash_1")
    expectEqual(cardText("NotebookRead", .object(["cell_id": .string("c2"), "notebook_path": .string("/n.ipynb")])),
                "NotebookRead\nnotebook_path: /n.ipynb, cell_id: c2")
    expectEqual(cardText("TodoWrite", .object(["todos": .array([.object([:]), .object([:])])])), "TodoWrite\ntodos: [2 items]")
    expectEqual(cardText("Grep", .object([:])), "Grep")
    expectEqual(cardText("Agent", .object([:])), "Agent")
    expectEqual(cardText("Skill", .object(["args": .string("x")])), "Skill\nargs: x")
  }
  test("fullRequestText: whole command, or every key on its own line, capped") {
    let cmd = "cat <<'EOF' > x\nline 1\nline 2\nline 3\nline 4\nEOF"
    expectEqual(fullRequestText("Bash", .object(["command": .string(cmd + "\n")])), cmd)
    let long = fullRequestText("Bash", .object(["command": .string(String(repeating: "a", count: 5000))]))
    expectEqual(long.count, 2000); expect(long.hasSuffix("…"))
    expectEqual(fullRequestText("Edit", .object(["file_path": .string("/a/b.ts"), "old_string": .string("x\ny"), "new_string": .string("z")])),
                "file_path: /a/b.ts\nnew_string: z\nold_string: x\ny")
    expectEqual(fullRequestText("mcp__s__t", .object(["query": .string("a"), "limit": .number(5),
                                                      "opts": .object(["x": .array([.number(1), .string("two/three")])])])),
                "query: a\nlimit: 5\nopts: {\"x\":[1,\"two/three\"]}")
    expectEqual(fullRequestText("TodoWrite", .object([:])), "")
    expectEqual(fullRequestText("Bash", .object([:])), "")
  }
  test("doing line busy and boundaries") {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func busy(_ e: TranscriptEvent?) -> String {
      doingLine(status: "busy", waitingFor: nil, pending: nil, latest: e, hasPrompt: true, statusSince: now, now: now)
    }
    expectEqual(busy(.toolUse(name: "Read", input: .object(["file_path": .string("/a/b.ts")]), at: nil)), "Reading b.ts")
    expectEqual(busy(.text("hi", at: nil)), "Writing a reply")
    expectEqual(busy(nil), "Working…")
    func idle(_ secs: Double) -> String {
      doingLine(status: "idle", waitingFor: nil, pending: nil, latest: nil, hasPrompt: true, statusSince: now - secs, now: now)
    }
    expectEqual(idle(59), "Done · waiting for you")
    expectEqual(idle(60), "Done · waiting for you (1 min)")
    expectEqual(idle(59 * 60), "Done · waiting for you (59 min)")
    expectEqual(idle(60 * 60), "Done · waiting for you (1 h)")
    expectEqual(relativeAge(now - 7200, now: now), "2h")
    expectEqual(relativeAge(nil, now: now), "")
    expectEqual(runningFor(since: nil, now: now), "")
  }
}
