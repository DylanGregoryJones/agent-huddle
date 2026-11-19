import Foundation

/// The mock-ups' four agents, built through the same `buildRows` the live panel uses
/// so the demo renders show the app's real wording, order and colours.
enum DemoData {
  static let deckId = "demo-client-deck"
  static let webAppId = "demo-web-app"
  static let webAppGoal = "Fixing the date filter in the web app: a timezone bug, ready for review."

  static var rows: [AgentRow] {
    let now = Date()
    let home = Paths.home
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    func record(_ pid: Int32, _ id: String, _ folder: String, _ status: String,
                started: TimeInterval, statusSince: TimeInterval = 0) -> SessionRecord {
      SessionRecord(pid: pid, sessionId: id, cwd: home + "/" + folder, name: nil, entrypoint: "cli",
                    status: status, waitingFor: status == "waiting" ? "permission prompt" : nil,
                    startedAt: ago(started), statusUpdatedAt: ago(statusSince))
    }
    func tool(_ name: String, _ input: [String: String], _ secondsAgo: TimeInterval) -> TranscriptEvent {
      .toolUse(name: name, input: .object(input.mapValues { .string($0) }), at: ago(secondsAgo))
    }
    func summary(_ events: [TranscriptEvent]) -> TranscriptSummary {
      var s = TranscriptSummary()
      s.apply(events)
      return s
    }

    let adsId = "demo-ads-editor", gameId = "demo-game-prototype"
    let records = [
      record(1001, deckId, "client-deck", "waiting", started: 3 * 3600),
      record(1002, webAppId, "web-app", "busy", started: 2 * 3600 + 14 * 60 + 20),
      record(1003, adsId, "ads-editor", "busy", started: 50 * 60),
      record(1004, gameId, "game-prototype", "idle", started: 40 * 60, statusSince: 4 * 60 + 30),
    ]
    let summaries: [String: TranscriptSummary] = [
      deckId: summary([
        .title("Client deck build"),
        .prompt("rebuild the final deck with the new charts"),
        tool("Bash", ["command": "python3 build_deck.py --final"], 2),
      ]),
      webAppId: summary([
        .title("Web app date filter fix"),
        .prompt("fix the date filter on the sales page and run the tests"),
        tool("Grep", ["pattern": "dateRange"], 190),
        tool("Read", ["file_path": home + "/web-app/src/dateRange.ts"], 130),
        tool("Edit", ["file_path": home + "/web-app/src/SalesFilter.tsx"], 70),
        .text("The filter was using UTC midnight. I've switched it to local time and I'm running the tests now.", at: ago(10)),
        tool("Bash", ["command": "npm test"], 5),
      ]),
      adsId: summary([
        .title("Ads editor layout"),
        .prompt("wire the draft studio editor to the new model"),
        tool("Edit", ["file_path": home + "/ads-editor/studio/Editor.tsx"], 3),
      ]),
      gameId: summary([
        .title("Game prototype tweaks"),
        .prompt("make the zombies a bit slower on easy"),
        .text("Done. Easy zombies now move at 80% speed.", at: ago(4 * 60 + 30)),
      ]),
    ]
    let pending = PendingRequest(id: "demo-request", sessionId: deckId, toolName: "Bash",
                                 toolInput: .object(["command": .string("python3 build_deck.py --final")]),
                                 receivedAt: ago(5))
    var colours = ColourAssigner()
    return buildRows(RowInputs(records: records, isTerminal: { _ in true }, isAlive: { _ in true },
                               summaries: summaries, pending: [pending], now: now),
                     colours: &colours)
  }
}
