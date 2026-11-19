import Foundation

private let settingsBinary: String = {
  let root = ((#filePath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
  return (root as NSString).appendingPathComponent("build/huddle-settings")
}()

private let ourCommand = "/Users/test/.agent-huddle/bin/huddle-permission-hook"

private func fixtureSettings() -> [String: Any] {
  try! JSONSerialization.jsonObject(with: fixture("settings-orca.json")) as! [String: Any]
}

private func permissionGroups(_ s: [String: Any]) -> [Any] {
  ((s["hooks"] as! [String: Any])["PermissionRequest"] as? [Any]) ?? []
}

private func strip(_ s: [String: Any]) -> [String: Any] {
  var c = s
  var h = c["hooks"] as! [String: Any]
  h.removeValue(forKey: "PermissionRequest")
  c["hooks"] = h
  return c
}

private func without(_ s: [String: Any]) -> NSDictionary {
  var c = s
  var h = c["hooks"] as! [String: Any]
  h.removeValue(forKey: "PermissionRequest")
  c["hooks"] = h
  return c as NSDictionary
}

private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { SettingsMerge.sameJSON(a, b) }

private func runSettings(_ args: [String]) -> (status: Int32, stderr: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: settingsBinary)
  p.arguments = args
  let err = Pipe()
  p.standardError = err
  p.standardOutput = FileHandle.nullDevice
  do { try p.run() } catch { fatalError("cannot run huddle-settings: \(error)") }
  let data = err.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func writeFixture(to dir: String) -> String {
  let path = (dir as NSString).appendingPathComponent("settings.json")
  FileManager.default.createFile(atPath: path, contents: fixture("settings-orca.json"))
  return path
}

private func backups(in dir: String) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains(".agent-huddle-backup-") }
}

func settingsTests() {
  test("install keeps every Orca entry and statusLine/env") {
    let orig = fixtureSettings()
    let out = SettingsMerge.install(orig, hookCommand: ourCommand)
    expect(without(out).isEqual(without(orig)) && same(strip(out), strip(orig)), "everything but PermissionRequest unchanged")
    let groups = permissionGroups(out)
    expectEqual(groups.count, 2)
    expect((groups[0] as! NSDictionary).isEqual(permissionGroups(orig)[0]), "Orca entry first and intact")
    let ours = groups[1] as! [String: Any]
    expectEqual(ours["matcher"] as? String, "*")
    let hook = (ours["hooks"] as! [[String: Any]])[0]
    expectEqual(hook["type"] as? String, "command")
    expectEqual(hook["command"] as? String, ourCommand)
    expectEqual(hook["timeout"] as? Int, 3600)
  }

  test("install twice leaves one Agent Huddle entry") {
    let once = SettingsMerge.install(fixtureSettings(), hookCommand: ourCommand)
    let twice = SettingsMerge.install(once, hookCommand: "/other/path/huddle-permission-hook")
    let ours = permissionGroups(twice).filter { ($0 as! NSDictionary).description.contains(SettingsMerge.marker) }
    expectEqual(ours.count, 1)
    expectEqual(permissionGroups(twice).count, 2)
    let cmd = ((ours[0] as! [String: Any])["hooks"] as! [[String: Any]])[0]["command"] as? String
    expectEqual(cmd, "/other/path/huddle-permission-hook", "survivor is the second command")
  }

  test("uninstall removes only ours") {
    let orig = fixtureSettings()
    let back = SettingsMerge.uninstall(SettingsMerge.install(orig, hookCommand: ourCommand))
    expect(same(back, orig), "round trip equals original")
  }

  test("uninstall drops an emptied PermissionRequest and keeps a shared group's other hooks") {
    let onlyOurs = SettingsMerge.install(["hooks": ["Stop": []]], hookCommand: ourCommand)
    let gone = SettingsMerge.uninstall(onlyOurs)
    expect(!(gone["hooks"] as! [String: Any]).keys.contains("PermissionRequest"), "key dropped")
    let shared: [String: Any] = ["hooks": ["PermissionRequest": [
      ["matcher": "*", "hooks": [["type": "command", "command": "keep-me"], ["type": "command", "command": ourCommand]]],
    ]]]
    let kept = SettingsMerge.uninstall(shared)
    let hooks = (permissionGroups(kept)[0] as! [String: Any])["hooks"] as! [[String: Any]]
    expectEqual(hooks.count, 1)
    expectEqual(hooks[0]["command"] as? String, "keep-me")
  }

  test("hasHook before/after") {
    let orig = fixtureSettings()
    expect(!SettingsMerge.hasHook(orig), "not before")
    expect(!SettingsMerge.hasHook([:]), "not on empty")
    expect(SettingsMerge.hasHook(SettingsMerge.install(orig, hookCommand: ourCommand)), "yes after")
  }

  test("save keeps integers, booleans and permissions, and writes through a symlink") {
    let dir = makeTempDir("settings")
    let real = (dir as NSString).appendingPathComponent("real.json")
    FileManager.default.createFile(atPath: real, contents: fixture("settings-orca.json"), attributes: [.posixPermissions: 0o644])
    let link = (dir as NSString).appendingPathComponent("link.json")
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    let s = SettingsMerge.install(try! SettingsMerge.load(link), hookCommand: ourCommand)
    try! SettingsMerge.save(s, to: link, backup: true)
    expectEqual(((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? ""), real, "still a symlink")
    let attrs = try! FileManager.default.attributesOfItem(atPath: real)
    expectEqual((attrs[.posixPermissions] as! NSNumber).intValue, 0o644)
    let reloaded = try! SettingsMerge.load(real)
    expect(same(reloaded, s), "reload equals saved")
    let text = String(decoding: try! Data(contentsOf: URL(fileURLWithPath: real)), as: UTF8.self)
    expect(text.contains("\"timeout\" : 3600"), "integer stays integer")
    expect(text.contains("\"skipDangerousModePermissionPrompt\" : true"), "bool stays bool")
    expect(text.contains("/.orca/agent-hooks/claude-hook.sh"), "slashes unescaped")
    expectEqual(backups(in: dir).count, 1)
  }

  test("CLI install writes a backup and valid JSON") {
    let dir = makeTempDir("settings")
    let path = writeFixture(to: dir)
    let orig = fixtureSettings()
    let r = runSettings(["install", path, ourCommand])
    expectEqual(r.status, 0, r.stderr)
    expectEqual(backups(in: dir).count, 1)
    let backup = (dir as NSString).appendingPathComponent(backups(in: dir)[0])
    expectEqual(FileManager.default.contents(atPath: backup), fixture("settings-orca.json"), "backup is the original bytes")
    expectEqual(runSettings(["check", path]).status, 0)
    let now = try! SettingsMerge.load(path)
    expect(same(now, SettingsMerge.install(orig, hookCommand: ourCommand)), "content as expected")
    expectEqual(runSettings(["uninstall", path]).status, 0)
    expectEqual(runSettings(["check", path]).status, 1)
    expect(same(try! SettingsMerge.load(path), orig), "uninstalled equals original")
  }

  test("CLI refuses invalid JSON and leaves file byte-identical") {
    let dir = makeTempDir("settings")
    let path = (dir as NSString).appendingPathComponent("settings.json")
    let bad = Data("{ \"hooks\": [oops".utf8)
    FileManager.default.createFile(atPath: path, contents: bad)
    for args in [["install", path, ourCommand], ["uninstall", path], ["check", path]] {
      let r = runSettings(args)
      expectEqual(r.status, 2, "\(args[0])")
      expect(!r.stderr.isEmpty, "message on stderr")
    }
    expectEqual(FileManager.default.contents(atPath: path), bad)
    expectEqual(backups(in: dir).count, 0)
  }

  test("CLI install on a missing file creates one with just our hook") {
    let dir = makeTempDir("settings")
    let path = (dir as NSString).appendingPathComponent("settings.json")
    expectEqual(runSettings(["install", path, ourCommand]).status, 0)
    let s = try! SettingsMerge.load(path)
    expectEqual(s.keys.sorted(), ["hooks"])
    expectEqual((s["hooks"] as! [String: Any]).keys.sorted(), ["PermissionRequest"])
    expect(SettingsMerge.hasHook(s), "has hook")
    expectEqual(backups(in: dir).count, 0)
  }

  test("CLI refuses wrong-typed hooks/PermissionRequest and non-object files, untouched") {
    let inputs = ["{\"hooks\":\"user-string\"}", "{\"hooks\":null}", "{\"hooks\":{\"PermissionRequest\":\"user-string\"}}",
                  "{\"hooks\":{\"PermissionRequest\":null}}",
                  "{\"hooks\":{\"PermissionRequest\":{\"matcher\":\"*\",\"hooks\":[]}}}", "[]", "\"str\""]
    for text in inputs {
      for args in [["install", "P", ourCommand], ["uninstall", "P"]] {
        let dir = makeTempDir("settings")
        let path = (dir as NSString).appendingPathComponent("settings.json")
        let bytes = Data(text.utf8)
        FileManager.default.createFile(atPath: path, contents: bytes)
        var a = args; a[1] = path
        expectEqual(runSettings(a).status, 2, "\(args[0]) \(text)")
        expectEqual(FileManager.default.contents(atPath: path), bytes, "untouched \(text)")
        expectEqual(backups(in: dir).count, 0, "no backup \(text)")
      }
    }
  }

  test("two saves in the same second keep both backups, one with the original bytes") {
    let dir = makeTempDir("settings")
    let path = writeFixture(to: dir)
    let s = SettingsMerge.install(fixtureSettings(), hookCommand: ourCommand)
    try! SettingsMerge.save(s, to: path, backup: true)
    try! SettingsMerge.save(SettingsMerge.uninstall(s), to: path, backup: true)
    let b = backups(in: dir)
    expectEqual(b.count, 2)
    let originals = b.filter { FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent($0)) == fixture("settings-orca.json") }
    expectEqual(originals.count, 1, "pristine original survives")
  }

  test("saved file ends with a newline and leaves no temp file") {
    let dir = makeTempDir("settings")
    let path = (dir as NSString).appendingPathComponent("settings.json")
    try! SettingsMerge.save(["a": 1], to: path, backup: false)
    expectEqual(FileManager.default.contents(atPath: path)?.last, 0x0A)
    expectEqual(try! FileManager.default.contentsOfDirectory(atPath: dir), ["settings.json"])
  }

  test("saved keys are sorted, so a rewrite of the same settings is byte-identical") {
    let dir = makeTempDir("settings")
    let path = (dir as NSString).appendingPathComponent("settings.json")
    try! SettingsMerge.save(["zeta": 1, "alpha": ["y": 1, "b": 2] as [String: Any], "mid": true], to: path, backup: false)
    let first = FileManager.default.contents(atPath: path)!
    let text = String(decoding: first, as: UTF8.self)
    let order = ["\"alpha\"", "\"b\"", "\"y\"", "\"mid\"", "\"zeta\""].map { text.range(of: $0)!.lowerBound }
    expectEqual(order, order.sorted(), "keys in order")
    try! SettingsMerge.save(try! SettingsMerge.load(path), to: path, backup: false)
    expectEqual(FileManager.default.contents(atPath: path), first)
  }

  test("CLI install refuses a command without the marker") {
    let dir = makeTempDir("settings")
    let path = writeFixture(to: dir)
    expectEqual(runSettings(["install", path, "/bin/true"]).status, 2)
    expectEqual(FileManager.default.contents(atPath: path), fixture("settings-orca.json"))
    expectEqual(backups(in: dir).count, 0)
  }

  test("no-op runs write nothing and back up nothing") {
    let dir = makeTempDir("settings")
    let path = writeFixture(to: dir)
    expectEqual(runSettings(["uninstall", path]).status, 0)  // hook not present
    expectEqual(FileManager.default.contents(atPath: path), fixture("settings-orca.json"))
    expectEqual(backups(in: dir).count, 0)
    expectEqual(runSettings(["install", path, ourCommand]).status, 0)
    expectEqual(backups(in: dir).count, 1)
    let after = FileManager.default.contents(atPath: path)
    expectEqual(runSettings(["install", path, ourCommand]).status, 0)  // identical result
    expectEqual(FileManager.default.contents(atPath: path), after)
    expectEqual(backups(in: dir).count, 1, "second identical install adds no backup")
    let missing = (dir as NSString).appendingPathComponent("nope.json")
    expectEqual(runSettings(["uninstall", missing]).status, 0)
    expect(!FileManager.default.fileExists(atPath: missing), "uninstall did not create a file")
  }
}
