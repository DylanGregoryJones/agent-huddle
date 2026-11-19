import Foundation

let samplePayload = Data(#"{"session_id":"S1","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/x"}"#.utf8)
let hookBinary = (((#filePath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
  .appendingPathComponent("build/huddle-permission-hook")

final class Lock<T> {
  private var v: T
  private let l = NSLock()
  init(_ v: T) { self.v = v }
  func get() -> T { l.lock(); defer { l.unlock() }; return v }
  func set(_ x: T) { l.lock(); v = x; l.unlock() }
}

/// Fake panel: accepts connections on a background thread and hands each to `handler`.
private final class FakePanel {
  let listenFd: Int32
  let accepted = Lock(0)
  private let stop = Lock(false)
  private let done = DispatchSemaphore(value: 0)

  init(path: String, handler: @escaping (Int32) -> Void) throws {
    listenFd = try UnixSocket.listen(path: path)
    let fd = listenFd
    let stop = self.stop, accepted = self.accepted, done = self.done
    Thread.detachNewThread {
      while !stop.get() {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, 50) > 0, let c = UnixSocket.accept(fd) {
          accepted.set(accepted.get() + 1)
          handler(c)
          close(c)
        }
      }
      done.signal()
    }
  }

  func shutdown() {
    stop.set(true)
    done.wait()
    close(listenFd)
  }
}

private struct HookRun { let status: Int32; let stdout: String; let elapsed: Double; let timedOut: Bool }

private func runHook(dir: String, sessions: String, termProgram: String? = "Apple_Terminal",
                     stdin: Data = samplePayload, timeout: Double = 5,
                     whileRunning: ((Process) -> Void)? = nil) -> HookRun {
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: hookBinary)
  var env = ["PATH": "/usr/bin:/bin", "HOME": dir, "AGENT_HUDDLE_DIR": dir, "AGENT_HUDDLE_SESSIONS_DIR": sessions]
  if let t = termProgram { env["TERM_PROGRAM"] = t }
  proc.environment = env
  let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
  proc.standardInput = inPipe
  proc.standardOutput = outPipe
  proc.standardError = errPipe
  let start = Date()
  do { try proc.run() } catch { fatalError("cannot run hook: \(error)") }
  inPipe.fileHandleForWriting.write(stdin)
  try? inPipe.fileHandleForWriting.close()
  var out = Data()
  let reading = DispatchSemaphore(value: 0)
  Thread.detachNewThread { out = outPipe.fileHandleForReading.readDataToEndOfFile(); reading.signal() }
  whileRunning?(proc)
  var timedOut = false
  while proc.isRunning {
    if Date().timeIntervalSince(start) > timeout { timedOut = true; proc.terminate(); break }
    usleep(5000)
  }
  proc.waitUntilExit()
  _ = reading.wait(timeout: .now() + 2)
  return HookRun(status: proc.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                 elapsed: Date().timeIntervalSince(start), timedOut: timedOut)
}

private func readRequest(_ fd: Int32) -> (id: String, toolName: String)? {
  guard case .line(let l) = LineReader(fd: fd).readLine(timeoutMs: 3000),
        let r = decodeRequestLine(l, receivedAt: Date()) else { return nil }
  return (r.id, r.toolName)
}

func hookTests() {
  let p = samplePayload
  test("gate passes through outside Terminal") { expectEqual(gate(payloadData: p, env: ["TERM_PROGRAM": "Orca"]), .passThrough) }
  test("gate passes through with no TERM_PROGRAM") { expectEqual(gate(payloadData: p, env: [:]), .passThrough) }
  test("gate passes through question tools") {
    for name in ["AskUserQuestion", "ExitPlanMode"] {
      let q = Data(#"{"session_id":"S1","tool_name":"\#(name)","tool_input":{}}"#.utf8)
      expectEqual(gate(payloadData: q, env: ["TERM_PROGRAM": "Apple_Terminal"]), .passThrough)
    }
  }
  test("gate passes through unparseable payload") {
    expectEqual(gate(payloadData: Data("nope".utf8), env: ["TERM_PROGRAM": "Apple_Terminal"]), .passThrough)
  }
  test("gate handles Terminal Bash") {
    expectEqual(gate(payloadData: p, env: ["TERM_PROGRAM": "Apple_Terminal"]),
                .handle(HookPayload(sessionId: "S1", toolName: "Bash", toolInput: .object(["command": .string("ls")]), cwd: "/x")))
  }
  test("decision strings are exact") {
    expectEqual(decisionOutput(.allow), #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
    expectEqual(decisionOutput(.deny), #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Agent Huddle","interrupt":true}}}"#)
  }
  test("request/decision lines round-trip") {
    let payload = parseHookPayload(p)!
    let line = encodeRequestLine(id: "abc", payload: payload)
    expectEqual(line.last, 0x0A)
    expectEqual(line.filter { $0 == 0x0A }.count, 1)
    let now = Date()
    let r = decodeRequestLine(line, receivedAt: now)
    expectEqual(r, PendingRequest(id: "abc", sessionId: "S1", toolName: "Bash",
                                  toolInput: .object(["command": .string("ls")]), receivedAt: now))
    for d in [Decision.allow, .deny] {
      let dl = encodeDecisionLine(id: "abc", d)
      expectEqual(dl.last, 0x0A)
      let back = decodeDecisionLine(dl)
      expectEqual(back?.id, "abc"); expectEqual(back?.decision, d)
    }
    expect(decodeDecisionLine(Data("garbage".utf8)) == nil)
    expect(decodeDecisionLine(Data(#"{"type":"decision","id":"a","behavior":"maybe"}"#.utf8)) == nil)
    expect(decodeRequestLine(Data("garbage".utf8), receivedAt: now) == nil)
  }
  test("multi-line command survives the wire") {
    let payload = HookPayload(sessionId: "S", toolName: "Bash", toolInput: .object(["command": .string("a\nb\n\"c\"")]), cwd: nil)
    let line = encodeRequestLine(id: "i", payload: payload)
    expectEqual(line.filter { $0 == 0x0A }.count, 1)
    expectEqual(decodeRequestLine(line, receivedAt: Date())?.toolInput, payload.toolInput)
  }
  test("answered-elsewhere needs waiting first") {
    var w = AnsweredElsewhereWatch()
    expect(!w.update(status: "busy")); expect(!w.update(status: "waiting"))
    expect(!w.update(status: "busy")); expect(w.update(status: "busy"))
  }
  test("answered-elsewhere ignores a single bad read") {
    var w = AnsweredElsewhereWatch()
    expect(!w.update(status: "waiting")); expect(!w.update(status: nil)); expect(!w.update(status: "waiting"))
    expect(!w.update(status: nil)); expect(w.update(status: nil))
  }
  test("answered-elsewhere: missing record after waiting counts") {
    var w = AnsweredElsewhereWatch()
    expect(!w.update(status: "waiting")); expect(!w.update(status: nil)); expect(w.update(status: nil))
  }
  test("answered-elsewhere: Claude's pid dying after being seen alive counts") {
    var w = AnsweredElsewhereWatch()
    expect(!w.update(status: "waiting", alive: false), "never seen alive: a stale file, keep waiting")
    expect(!w.update(status: "waiting", alive: nil)); expect(!w.update(status: "waiting", alive: true))
    expect(!w.update(status: "waiting", alive: nil), "no record is not a dead pid")
    expect(w.update(status: "waiting", alive: false))
  }
  test("LineReader splits lines, times out, reports close") {
    var fds: [Int32] = [0, 0]
    expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let r = LineReader(fd: fds[0])
    expectEqual(r.readLine(timeoutMs: 20), .timeout)
    expect(UnixSocket.writeAll(fds[1], Data("one\ntwo\npart".utf8)))
    expectEqual(r.readLine(timeoutMs: 500), .line(Data("one".utf8)))
    expectEqual(r.readLine(timeoutMs: 500), .line(Data("two".utf8)))
    expectEqual(r.readLine(timeoutMs: 20), .timeout)
    close(fds[1])
    expectEqual(r.readLine(timeoutMs: 500), .closed)
    close(fds[0])
  }

  // Integration: runs build/huddle-permission-hook
  func fresh() -> (dir: String, sessions: String) { (makeTempDir("hk"), makeTempDir("hs")) }

  test("no panel: exits 0, empty stdout, under 0.5 s") {
    let (d, s) = fresh()
    let r = runHook(dir: d, sessions: s)
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(r.elapsed < 0.5, "took \(r.elapsed)")
  }
  test("stale socket file, no listener: exits 0, empty stdout, under 0.5 s") {
    let (d, s) = fresh()
    FileManager.default.createFile(atPath: d + "/huddle.sock", contents: Data("x".utf8))
    let r = runHook(dir: d, sessions: s)
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(r.elapsed < 0.5, "took \(r.elapsed)")
  }
  test("panel allows: stdout == decisionOutput(.allow) + newline") {
    let (d, s) = fresh()
    let tool = Lock<String?>(nil)
    let panel = try! FakePanel(path: d + "/huddle.sock") { fd in
      guard let req = readRequest(fd) else { return }
      tool.set(req.toolName)
      _ = UnixSocket.writeAll(fd, encodeDecisionLine(id: req.id, .allow))
    }
    let r = runHook(dir: d, sessions: s)
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, decisionOutput(.allow) + "\n"); expectEqual(tool.get(), "Bash")
    expect(!r.timedOut)
  }
  test("panel denies: stdout == decisionOutput(.deny) + newline") {
    let (d, s) = fresh()
    let panel = try! FakePanel(path: d + "/huddle.sock") { fd in
      guard let req = readRequest(fd) else { return }
      _ = UnixSocket.writeAll(fd, encodeDecisionLine(id: req.id, .deny))
    }
    let r = runHook(dir: d, sessions: s)
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, decisionOutput(.deny) + "\n")
  }
  test("decision with another id is skipped, then the right one is used") {
    let (d, s) = fresh()
    let panel = try! FakePanel(path: d + "/huddle.sock") { fd in
      guard let req = readRequest(fd) else { return }
      _ = UnixSocket.writeAll(fd, encodeDecisionLine(id: "someone-else", .deny))
      _ = UnixSocket.writeAll(fd, encodeDecisionLine(id: req.id, .allow))
    }
    let r = runHook(dir: d, sessions: s)
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, decisionOutput(.allow) + "\n"); expect(!r.timedOut)
  }
  test("panel closes connection: exits 0, empty stdout") {
    let (d, s) = fresh()
    let panel = try! FakePanel(path: d + "/huddle.sock") { fd in _ = readRequest(fd) }
    let r = runHook(dir: d, sessions: s)
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(!r.timedOut)
  }
  test("answered elsewhere: exits within 1 s of registry flip") {
    let (d, s) = fresh()
    let regPath = s + "/12345.json"
    func write(_ status: String) {
      try? Data(#"{"pid":12345,"sessionId":"S1","cwd":"/x","status":"\#(status)"}"#.utf8).write(to: URL(fileURLWithPath: regPath))
    }
    write("waiting")
    let release = DispatchSemaphore(value: 0)
    let panel = try! FakePanel(path: d + "/huddle.sock") { fd in
      _ = readRequest(fd)
      _ = release.wait(timeout: .now() + 6)   // hold the connection open, never answer
    }
    var flippedAt = Date()
    let r = runHook(dir: d, sessions: s, timeout: 4) { proc in
      Thread.sleep(forTimeInterval: 0.6)
      expect(proc.isRunning, "hook exited before the registry flip")
      flippedAt = Date()
      write("busy")
    }
    release.signal()
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(!r.timedOut, "hook did not exit")
    expect(Date().timeIntervalSince(flippedAt) < 1.5, "slow")
    expect(r.elapsed - 0.6 < 1.0, "exit \(r.elapsed - 0.6)s after flip")
  }
  test("Claude dies while the request waits: exits within 1 s though the registry still says waiting") {
    let (d, s) = fresh()
    let claude = Process()   // stands in for the Claude process
    claude.executableURL = URL(fileURLWithPath: "/bin/sleep")
    claude.arguments = ["30"]
    try! claude.run()
    defer { if claude.isRunning { claude.terminate() }; claude.waitUntilExit() }
    let json = #"{"pid":\#(claude.processIdentifier),"sessionId":"S1","cwd":"/x","status":"waiting"}"#
    try? Data(json.utf8).write(to: URL(fileURLWithPath: s + "/\(claude.processIdentifier).json"))
    let release = DispatchSemaphore(value: 0)
    let panel = try! FakePanel(path: d + "/huddle.sock") { fd in
      _ = readRequest(fd)
      _ = release.wait(timeout: .now() + 6)   // hold the connection open, never answer
    }
    var diedAt = Date()
    let r = runHook(dir: d, sessions: s, timeout: 4) { proc in
      Thread.sleep(forTimeInterval: 0.6)
      expect(proc.isRunning, "hook exited while Claude was alive")
      diedAt = Date()
      claude.terminate(); claude.waitUntilExit()   // reaped, so the pid is really gone
    }
    release.signal()
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(!r.timedOut, "hook did not exit")
    expect(Date().timeIntervalSince(diedAt) < 1.5, "took \(Date().timeIntervalSince(diedAt))s after Claude died")
  }
  test("non-Terminal env: exits 0 without connecting") {
    let (d, s) = fresh()
    let panel = try! FakePanel(path: d + "/huddle.sock") { _ in }
    let r = runHook(dir: d, sessions: s, termProgram: "Orca")
    Thread.sleep(forTimeInterval: 0.5)
    let n = panel.accepted.get()
    panel.shutdown()
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expectEqual(n, 0)
  }
  test("stale real socket (listener closed, file left): exits 0, empty stdout, under 0.5 s") {
    let (d, s) = fresh()
    let fd = try! UnixSocket.listen(path: d + "/huddle.sock")
    close(fd)
    expect(FileManager.default.fileExists(atPath: d + "/huddle.sock"))
    let r = runHook(dir: d, sessions: s)
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(r.elapsed < 0.5, "took \(r.elapsed)")
  }
  test("huge request to a panel that never accepts: still notices answered-elsewhere within 2 s") {
    let (d, s) = fresh()
    let regPath = s + "/12345.json"
    func write(_ status: String) {
      try? Data(#"{"pid":12345,"sessionId":"S1","cwd":"/x","status":"\#(status)"}"#.utf8).write(to: URL(fileURLWithPath: regPath))
    }
    write("waiting")
    let listenFd = try! UnixSocket.listen(path: d + "/huddle.sock")  // listens, never accepts
    let big = String(repeating: "x", count: 200_000)
    let payload = Data(#"{"session_id":"S1","tool_name":"Write","tool_input":{"content":"\#(big)"},"cwd":"/x"}"#.utf8)
    var flippedAt = Date()
    let r = runHook(dir: d, sessions: s, stdin: payload, timeout: 6) { _ in
      Thread.sleep(forTimeInterval: 0.6)
      flippedAt = Date(); write("busy")
    }
    close(listenFd)
    expectEqual(r.status, 0); expectEqual(r.stdout, ""); expect(!r.timedOut, "hook hung")
    expect(Date().timeIntervalSince(flippedAt) < 2, "took \(Date().timeIntervalSince(flippedAt))s after flip")
  }
}
