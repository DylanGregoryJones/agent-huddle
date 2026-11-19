import Foundation

enum TranscriptEvent: Equatable {
  case prompt(String)
  case title(String)
  case toolUse(name: String, input: JSONValue, at: Date?)
  case thinking(at: Date?)
  case text(String, at: Date?)
}

private let timestampFormatter: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()

private func parseTimestamp(_ s: String?) -> Date? {
  guard let s else { return nil }
  return timestampFormatter.date(from: s)
}

func parseTranscriptLine(_ line: Data) -> [TranscriptEvent] {
  guard let v = JSONValue.parse(line), let type = v["type"]?.string else { return [] }
  switch type {
  case "last-prompt":
    return v["lastPrompt"]?.string.map { [.prompt($0)] } ?? []
  case "ai-title":
    return v["aiTitle"]?.string.map { [.title($0)] } ?? []
  case "assistant":
    if case .bool(true)? = v["isSidechain"] { return [] }
    let at = parseTimestamp(v["timestamp"]?.string)
    guard let blocks = v["message"]?["content"]?.array else { return [] }
    return blocks.compactMap { b in
      switch b["type"]?.string {
      case "thinking": return .thinking(at: at)
      case "text": return b["text"]?.string.map { .text($0, at: at) }
      case "tool_use": return b["name"]?.string.map { .toolUse(name: $0, input: b["input"] ?? .null, at: at) }
      default: return nil
      }
    }
  default:
    return []
  }
}

final class TranscriptTail {
  private let path: String
  private var offset: UInt64 = 0
  private var buffer = Data()

  init(path: String) { self.path = path }

  func readNew() -> [TranscriptEvent] {
    guard let h = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? h.close() }
    guard let size = try? h.seekToEnd() else { return [] }
    if size < offset { offset = 0; buffer = Data() }
    guard size > offset, (try? h.seek(toOffset: offset)) != nil,
          let chunk = try? h.readToEnd(), !chunk.isEmpty else { return [] }
    offset += UInt64(chunk.count)
    buffer.append(chunk)
    var events: [TranscriptEvent] = []
    var start = buffer.startIndex
    while let nl = buffer[start...].firstIndex(of: 0x0A) {
      if nl > start { events += parseTranscriptLine(buffer[start..<nl]) }
      start = nl + 1
    }
    if start > buffer.startIndex { buffer = Data(buffer[start...]) }
    return events
  }
}

/// Where the transcript normally is: the project folder named after `cwd`. Does not check the disk.
func directTranscriptPath(cwd: String, sessionId: String, projectsDir: String = Paths.projectsDir) -> String {
  let slug = String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
  return "\(projectsDir)/\(slug)/\(sessionId).jsonl"
}

func transcriptPath(cwd: String, sessionId: String, projectsDir: String = Paths.projectsDir) -> String? {
  let fm = FileManager.default
  let direct = directTranscriptPath(cwd: cwd, sessionId: sessionId, projectsDir: projectsDir)
  if fm.fileExists(atPath: direct) { return direct }
  for sub in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
    let p = "\(projectsDir)/\(sub)/\(sessionId).jsonl"
    if fm.fileExists(atPath: p) { return p }
  }
  return nil
}

struct ToolStep: Equatable {
  let name: String
  let input: JSONValue
  let at: Date?
}

struct TranscriptSummary: Equatable {
  var title: String?
  var lastPrompt: String?
  var lastText: String?
  var steps: [ToolStep] = []
  var latest: TranscriptEvent?
  /// Distinct messages the user has sent: trimmed, non-empty, and not the same as the one before
  /// (Claude Code writes `last-prompt` again on every turn).
  var messageCount = 0
  /// The first 3 distinct messages.
  var firstMessages: [String] = []
  /// The last 5 distinct messages, newest last.
  var recentMessages: [String] = []

  mutating func apply(_ events: [TranscriptEvent]) {
    for e in events {
      switch e {
      case .title(let t): title = t
      case .prompt(let p):
        lastPrompt = p
        noteMessage(p)
      case .toolUse(let name, let input, let at):
        steps.insert(ToolStep(name: name, input: input, at: at), at: 0)
        if steps.count > 4 { steps.removeLast(steps.count - 4) }
        latest = e
      case .thinking: latest = e
      case .text(let t, _): lastText = t; latest = e
      }
    }
  }

  private mutating func noteMessage(_ p: String) {
    let m = p.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !m.isEmpty, m != recentMessages.last else { return }
    messageCount += 1
    if firstMessages.count < 3 { firstMessages.append(m) }
    recentMessages.append(m)
    if recentMessages.count > 5 { recentMessages.removeFirst(recentMessages.count - 5) }
  }
}
