import Foundation

signal(SIGPIPE, SIG_IGN)

// Contract: print exactly one decision string, or nothing. Always exit 0.
let input = FileHandle.standardInput.readDataToEndOfFile()

guard case .handle(let payload) = gate(payloadData: input, env: ProcessInfo.processInfo.environment),
      let fd = UnixSocket.connect(path: Paths.socketPath, timeoutMs: 200) else { exit(0) }

UnixSocket.setSendTimeout(fd, ms: 1000)  // a hung panel must not block us before the registry watch starts
let requestId = UUID().uuidString
guard UnixSocket.writeAll(fd, encodeRequestLine(id: requestId, payload: payload)) else { exit(0) }

let reader = LineReader(fd: fd)
var watch = AnsweredElsewhereWatch()
while true {
  switch reader.readLine(timeoutMs: 250) {
  case .line(let l):
    if let d = decodeDecisionLine(l), d.id == requestId {
      print(decisionOutput(d.decision))
      fflush(stdout)
      exit(0)
    }
  case .closed:
    exit(0)
  case .timeout:
    let record = findRecord(sessionId: payload.sessionId)
    if watch.update(status: record?.status, alive: record.map { ProcessReader.isAlive($0.pid) }) { exit(0) }
  }
}
