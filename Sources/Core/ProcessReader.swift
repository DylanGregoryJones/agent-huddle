import Foundation

enum ProcessReader {
  static func isAlive(_ pid: Int32) -> Bool {
    pid >= 1 && (kill(pid, 0) == 0 || errno == EPERM)
  }

  static func environment(of pid: Int32) -> [String: String]? {
    var argmax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    var mib = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: Int(argmax))
    var len = buf.count
    var pmib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&pmib, 3, &buf, &len, nil, 0) == 0, len > MemoryLayout<Int32>.size else { return nil }

    let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var i = MemoryLayout<Int32>.size
    // exec path, then its NUL padding
    while i < len && buf[i] != 0 { i += 1 }
    while i < len && buf[i] == 0 { i += 1 }
    // argc args
    var skipped = 0
    while skipped < argc && i < len {
      while i < len && buf[i] != 0 { i += 1 }
      i += 1
      skipped += 1
    }
    // KEY=VALUE strings until an empty string or end of buffer
    var env: [String: String] = [:]
    while i < len && buf[i] != 0 {
      var j = i
      while j < len && buf[j] != 0 { j += 1 }
      let s = String(decoding: buf[i..<j], as: UTF8.self)
      if let eq = s.firstIndex(of: "=") {
        env[String(s[..<eq])] = String(s[s.index(after: eq)...])
      }
      i = j + 1
    }
    return env
  }

  static func tty(of pid: Int32) -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let dev = info.kp_eproc.e_tdev
    guard dev != UInt32.max, dev != 0, let cName = devname(dev_t(dev), S_IFCHR) else { return nil }
    let name = String(cString: cName)
    return name.hasPrefix("#") ? nil : "/dev/" + name
  }

  /// The executable a process is running, e.g. `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`.
  static func executablePath(of pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
  }
}
