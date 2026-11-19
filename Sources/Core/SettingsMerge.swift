import Foundation

/// Adds and removes Agent Huddle's PermissionRequest hook in a Claude settings.json
/// without disturbing any other entry.
enum SettingsMerge {
  static let marker = "huddle-permission-hook"

  struct SettingsError: Error, CustomStringConvertible {
    let description: String
  }

  private static func isOurs(_ hook: Any) -> Bool {
    guard let h = hook as? [String: Any], let c = h["command"] as? String else { return false }
    return c.contains(marker)
  }

  /// Groups with our hooks removed; a group left with no hooks because of that is dropped.
  private static func strip(_ groups: [Any]) -> [Any] {
    var out: [Any] = []
    for g in groups {
      guard var group = g as? [String: Any], let hooks = group["hooks"] as? [Any] else {
        out.append(g)
        continue
      }
      let kept = hooks.filter { !isOurs($0) }
      if kept.count == hooks.count { out.append(g); continue }
      if kept.isEmpty { continue }
      group["hooks"] = kept
      out.append(group)
    }
    return out
  }

  /// Throws if `hooks` or `hooks.PermissionRequest` exists with the wrong type, so a
  /// merge never silently replaces something the user wrote.
  static func validateShape(_ s: [String: Any]) throws {
    guard let h = s["hooks"] else { return }
    guard let hooks = h as? [String: Any] else { throw SettingsError(description: "\"hooks\" is not an object") }
    if let p = hooks["PermissionRequest"], !(p is [Any]) {
      throw SettingsError(description: "\"hooks.PermissionRequest\" is not an array")
    }
  }

  /// True when both serialise identically (distinguishes true from 1, unlike NSDictionary equality).
  static func sameJSON(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    let o: JSONSerialization.WritingOptions = [.sortedKeys]
    guard let x = try? JSONSerialization.data(withJSONObject: a, options: o),
          let y = try? JSONSerialization.data(withJSONObject: b, options: o) else { return false }
    return x == y
  }

  static func install(_ s: [String: Any], hookCommand: String, timeout: Int = 3600) -> [String: Any] {
    var result = s
    var hooks = (s["hooks"] as? [String: Any]) ?? [:]
    var groups = strip((hooks["PermissionRequest"] as? [Any]) ?? [])
    groups.append([
      "matcher": "*",
      "hooks": [["type": "command", "command": hookCommand, "timeout": timeout] as [String: Any]],
    ] as [String: Any])
    hooks["PermissionRequest"] = groups
    result["hooks"] = hooks
    return result
  }

  static func uninstall(_ s: [String: Any]) -> [String: Any] {
    guard var hooks = s["hooks"] as? [String: Any], let groups = hooks["PermissionRequest"] as? [Any] else { return s }
    let kept = strip(groups)
    if kept.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = kept }
    var result = s
    result["hooks"] = hooks
    return result
  }

  static func hasHook(_ s: [String: Any]) -> Bool {
    guard let hooks = s["hooks"] as? [String: Any], let groups = hooks["PermissionRequest"] as? [Any] else { return false }
    for g in groups {
      if let group = g as? [String: Any], let hs = group["hooks"] as? [Any], hs.contains(where: isOurs) { return true }
    }
    return false
  }

  static func load(_ path: String) throws -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path) else {
      if FileManager.default.fileExists(atPath: path) { throw SettingsError(description: "cannot read \(path)") }
      return [:]
    }
    let obj: Any
    do { obj = try JSONSerialization.jsonObject(with: data) } catch {
      throw SettingsError(description: "\(path) is not valid JSON")
    }
    guard let dict = obj as? [String: Any] else { throw SettingsError(description: "\(path) is not a JSON object") }
    return dict
  }

  static func save(_ s: [String: Any], to path: String, backup: Bool) throws {
    let fm = FileManager.default
    // Write through a symlink to its target rather than replacing the link.
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let dir = (target as NSString).deletingLastPathComponent
    let existed = fm.fileExists(atPath: target)
    // Encode first so a failure leaves everything untouched. Sorted keys, so rewrites never reorder.
    var data = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    data.append(0x0A)
    var perms: NSNumber? = nil
    if existed {
      perms = try fm.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
      if backup {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(target).agent-huddle-backup-\(f.string(from: Date()))"
        var b = base
        var n = 0
        while fm.fileExists(atPath: b) { n += 1; b = "\(base)-\(n)" }
        try fm.copyItem(atPath: target, toPath: b)
        try syncToDisk(b)
      }
    } else {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let tmp = (dir as NSString).appendingPathComponent(".\((target as NSString).lastPathComponent).agent-huddle-tmp-\(getpid())")
    try? fm.removeItem(atPath: tmp)
    do {
      guard fm.createFile(atPath: tmp, contents: data, attributes: perms.map { [.posixPermissions: $0] }) else {
        throw SettingsError(description: "cannot write \(tmp)")
      }
      if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp) }
      try syncToDisk(tmp)
      if rename(tmp, target) != 0 {
        throw SettingsError(description: "cannot replace \(target): \(String(cString: strerror(errno)))")
      }
    } catch {
      try? fm.removeItem(atPath: tmp)
      throw error
    }
  }

  private static func syncToDisk(_ path: String) throws {
    let fd = open(path, O_RDONLY)
    if fd < 0 { throw SettingsError(description: "cannot open \(path) to sync") }
    defer { close(fd) }
    if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 { throw SettingsError(description: "cannot sync \(path)") }
  }
}
