import Foundation

/// Listens on the huddle socket. Each hook connection sends one request line and then waits;
/// the connection itself is the request's lifetime (EOF = the hook is gone).
final class PermissionServer {
  private final class Conn {
    let fd: Int32
    var source: DispatchSourceRead?
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var request: PendingRequest?
    var closed = false
    init(fd: Int32) { self.fd = fd }
  }

  private static let maxUnterminated = 8 * 1024 * 1024

  private let socketPath: String
  private let callbackQueue: DispatchQueue
  private let onChange: ([PendingRequest]) -> Void
  private let q = DispatchQueue(label: "agent-huddle.permission-server")

  // All mutable state below is touched only on `q`.
  private var listenSource: DispatchSourceRead?
  private var conns: [Conn] = []   // arrival order, oldest first

  init(socketPath: String, callbackQueue: DispatchQueue = .main,
       onChange: @escaping ([PendingRequest]) -> Void) {
    self.socketPath = socketPath
    self.callbackQueue = callbackQueue
    self.onChange = onChange
  }

  func start() throws {
    try q.sync {
      guard listenSource == nil else { return }
      let fd = try UnixSocket.listen(path: socketPath)
      let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
      src.setEventHandler { [weak self] in self?.acceptOne(fd) }
      src.setCancelHandler { close(fd) }
      listenSource = src
      src.resume()
    }
  }

  func stop() {
    q.sync {
      guard let src = listenSource else { return }
      src.cancel()
      listenSource = nil
      let hadRequests = conns.contains { $0.request != nil }
      for c in conns { closeConn(c, notify: false) }
      unlink(socketPath)
      if hadRequests { emit() }
    }
  }

  var pending: [PendingRequest] { q.sync { snapshot() } }

  @discardableResult
  func decide(id: String, _ d: Decision) -> Bool {
    q.sync {
      guard let c = conns.first(where: { !$0.closed && $0.request?.id == id }) else { return false }
      let ok = UnixSocket.writeAll(c.fd, encodeDecisionLine(id: id, d))
      closeConn(c, notify: true)
      return ok
    }
  }

  // MARK: private (on q)

  private func snapshot() -> [PendingRequest] { conns.compactMap { $0.request } }

  private func emit() {
    let snap = snapshot()
    callbackQueue.async { [onChange] in onChange(snap) }
  }

  private func acceptOne(_ listenFd: Int32) {
    guard let fd = UnixSocket.accept(listenFd) else { return }
    UnixSocket.setSendTimeout(fd, ms: 1000)
    let c = Conn(fd: fd)
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
    src.setEventHandler { [weak self] in self?.readable(c) }
    src.setCancelHandler { close(fd) }
    c.source = src
    conns.append(c)
    src.resume()
  }

  private func readable(_ c: Conn) {
    guard !c.closed else { return }
    let n = c.chunk.withUnsafeMutableBytes { read(c.fd, $0.baseAddress, $0.count) }   // readiness was signalled, so this does not block
    if n < 0 {
      if errno == EINTR || errno == EAGAIN { return }
      closeConn(c, notify: true); return
    }
    if n == 0 { closeConn(c, notify: true); return }
    guard c.request == nil else { return }   // one request per connection; ignore extras
    if let nl = c.chunk[0..<n].firstIndex(of: 0x0A) {   // only the new bytes can hold the newline
      c.buffer.append(contentsOf: c.chunk[0..<nl])
      let line = c.buffer
      c.buffer = Data()
      guard let req = decodeRequestLine(line, receivedAt: Date()) else { closeConn(c, notify: false); return }
      admit(c, req)
    } else {
      c.buffer.append(contentsOf: c.chunk[0..<n])
      if c.buffer.count > Self.maxUnterminated { closeConn(c, notify: false) }
    }
  }

  /// `conns` is in accept order, so an earlier index means an older connection.
  private func admit(_ c: Conn, _ req: PendingRequest) {
    guard let idx = conns.firstIndex(where: { $0 === c }) else { return }
    // A decision may only ever reach one connection: refuse a duplicate id.
    if conns.contains(where: { $0 !== c && $0.request?.id == req.id }) { closeConn(c, notify: false); return }
    // A newer connection for this session already holds a request: this one is stale.
    if conns[(idx + 1)...].contains(where: { $0.request?.sessionId == req.sessionId }) {
      closeConn(c, notify: false); return
    }
    c.request = req
    for old in conns[..<idx] where old.request?.sessionId == req.sessionId {
      closeConn(old, notify: false)   // supersede: the session moved on
    }
    emit()
  }

  private func closeConn(_ c: Conn, notify: Bool) {
    guard !c.closed else { return }
    c.closed = true
    let hadRequest = c.request != nil
    c.request = nil
    conns.removeAll { $0 === c }
    c.source?.cancel()   // cancel handler closes the fd
    c.source = nil
    if notify && hadRequest { emit() }
  }
}
