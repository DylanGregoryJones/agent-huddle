import Foundation

private func payload(session: String, command: String = "ls") -> Data {
  let obj: [String: Any] = ["session_id": session, "tool_name": "Bash", "tool_input": ["command": command], "cwd": "/x"]
  return try! JSONSerialization.data(withJSONObject: obj)
}

private final class RunningHook {
  let proc = Process()
  let outPath: String
  init(dir: String, sessions: String, stdin: Data) {
    outPath = dir + "/out-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: outPath, contents: nil)
    proc.executableURL = URL(fileURLWithPath: hookBinary)
    proc.environment = ["PATH": "/usr/bin:/bin", "HOME": dir, "AGENT_HUDDLE_DIR": dir,
                        "AGENT_HUDDLE_SESSIONS_DIR": sessions, "TERM_PROGRAM": "Apple_Terminal"]
    let inPipe = Pipe()
    proc.standardInput = inPipe
    proc.standardOutput = FileHandle(forWritingAtPath: outPath)
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { fatalError("cannot run hook: \(error)") }
    inPipe.fileHandleForWriting.write(stdin)
    try? inPipe.fileHandleForWriting.close()
  }
  var stdout: String { String(decoding: FileManager.default.contents(atPath: outPath) ?? Data(), as: UTF8.self) }
  func waitExit(_ seconds: Double = 5) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while proc.isRunning && Date() < end { usleep(5000) }
    return !proc.isRunning
  }
  func kill9() { Darwin.kill(proc.processIdentifier, SIGKILL) }
  func cleanup() { if proc.isRunning { proc.terminate() }; proc.waitUntilExit() }
}

private func waitFor(_ seconds: Double = 5, _ cond: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { if cond() { return true }; usleep(5000) }
  return cond()
}

func permissionServerTests() {
  func setup() -> (dir: String, sessions: String, server: PermissionServer, changes: Lock<[[PendingRequest]]>) {
    let dir = makeTempDir("ps"), sessions = makeTempDir("pss")
    let changes = Lock<[[PendingRequest]]>([])
    let server = PermissionServer(socketPath: dir + "/huddle.sock",
                                  callbackQueue: DispatchQueue(label: "test.callback")) { snap in
      changes.set(changes.get() + [snap])
    }
    try! server.start()
    return (dir, sessions, server, changes)
  }

  test("a server whose start failed can be started again once the folder is fixed") {
    let dir = makeTempDir()
    let blocker = dir + "/huddle"
    FileManager.default.createFile(atPath: blocker, contents: Data())   // a file where the folder should be
    let server = PermissionServer(socketPath: blocker + "/huddle.sock", onChange: { _ in })
    expect((try? server.start()) == nil, "start should fail while a file blocks the folder")
    try FileManager.default.removeItem(atPath: blocker)
    try server.start()
    expect(FileManager.default.fileExists(atPath: blocker + "/huddle.sock"))
    server.stop()
  }

  test("request appears in pending with tool and session") {
    let (d, s, server, changes) = setup()
    let h = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { h.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 }, "request never arrived")
    expectEqual(server.pending.first?.sessionId, "S1")
    expectEqual(server.pending.first?.toolName, "Bash")
    expectEqual(server.pending.first?.toolInput, .object(["command": .string("ls")]))
    expect(waitFor { changes.get().last?.count == 1 }, "onChange not called")
  }

  test("decide(.allow) makes the hook print the allow string and pending empties") {
    let (d, s, server, changes) = setup()
    let h = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { h.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 })
    let id = server.pending[0].id
    expect(server.decide(id: id, .allow))
    expect(h.waitExit(), "hook did not exit")
    expectEqual(h.stdout, decisionOutput(.allow) + "\n")
    expectEqual(server.pending.count, 0)
    expect(waitFor { changes.get().last?.isEmpty == true }, "onChange not called with empty")
    expect(!server.decide(id: id, .allow), "second decide must fail")
  }

  test("decide(.deny) with a 300 KB request prints the deny string") {
    let (d, s, server, _) = setup()
    let big = String(repeating: "x", count: 300_000)
    let h = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1", command: big))
    defer { h.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 }, "large request never arrived")
    expect(server.decide(id: server.pending[0].id, .deny))
    expect(h.waitExit())
    expectEqual(h.stdout, decisionOutput(.deny) + "\n")
  }

  test("newer request from same session supersedes older") {
    let (d, s, server, _) = setup()
    let a = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { a.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 })
    let idA = server.pending[0].id
    let b = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { b.cleanup() }
    expect(waitFor { server.pending.first.map { $0.id != idA } ?? false }, "B never replaced A")
    expectEqual(server.pending.map(\.sessionId), ["S1"])
    expect(a.waitExit(), "A should exit")
    expectEqual(a.proc.terminationStatus, 0)
    expectEqual(a.stdout, "")
    expect(b.proc.isRunning, "B should still be waiting")
    expect(!server.decide(id: idA, .allow), "decide on superseded id must fail")
  }

  test("requests from different sessions coexist, oldest first") {
    let (d, s, server, _) = setup()
    let a = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { a.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 })
    let b = RunningHook(dir: d, sessions: s, stdin: payload(session: "S2"))
    defer { b.cleanup() }
    expect(waitFor { server.pending.count == 2 })
    expectEqual(server.pending.map(\.sessionId), ["S1", "S2"])
    expect(a.proc.isRunning && b.proc.isRunning)
  }

  test("hook killed: request removed; decide on it returns false, no crash") {
    let (d, s, server, _) = setup()
    let h = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { h.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 })
    let id = server.pending[0].id
    h.kill9()
    expect(waitFor { server.pending.isEmpty }, "request not removed after kill")
    expect(!server.decide(id: id, .allow))
  }

  test("start() over a stale socket file succeeds; stop() unlinks") {
    let dir = makeTempDir("ps")
    let path = dir + "/huddle.sock"
    FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
    let server = PermissionServer(socketPath: path, callbackQueue: DispatchQueue(label: "test.cb")) { _ in }
    do { try server.start() } catch { expect(false, "start threw \(error)") }
    let fd = UnixSocket.connect(path: path, timeoutMs: 500)
    expect(fd != nil, "cannot connect to rebound socket")
    if let fd = fd { close(fd) }
    server.stop()
    expect(!FileManager.default.fileExists(atPath: path), "socket not unlinked")
  }

  test("garbage line and early disconnect leave pending empty") {
    let (d, _, server, _) = setup()
    defer { server.stop() }
    if let fd = UnixSocket.connect(path: d + "/huddle.sock", timeoutMs: 500) {
      _ = UnixSocket.writeAll(fd, Data("garbage\n".utf8))
      usleep(50_000); close(fd)
    }
    if let fd = UnixSocket.connect(path: d + "/huddle.sock", timeoutMs: 500) {
      _ = UnixSocket.writeAll(fd, Data("{\"type\":\"req".utf8)); close(fd)
    }
    usleep(100_000)
    expectEqual(server.pending.count, 0)
  }

  func rawReq(_ id: String, _ session: String, command: String = "ls") -> Data {
    let obj: [String: Any] = ["type": "request", "id": id, "sessionId": session, "toolName": "Bash", "toolInput": ["command": command]]
    return try! JSONSerialization.data(withJSONObject: obj) + Data([0x0A])
  }
  func isClosedByPeer(_ fd: Int32) -> Bool {
    waitFor(2) {
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&p, 1, 0) > 0 else { return false }
      var b = [UInt8](repeating: 0, count: 16)
      return read(fd, &b, 16) == 0
    }
  }

  test("older connection finishing its line after a newer one is dropped, not the newer") {
    let (d, _, server, _) = setup()
    defer { server.stop() }
    let path = d + "/huddle.sock"
    let a = UnixSocket.connect(path: path, timeoutMs: 500)!
    let line = rawReq("A", "S1")
    _ = UnixSocket.writeAll(a, line.prefix(10))
    usleep(100_000)
    let b = UnixSocket.connect(path: path, timeoutMs: 500)!
    _ = UnixSocket.writeAll(b, rawReq("B", "S1"))
    expect(waitFor { server.pending.map(\.id) == ["B"] })
    _ = UnixSocket.writeAll(a, line.dropFirst(10))
    expect(isClosedByPeer(a), "A should be closed")
    expectEqual(server.pending.map(\.id), ["B"])
    close(a); close(b)
  }

  test("duplicate request id is refused; first connection keeps it") {
    let (d, _, server, _) = setup()
    defer { server.stop() }
    let path = d + "/huddle.sock"
    let a = UnixSocket.connect(path: path, timeoutMs: 500)!
    _ = UnixSocket.writeAll(a, rawReq("X", "S1"))
    expect(waitFor { server.pending.count == 1 })
    let b = UnixSocket.connect(path: path, timeoutMs: 500)!
    _ = UnixSocket.writeAll(b, rawReq("X", "S2"))
    expect(isClosedByPeer(b), "duplicate should be closed")
    expectEqual(server.pending.map(\.sessionId), ["S1"])
    close(a); close(b)
  }

  test("~6 MB request is ingested promptly") {
    let (d, _, server, _) = setup()
    defer { server.stop() }
    let a = UnixSocket.connect(path: d + "/huddle.sock", timeoutMs: 500)!
    let big = rawReq("BIG", "S1", command: String(repeating: "y", count: 6_000_000))
    Thread.detachNewThread { _ = UnixSocket.writeAll(a, big) }
    expect(waitFor(2) { server.pending.count == 1 }, "6 MB request not ingested within 2 s")
    close(a)
  }

  test("killing one session's hook leaves another's request decidable") {
    let (d, s, server, _) = setup()
    let h1 = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { h1.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 })
    let id1 = server.pending[0].id
    let h2 = RunningHook(dir: d, sessions: s, stdin: payload(session: "S2"))
    defer { h2.cleanup() }
    expect(waitFor { server.pending.count == 2 })
    let id2 = server.pending[1].id
    h1.kill9()
    expect(waitFor { server.pending.map(\.sessionId) == ["S2"] })
    expect(!server.decide(id: id1, .allow))
    expectEqual(server.pending.map(\.id), [id2])
    expect(h2.proc.isRunning); expectEqual(h2.stdout, "")
    expect(server.decide(id: id2, .allow))
    expect(h2.waitExit())
    expectEqual(h2.stdout, decisionOutput(.allow) + "\n")
  }

  test("stop() with a connected hook: hook exits silently, onChange gets [], socket gone") {
    let (d, s, server, changes) = setup()
    let h = RunningHook(dir: d, sessions: s, stdin: payload(session: "S1"))
    defer { h.cleanup(); server.stop() }
    expect(waitFor { server.pending.count == 1 })
    server.stop()
    expect(h.waitExit(), "hook should exit")
    expectEqual(h.proc.terminationStatus, 0); expectEqual(h.stdout, "")
    expect(waitFor { changes.get().last?.isEmpty == true }, "onChange not [] after stop")
    expect(!FileManager.default.fileExists(atPath: d + "/huddle.sock"))
  }
}
