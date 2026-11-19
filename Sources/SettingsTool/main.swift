import Foundation

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("huddle-settings: \(msg)\n".utf8))
  exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail("usage: huddle-settings install <settings.json> <hookCommand> | uninstall <settings.json> | check <settings.json>") }
let path = args[1]

func apply(_ s: [String: Any], _ merged: [String: Any]) throws {
  if SettingsMerge.sameJSON(s, merged) { return }  // nothing to change: no backup, no write
  try SettingsMerge.save(merged, to: path, backup: true)
}

do {
  switch (args[0], args.count) {
  case ("install", 3):
    guard args[2].contains(SettingsMerge.marker) else { fail("hook command must contain \(SettingsMerge.marker)") }
    let s = try SettingsMerge.load(path)
    try SettingsMerge.validateShape(s)
    try apply(s, SettingsMerge.install(s, hookCommand: args[2]))
  case ("uninstall", 2):
    let s = try SettingsMerge.load(path)
    try SettingsMerge.validateShape(s)
    try apply(s, SettingsMerge.uninstall(s))
  case ("check", 2):
    exit(SettingsMerge.hasHook(try SettingsMerge.load(path)) ? 0 : 1)
  default:
    fail("bad arguments")
  }
} catch {
  fail("\(error)")
}
