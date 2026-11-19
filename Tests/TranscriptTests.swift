import Foundation

func transcriptTests() {
  func tempFile(_ content: String) -> String {
    let p = makeTempDir() + "/t.jsonl"
    FileManager.default.createFile(atPath: p, contents: Data(content.utf8))
    return p
  }
  func append(_ s: String, to p: String) {
    let h = FileHandle(forWritingAtPath: p)!
    h.seekToEndOfFile(); h.write(Data(s.utf8)); h.closeFile()
  }
  func line(_ text: String) -> String {
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}"
  }

  test("summary from fixture") {
    let p = makeTempDir() + "/transcript.jsonl"
    FileManager.default.createFile(atPath: p, contents: fixture("transcript.jsonl"))
    var s = TranscriptSummary(); let tail = TranscriptTail(path: p)
    s.apply(tail.readNew())
    expectEqual(s.title, "Agent huddle corner widget"); expectEqual(s.lastPrompt, "fix the date filter")
    expectEqual(s.lastText, "The filter was using UTC midnight.")
    expectEqual(s.steps.map(\.name), ["Bash", "Edit", "Read", "Grep"])
    if case .toolUse(let n, _, let at)? = s.latest { expectEqual(n, "Bash"); expect(at != nil, "timestamp parsed") } else { expect(false, "latest") }
  }
  test("parse line shapes") {
    expectEqual(parseTranscriptLine(Data("{\"type\":\"user\"}".utf8)), [])
    expectEqual(parseTranscriptLine(Data("garbage".utf8)), [])
    let multi = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"x\"},{\"type\":\"text\",\"text\":\"hi\"}]}}"
    expectEqual(parseTranscriptLine(Data(multi.utf8)), [.thinking(at: nil), .text("hi", at: nil)])
  }
  test("partial last line waits for its newline") {
    let p = tempFile(line("one") + "\n" + line("two") + "\n" + String(line("three").prefix(30)))
    let tail = TranscriptTail(path: p)
    expectEqual(tail.readNew(), [.text("one", at: nil), .text("two", at: nil)])
    append(String(line("three").dropFirst(30)) + "\n", to: p)
    expectEqual(tail.readNew(), [.text("three", at: nil)])
  }
  test("readNew returns nothing new on second call") {
    let tail = TranscriptTail(path: tempFile(line("a") + "\n"))
    expectEqual(tail.readNew().count, 1)
    expectEqual(tail.readNew(), [])
  }
  test("shrunk file restarts from 0") {
    let p = tempFile(line("first long one") + "\n" + line("second") + "\n")
    let tail = TranscriptTail(path: p)
    _ = tail.readNew()
    try? Data((line("z") + "\n").utf8).write(to: URL(fileURLWithPath: p))
    expectEqual(tail.readNew(), [.text("z", at: nil)])
  }
  test("missing file gives no events") {
    expectEqual(TranscriptTail(path: "/nonexistent/x.jsonl").readNew(), [])
  }
  test("transcriptPath direct and fallback scan") {
    let dir = makeTempDir()
    try? FileManager.default.createDirectory(atPath: dir + "/odd-slug", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/odd-slug/abc.jsonl", contents: Data())
    expectEqual(transcriptPath(cwd: "/Users/x/y", sessionId: "abc", projectsDir: dir), dir + "/odd-slug/abc.jsonl")
    expectEqual(transcriptPath(cwd: "/Users/x/y", sessionId: "nope", projectsDir: dir), nil)
    try? FileManager.default.createDirectory(atPath: dir + "/-Users-x-my-app", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/-Users-x-my-app/def.jsonl", contents: Data())
    expectEqual(transcriptPath(cwd: "/Users/x/my.app", sessionId: "def", projectsDir: dir), dir + "/-Users-x-my-app/def.jsonl")
  }
  test("directTranscriptPath is the slug path, without touching the disk") {
    expectEqual(directTranscriptPath(cwd: "/Users/x/my.app", sessionId: "def", projectsDir: "/nonexistent"),
                "/nonexistent/-Users-x-my-app/def.jsonl")
  }
  test("summary keeps four newest steps and ignores prompts for latest") {
    var s = TranscriptSummary()
    s.apply((1...6).map { .toolUse(name: "T\($0)", input: .null, at: nil) })
    expectEqual(s.steps.map(\.name), ["T6", "T5", "T4", "T3"])
    s.apply([.prompt("p"), .title("t")])
    expectEqual(s.lastPrompt, "p")
    if case .toolUse(let n, _, _)? = s.latest { expectEqual(n, "T6") } else { expect(false, "latest") }
  }
  test("large transcript reads in linear time") {
    func toolLine(_ i: Int) -> String {
      let pad = String(repeating: "x", count: 500)
      return "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"T\(i)\",\"input\":{\"command\":\"\(pad)\"}}]}}\n"
    }
    var content = ""
    for i in 0..<20_000 { content += toolLine(i) }
    let p = tempFile(content)
    let tail = TranscriptTail(path: p)
    let t0 = Date()
    let events = tail.readNew()
    expect(Date().timeIntervalSince(t0) < 3, "first read took \(Date().timeIntervalSince(t0))s")
    expectEqual(events.count, 20_000)
    var s = TranscriptSummary(); s.apply(events)
    expectEqual(s.steps.count, 4)
    expectEqual(s.steps.first?.name, "T19999")
    append(toolLine(20_000) + toolLine(20_001), to: p)
    expectEqual(tail.readNew().count, 2)
  }
}
