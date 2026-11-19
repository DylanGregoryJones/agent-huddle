import AppKit

/// How a jump to a Terminal tab went.
enum JumpResult: Equatable {
  case focused
  /// No tab on that tty, Terminal isn't running, or it didn't answer in time.
  case notFound
  /// macOS hasn't let Agent Huddle control Terminal (Privacy & Security › Automation).
  case notAuthorized
}

/// Brings the Terminal tab on a given tty to the front.
enum TerminalBridge {
  private static let script = """
    on run argv
      set wanted to item 1 of argv
      if application "Terminal" is not running then return "false"
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if (tty of t) is wanted then
              if miniaturized of w then set miniaturized of w to false
              set selected of t to true
              set index of w to 1
              activate
              return "true"
            end if
          end repeat
        end repeat
      end tell
      return "false"
    end run
    """

  /// Blocks while osascript runs, at most `timeout` seconds; a hung Terminal counts as not found.
  /// While macOS's one-time "control Terminal" prompt is waiting for an answer, osascript waits too,
  /// so it gets `consentTimeout` instead and the first click still works once the user clicks OK.
  static func focus(tty: String?, timeout: TimeInterval = 5, consentTimeout: TimeInterval = 120) -> JumpResult {
    guard let tty else { return .notFound }
    let permission = automationPermission()
    if permission == OSStatus(errAEEventNotPermitted) { return .notAuthorized }
    let limit = permission == OSStatus(errAEEventWouldRequireUserConsent) ? consentTimeout : timeout

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script, tty]   // the tty goes in as an argument, never into the script text
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { return .notFound }
    guard exited.wait(timeout: .now() + limit) == .success else {
      p.terminate()
      return automationPermission() == OSStatus(errAEEventWouldRequireUserConsent) ? .notAuthorized : .notFound
    }
    let answer = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if p.terminationStatus == 0 && answer == "true" { return .focused }
    // e.g. "execution error: Not authorized to send Apple events to Terminal. (-1743)"
    if problem.contains("(-1743)") { return .notAuthorized }
    return .notFound
  }

  /// Whether Agent Huddle may send Terminal Apple events, without ever showing a prompt: noErr,
  /// errAEEventNotPermitted (-1743, refused), errAEEventWouldRequireUserConsent (-1744, not asked
  /// yet or the prompt is up) or procNotFound (-600, Terminal isn't running).
  private static func automationPermission() -> OSStatus {
    guard let desc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal").aeDesc else { return noErr }
    return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
  }
}
