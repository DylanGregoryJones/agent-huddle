import Foundation

/// `s` with every run of whitespace (newlines included) collapsed to one space, cut to `max`
/// characters with "…". Reads only as far as it needs, so huge inputs cost no more than short ones.
func oneLine(_ s: String, max: Int) -> String {
  if max < 1 { return "" }
  var out: [Character] = []
  out.reserveCapacity(max + 2)
  var gap = false
  for ch in s {
    if ch.isWhitespace { gap = !out.isEmpty; continue }
    if gap { out.append(" "); gap = false }
    out.append(ch)
    if out.count > max { break }
  }
  if out.count <= max { return String(out) }
  return String(out.prefix(max - 1)) + "…"
}

private func basename(_ input: JSONValue) -> String {
  let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? ""
  let name = oneLine((path as NSString).lastPathComponent, max: 60)
  return name.isEmpty ? "a file" : name
}

private func mcpParts(_ name: String) -> (server: String, tool: String)? {
  guard name.hasPrefix("mcp__") else { return nil }
  let parts = name.dropFirst(5).components(separatedBy: "__")
  guard parts.count >= 2, !parts[0].isEmpty else { return nil }
  return (parts[0], parts.dropFirst().joined(separator: "__"))
}

func describeTool(_ name: String, _ input: JSONValue) -> String {
  switch name {
  case "Bash":
    let cmd = oneLine(input["command"]?.string ?? "", max: 40)
    return cmd.isEmpty ? "Running a command" : "Running " + cmd
  case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + basename(input)
  case "Write": return "Creating " + basename(input)
  case "Read": return "Reading " + basename(input)
  case "Grep", "Glob":
    let pattern = oneLine(input["pattern"]?.string ?? "", max: 30)
    return pattern.isEmpty ? "Searching files" : "Searching for \"" + pattern + "\""
  case "WebSearch": return "Searching the web"
  case "WebFetch":
    let url = input["url"]?.string ?? ""
    if let host = URL(string: url)?.host, !host.isEmpty { return "Reading " + host }
    let shown = oneLine(url, max: 40)
    return shown.isEmpty ? "Reading a page" : "Reading " + shown
  case "Agent", "Task": return "Running a helper agent"
  default:
    if let m = mcpParts(name) { return "Using " + m.server }
    return "Using " + name
  }
}

func describePending(_ name: String, _ input: JSONValue) -> String {
  switch name {
  case "Bash": return "Wants to run a command"
  case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Wants to edit " + basename(input)
  default:
    if let m = mcpParts(name) { return "Wants to use " + m.server }
    return "Wants to use " + name
  }
}

func doingLine(status: String?, waitingFor: String?, pending: PendingRequest?, latest: TranscriptEvent?,
               hasPrompt: Bool, statusSince: Date?, now: Date) -> String {
  if let p = pending { return describePending(p.toolName, p.toolInput) }
  if status == "waiting" {
    if let w = waitingFor, w.contains("permission") { return "Needs permission · answer in Terminal" }
    return "Needs you · answer in Terminal"
  }
  if status == "busy" {
    switch latest {
    case .toolUse(let name, let input, _)?: return describeTool(name, input)
    case .thinking?: return "Thinking…"
    case .text?: return "Writing a reply"
    default: return "Working…"
    }
  }
  if !hasPrompt { return "Ready" }
  var line = "Done · waiting for you"
  if let since = statusSince {
    let minutes = Int(now.timeIntervalSince(since) / 60)
    if minutes >= 60 { line += " (\(minutes / 60) h)" }
    else if minutes >= 1 { line += " (\(minutes) min)" }
  }
  return line
}

func relativeAge(_ d: Date?, now: Date) -> String {
  guard let d = d else { return "" }
  let secs = Int(now.timeIntervalSince(d))
  if secs < 60 { return "now" }
  if secs < 3600 { return "\(secs / 60)m" }
  return "\(secs / 3600)h"
}

func runningFor(since: Date?, now: Date) -> String {
  guard let since = since else { return "" }
  let minutes = Int(now.timeIntervalSince(since) / 60)
  if minutes < 1 { return "running <1m" }
  if minutes < 60 { return "running \(minutes)m" }
  return "running \(minutes / 60)h \(minutes % 60)m"
}

/// Keys that usually hold a tool's main argument, most telling first. Inputs list these keys
/// first, then the rest alphabetically.
private let mainKeys = ["command", "file_path", "notebook_path", "path", "url", "query", "pattern",
                        "description", "prompt", "skill", "name"]

private func orderedKeys(_ o: [String: JSONValue]) -> [String] {
  mainKeys.filter { o[$0] != nil } + o.keys.filter { !mainKeys.contains($0) }.sorted()
}

private func numberText(_ d: Double) -> String {
  d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
}

private func counted(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

/// One value for the one-line `key: value` form: strings one-lined, nested values summarised.
private func compactValue(_ v: JSONValue) -> String {
  switch v {
  case .string(let s): return oneLine(s, max: 100)
  case .number(let d): return numberText(d)
  case .bool(let b): return b ? "true" : "false"
  case .null: return "null"
  case .array(let a): return a.isEmpty ? "[]" : "[" + counted(a.count, "item", "items") + "]"
  case .object(let o): return o.isEmpty ? "{}" : "{" + counted(o.count, "key", "keys") + "}"
  }
}

/// A tool input on one line, `key: value, key: value`, at most `max` characters.
func compactInput(_ input: JSONValue, max: Int = 300) -> String {
  guard let o = input.object else { return oneLine(compactValue(input), max: max) }
  return oneLine(orderedKeys(o).map { $0 + ": " + compactValue(o[$0]!) }.joined(separator: ", "), max: max)
}

/// The tool name, then its input in the one-line form.
private func nameAndInput(_ name: String, _ input: JSONValue) -> String {
  let args = compactInput(input)
  return args.isEmpty ? name : name + "\n" + args
}

/// What the permission card shows: the command for Bash, the path for file tools, the URL or query
/// for web tools, the pattern and folder for searches, the description for helper agents, the skill's
/// name; otherwise the tool name and its input. At most 3 lines are shown.
func cardText(_ name: String, _ input: JSONValue) -> String {
  switch name {
  case "Bash":
    // The first three lines, then "…" if anything but blank lines follows. maxSplits keeps a huge
    // command's remainder in one piece instead of splitting all of it.
    var lines = Array((input["command"]?.string ?? "")
      .split(maxSplits: 3, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }))
    let more = lines.count == 4 && lines[3].contains(where: { !$0.isNewline })
    if lines.count == 4 { lines.removeLast() }
    if !more { while let last = lines.last, last.isEmpty { lines.removeLast() } }
    let head = lines.joined(separator: "\n")
    return more ? head + "\n…" : head
  case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
    return Paths.abbreviate(input["file_path"]?.string ?? input["notebook_path"]?.string ?? "")
  case "WebFetch": return input["url"]?.string ?? ""
  case "WebSearch": return input["query"]?.string ?? ""
  case "Grep", "Glob":
    let pattern = oneLine(input["pattern"]?.string ?? "", max: 200)
    if pattern.isEmpty { return nameAndInput(name, input) }
    guard let path = input["path"]?.string, !path.isEmpty else { return pattern }
    return pattern + "\nin " + oneLine(Paths.abbreviate(path), max: 200)
  case "Agent", "Task":
    let about = oneLine(input["description"]?.string ?? input["prompt"]?.string ?? "", max: 300)
    return about.isEmpty ? nameAndInput(name, input) : about
  case "Skill":
    let skill = oneLine(input["skill"]?.string ?? "", max: 200)
    return skill.isEmpty ? nameAndInput(name, input) : skill
  default:
    if let m = mcpParts(name) {
      let args = compactInput(input)
      return m.server + " · " + m.tool + (args.isEmpty ? "" : "\n" + args)
    }
    return nameAndInput(name, input)
  }
}

/// `s` cut to `max` characters plus "…" if longer: as much as a `max`-character text can show.
private func head<S: StringProtocol>(_ s: S, max: Int) -> String {
  let h = s.prefix(max + 1)
  return h.count > max ? String(h.prefix(max)) + "…" : String(h)
}

/// `v` with every string cut to `max` characters and every array to `max` items: written out it
/// starts with the same `max` characters, but costs little however large `v` is.
private func pruned(_ v: JSONValue, max: Int) -> JSONValue {
  switch v {
  case .string(let s): return .string(head(s, max: max))
  case .array(let a): return .array(a.prefix(max + 1).map { pruned($0, max: max) })
  case .object(let o): return .object(o.mapValues { pruned($0, max: max) })
  default: return v
  }
}

/// A value in full (up to `max` characters): strings as they are, nested values as compact JSON.
private func fullValue(_ v: JSONValue, max: Int) -> String {
  switch v {
  case .string(let s): return head(s, max: max)
  case .array, .object:
    let data = try? JSONSerialization.data(withJSONObject: jsonAny(pruned(v, max: max)),
                                           options: [.sortedKeys, .withoutEscapingSlashes])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? compactValue(v)
  default: return compactValue(v)
  }
}

/// Everything being asked, for the expanded row: the whole command for Bash, otherwise every
/// input key on its own line with its full value. At most `max` characters.
func fullRequestText(_ name: String, _ input: JSONValue, max: Int = 2000) -> String {
  if max < 1 { return "" }
  var text = ""
  if name == "Bash", let cmd = input["command"]?.string {
    // Room for trailing blank lines, which are trimmed, before deciding the command is too long.
    text = head(cmd.drop(while: { $0.isWhitespace }), max: max + 64)
    if !text.hasSuffix("…") { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
  } else if let o = input.object {
    for key in orderedKeys(o) {
      if !text.isEmpty { text += "\n" }
      text += key + ": " + fullValue(o[key]!, max: max)
      if text.count > max { break }
    }
  } else {
    text = fullValue(input, max: max)
  }
  if text.count > max { text = String(text.prefix(max - 1)) + "…" }
  return text
}
