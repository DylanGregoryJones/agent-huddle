import Foundation

struct HookPayload: Equatable {
  let sessionId: String
  let toolName: String
  let toolInput: JSONValue
  let cwd: String?
}

func parseHookPayload(_ data: Data) -> HookPayload? {
  guard let json = JSONValue.parse(data),
        let sessionId = json["session_id"]?.string,
        let toolName = json["tool_name"]?.string else { return nil }
  return HookPayload(sessionId: sessionId, toolName: toolName,
                     toolInput: json["tool_input"] ?? .object([:]), cwd: json["cwd"]?.string)
}

func isQuestionTool(_ name: String) -> Bool {
  name == "AskUserQuestion" || name == "ExitPlanMode"
}

enum HookGate: Equatable {
  case handle(HookPayload), passThrough
}

func gate(payloadData: Data, env: [String: String]) -> HookGate {
  guard env["TERM_PROGRAM"] == "Apple_Terminal",
        let payload = parseHookPayload(payloadData),
        !isQuestionTool(payload.toolName) else { return .passThrough }
  return .handle(payload)
}

enum Decision: String { case allow, deny }

func decisionOutput(_ d: Decision) -> String {
  switch d {
  case .allow:
    return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
  case .deny:
    return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Agent Huddle","interrupt":true}}}"#
  }
}

struct PendingRequest: Equatable, Identifiable {
  let id: String
  let sessionId: String
  let toolName: String
  let toolInput: JSONValue
  let receivedAt: Date
}

/// The Foundation object for `v`, for JSONSerialization.
func jsonAny(_ v: JSONValue) -> Any {
  switch v {
  case .string(let s): return s
  case .number(let d): return d
  case .bool(let b): return b
  case .null: return NSNull()
  case .array(let a): return a.map(jsonAny)
  case .object(let o): return o.mapValues(jsonAny)
  }
}

private func line(_ obj: [String: Any]) -> Data {
  var d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
  d.append(0x0A)
  return d
}

func encodeRequestLine(id: String, payload: HookPayload) -> Data {
  line(["type": "request", "id": id, "sessionId": payload.sessionId,
        "toolName": payload.toolName, "toolInput": jsonAny(payload.toolInput)])
}

func decodeRequestLine(_ line: Data, receivedAt: Date) -> PendingRequest? {
  guard let j = JSONValue.parse(line), j["type"]?.string == "request",
        let id = j["id"]?.string, let sid = j["sessionId"]?.string,
        let tool = j["toolName"]?.string else { return nil }
  return PendingRequest(id: id, sessionId: sid, toolName: tool,
                        toolInput: j["toolInput"] ?? .object([:]), receivedAt: receivedAt)
}

func encodeDecisionLine(id: String, _ d: Decision) -> Data {
  line(["type": "decision", "id": id, "behavior": d.rawValue])
}

func decodeDecisionLine(_ line: Data) -> (id: String, decision: Decision)? {
  guard let j = JSONValue.parse(line), j["type"]?.string == "decision",
        let id = j["id"]?.string, let b = j["behavior"]?.string,
        let d = Decision(rawValue: b) else { return nil }
  return (id, d)
}

/// True once the session has been seen "waiting" and then two consecutive reads show it
/// not waiting (the user answered in Terminal). Two reads, so one registry file caught
/// mid-write does not end a live request. Also true as soon as Claude itself has died:
/// its record's pid was seen alive and is now dead.
struct AnsweredElsewhereWatch {
  private(set) var sawWaiting = false
  private(set) var sawAlive = false
  private var notWaitingStreak = 0
  /// `alive`: whether the record's pid is alive; nil when there's no record.
  mutating func update(status: String?, alive: Bool? = nil) -> Bool {
    if alive == true { sawAlive = true }
    if alive == false && sawAlive { return true }
    if status == "waiting" { sawWaiting = true; notWaitingStreak = 0; return false }
    guard sawWaiting else { return false }
    notWaitingStreak += 1
    return notWaitingStreak >= 2
  }
}
