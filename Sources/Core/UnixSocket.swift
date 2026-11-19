import Foundation

struct UnixSocketError: Error { let message: String }

enum LineResult: Equatable { case line(Data), timeout, closed }

enum UnixSocket {
  private static func makeAddr(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      for (i, b) in bytes.enumerated() { buf[i] = b }
      buf[bytes.count] = 0
    }
    return addr
  }

  private static func newSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
  }

  static func connect(path: String, timeoutMs: Int) -> Int32? {
    guard var addr = makeAddr(path), let fd = newSocket() else { return nil }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if rc != 0 {
      guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
      var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      guard poll(&p, 1, Int32(timeoutMs)) == 1 else { close(fd); return nil }
      var err: Int32 = 0
      var len = socklen_t(MemoryLayout<Int32>.size)
      getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
      guard err == 0 else { close(fd); return nil }
    }
    _ = fcntl(fd, F_SETFL, flags)
    return fd
  }

  static func listen(path: String) throws -> Int32 {
    guard var addr = makeAddr(path) else { throw UnixSocketError(message: "socket path too long") }
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard chmod(dir, 0o700) == 0 else { throw UnixSocketError(message: "chmod dir failed: errno \(errno)") }
    unlink(path)
    guard let fd = newSocket() else { throw UnixSocketError(message: "socket() failed: errno \(errno)") }
    let rc = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else { let e = errno; close(fd); throw UnixSocketError(message: "bind() failed: errno \(e)") }
    guard chmod(path, 0o600) == 0 else {
      let e = errno; close(fd); unlink(path); throw UnixSocketError(message: "chmod socket failed: errno \(e)")
    }
    guard Darwin.listen(fd, 16) == 0 else {
      let e = errno; close(fd); throw UnixSocketError(message: "listen() failed: errno \(e)")
    }
    return fd
  }

  /// Bounds how long a single write may block (a hung peer must not stall the caller).
  static func setSendTimeout(_ fd: Int32, ms: Int) {
    var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  }

  static func accept(_ fd: Int32) -> Int32? {
    let c = Darwin.accept(fd, nil, nil)
    if c < 0 { return nil }
    var one: Int32 = 1
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return c
  }

  static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let total = data.count
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
      while offset < total {
        let n = write(fd, raw.baseAddress! + offset, total - offset)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        if n == 0 { return false }
        offset += n
      }
      return true
    }
  }
}

final class LineReader {
  private let fd: Int32
  private var buffer = Data()

  init(fd: Int32) { self.fd = fd }

  func readLine(timeoutMs: Int) -> LineResult {
    let deadline = ProcessInfo.processInfo.systemUptime + Double(max(timeoutMs, 0)) / 1000
    while true {
      if let nl = buffer.firstIndex(of: 0x0A) {
        let lineData = Data(buffer[buffer.startIndex..<nl])
        buffer.removeSubrange(buffer.startIndex...nl)
        return .line(lineData)
      }
      let remaining = min(Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000), 60_000)
      if remaining <= 0 { return .timeout }
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let rc = poll(&p, 1, Int32(remaining))
      if rc < 0 { if errno == EINTR { continue }; return .closed }
      if rc == 0 { return .timeout }
      var chunk = [UInt8](repeating: 0, count: 4096)
      let n = read(fd, &chunk, chunk.count)
      if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .closed }
      if n == 0 { return .closed }
      buffer.append(contentsOf: chunk[0..<n])
    }
  }
}
