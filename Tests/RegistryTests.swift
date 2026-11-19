import Foundation

func registryTests() {
  let waitingId = "9e4a7b32-81c5-4f06-b3d9-7a2e5c1f6d48"

  func makeRegistryDir() -> String {
    let d = makeTempDir()
    for (src, dst) in [("session-busy.json", "busy.json"), ("session-waiting.json", "waiting.json"),
                       ("session-truncated.json", "truncated.json"), ("session-busy.json", "1.abc.key")] {
      FileManager.default.createFile(atPath: d + "/" + dst, contents: fixture(src))
    }
    return d
  }

  test("parses a registry file") {
    let r = parseSessionRecord(fixture("session-waiting.json"))!
    expectEqual(r.pid, 39786); expectEqual(r.status, "waiting"); expectEqual(r.waitingFor, "permission prompt")
    expectEqual(r.startedAt, Date(timeIntervalSince1970: 1794921554.123))
  }
  test("truncated file is skipped, not fatal") { expect(parseSessionRecord(fixture("session-truncated.json")) == nil) }
  test("loadRegistry ignores .key files and garbage") {
    let d = makeRegistryDir()
    expectEqual(Set(loadRegistry(dir: d).map(\.pid)), [39786, 67232])
  }
  test("findRecord by sessionId") {
    let d = makeRegistryDir()
    expectEqual(findRecord(sessionId: waitingId, dir: d)?.pid, 39786)
  }
  test("findRecord prefers a live pid, then the newest status") {
    let d = makeTempDir()
    func write(_ pid: Int32, _ sid: String, updated: Double?) {
      let stamp = updated.map { ",\"statusUpdatedAt\":\($0)" } ?? ""
      let json = #"{"pid":\#(pid),"sessionId":"\#(sid)","cwd":"/x","status":"waiting"\#(stamp)}"#
      FileManager.default.createFile(atPath: d + "/\(pid).json", contents: Data(json.utf8))
    }
    write(11, "S", updated: 3000)   // dead, newest
    write(22, "S", updated: 1000)   // alive, oldest
    write(33, "S", updated: 2000)   // alive, newer
    write(44, "S", updated: nil)    // alive, no time
    write(55, "T", updated: 9000)
    expectEqual(findRecord(sessionId: "S", dir: d, isAlive: { [22, 33, 44, 55].contains($0) })?.pid, 33)
    expectEqual(findRecord(sessionId: "S", dir: d, isAlive: { [22, 44].contains($0) })?.pid, 22)
    expectEqual(findRecord(sessionId: "S", dir: d, isAlive: { $0 == 44 })?.pid, 44)
    expectEqual(findRecord(sessionId: "S", dir: d, isAlive: { _ in false })?.pid, 11)
    expectEqual(findRecord(sessionId: "T", dir: d, isAlive: { _ in false })?.pid, 55)
    expect(findRecord(sessionId: "U", dir: d) == nil)
  }
  test("own process is alive, pid 999999 is not") {
    expect(ProcessReader.isAlive(getpid())); expect(!ProcessReader.isAlive(999_999))
  }
  test("reads own environment") {
    expectEqual(ProcessReader.environment(of: getpid())?["HOME"], ProcessInfo.processInfo.environment["HOME"])
  }
  test("out-of-range or non-positive pids are rejected") {
    for pid in ["0", "-5", "4294967296", "1e20"] {
      let json = #"{"pid":\#(pid),"sessionId":"s","cwd":"/x"}"#
      expect(parseSessionRecord(Data(json.utf8)) == nil, "pid \(pid)")
    }
  }
  test("isAlive is false for pid 0 and negative") {
    expect(!ProcessReader.isAlive(0)); expect(!ProcessReader.isAlive(-1))
  }
}
