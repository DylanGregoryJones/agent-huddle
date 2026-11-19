import Foundation

enum Paths {
  private static var env: [String: String] { ProcessInfo.processInfo.environment }

  static var home: String { env["HOME"] ?? NSHomeDirectory() }
  static var huddleDir: String { env["AGENT_HUDDLE_DIR"] ?? home + "/.agent-huddle" }
  static var socketPath: String { huddleDir + "/huddle.sock" }
  static var goalsPath: String { huddleDir + "/goals.json" }
  static var sessionsDir: String { env["AGENT_HUDDLE_SESSIONS_DIR"] ?? home + "/.claude/sessions" }
  static var projectsDir: String { env["AGENT_HUDDLE_PROJECTS_DIR"] ?? home + "/.claude/projects" }
  static var settingsPath: String { home + "/.claude/settings.json" }

  static func abbreviate(_ path: String) -> String {
    let h = home
    if path == h { return "~" }
    if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
    return path
  }
}
