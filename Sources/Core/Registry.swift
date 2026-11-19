import Foundation

struct SessionRecord: Equatable {
  let pid: Int32
  let sessionId: String
  let cwd: String
  let name: String?
  let entrypoint: String?
  let status: String?
  let waitingFor: String?
  let startedAt: Date?
  let statusUpdatedAt: Date?
}

func parseSessionRecord(_ data: Data) -> SessionRecord? {
  guard let v = JSONValue.parse(data),
        let rawPid = v["pid"]?.double,
        let pid = Int32(exactly: rawPid), pid >= 1,
        let sessionId = v["sessionId"]?.string,
        let cwd = v["cwd"]?.string else { return nil }
  func date(_ key: String) -> Date? { v[key]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } }
  return SessionRecord(
    pid: pid, sessionId: sessionId, cwd: cwd,
    name: v["name"]?.string, entrypoint: v["entrypoint"]?.string,
    status: v["status"]?.string, waitingFor: v["waitingFor"]?.string,
    startedAt: date("startedAt"), statusUpdatedAt: date("statusUpdatedAt"))
}

func loadRegistry(dir: String = Paths.sessionsDir) -> [SessionRecord] {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
  return names.filter { $0.hasSuffix(".json") }.compactMap { name in
    FileManager.default.contents(atPath: dir + "/" + name).flatMap(parseSessionRecord)
  }
}

/// The record for `sessionId`. Files for dead processes can linger and share a session id, so a
/// live pid wins, then the most recent status (records without a time count as oldest).
func findRecord(sessionId: String, dir: String = Paths.sessionsDir,
                isAlive: (Int32) -> Bool = ProcessReader.isAlive) -> SessionRecord? {
  let matches = loadRegistry(dir: dir).filter { $0.sessionId == sessionId }
  if matches.count < 2 { return matches.first }
  func rank(_ r: SessionRecord) -> (Int, Date, Int32) {
    (isAlive(r.pid) ? 1 : 0, r.statusUpdatedAt ?? .distantPast, r.pid)
  }
  return matches.map { (record: $0, rank: rank($0)) }.max { $0.rank < $1.rank }?.record
}
