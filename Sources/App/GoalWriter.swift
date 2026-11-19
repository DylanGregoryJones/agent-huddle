import Foundation

/// What the "Working towards" section shows.
enum GoalDisplay: Equatable {
  case working
  case text(String)
}

/// Writes each session's "Working towards" line by asking Claude (Haiku) when the user opens its row,
/// at most two at a time, and remembers the answers in goals.json so reopening doesn't ask again.
@MainActor
final class GoalWriter {
  typealias Runner = @Sendable (_ binary: String, _ prompt: String) -> String?

  static let maxRunning = 2
  static let retryAfter: TimeInterval = 60
  nonisolated static let timeout: TimeInterval = 45

  /// sessionId and what its section should now show.
  var onChange: (String, GoalDisplay?) -> Void = { _, _ in }

  private struct Job {
    let id: String
    let binary: String
    let prompt: String
    let messageCount: Int
  }

  private let cachePath: String
  private let run: Runner
  private var cache: GoalCache
  private var running: Set<String> = []
  private var queued: [Job] = []
  private var failedAt: [String: Date] = [:]
  private let work = DispatchQueue(label: "agent-huddle.goals", attributes: .concurrent)

  init(cachePath: String = Paths.goalsPath, run: @escaping Runner = { GoalWriter.runClaude(binary: $0, prompt: $1) }) {
    self.cachePath = cachePath
    self.run = run
    var c = GoalCache.load(cachePath)
    c.prune(now: Date())
    cache = c
  }

  /// The last description, or "Working it out…" while the first one is being written.
  func display(_ sessionId: String) -> GoalDisplay? {
    if let text = cache.entries[sessionId]?.text { return .text(text) }
    let inFlight = running.contains(sessionId) || queued.contains { $0.id == sessionId }
    return inFlight ? .working : nil
  }

  /// Asks Claude for this row's description unless the remembered one still covers every message,
  /// one is already being written, or the last try failed under a minute ago.
  func request(_ row: AgentRow) {
    let id = row.id
    guard cache.needsRefresh(sessionId: id, messageCount: row.messageCount),
          !running.contains(id), !queued.contains(where: { $0.id == id }) else { return }
    if let failed = failedAt[id], Date().timeIntervalSince(failed) < Self.retryAfter { return }
    guard let binary = pickClaudeBinary(sessionBinary: ProcessReader.executablePath(of: row.pid), home: Paths.home,
                                        exists: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      failedAt[id] = Date()
      return
    }
    queued.append(Job(id: id, binary: binary, prompt: GoalPrompt.text(title: row.title, messages: row.goalMessages),
                      messageCount: row.messageCount))
    onChange(id, display(id))
    startNext()
  }

  private func startNext() {
    while running.count < Self.maxRunning, !queued.isEmpty {
      let job = queued.removeFirst()
      running.insert(job.id)
      let run = self.run
      work.async {
        let text = run(job.binary, job.prompt)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.finish(job, text: text) }
        }
      }
    }
  }

  private func finish(_ job: Job, text: String?) {
    running.remove(job.id)
    if let text {
      failedAt[job.id] = nil
      cache.entries[job.id] = GoalEntry(text: text, messageCount: job.messageCount, madeAt: Date())
      cache.prune(now: Date())
      try? cache.save(cachePath)
    } else {
      failedAt[job.id] = Date()
    }
    onChange(job.id, display(job.id))
    startNext()
  }

  /// `claude -p` with `GoalCommand.arguments`, run from a fresh empty folder in the temporary directory
  /// so no git status, CLAUDE.md or project settings of the user's go with it. The prompt goes in and the
  /// answer comes back through files in that folder, so a stray child process holding a pipe open can
  /// never hang the read. nil on any failure, an error answer, or after 45 s.
  nonisolated static func runClaude(binary: String, prompt: String) -> String? {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "agent-huddle-goal-" + UUID().uuidString
    guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])) != nil else { return nil }
    defer { try? fm.removeItem(atPath: dir) }
    let inPath = dir + "/prompt.txt", outPath = dir + "/answer.json"
    guard fm.createFile(atPath: inPath, contents: Data(prompt.utf8), attributes: [.posixPermissions: 0o600]),
          fm.createFile(atPath: outPath, contents: nil, attributes: [.posixPermissions: 0o600]),
          let input = FileHandle(forReadingAtPath: inPath),
          let output = FileHandle(forWritingAtPath: outPath) else { return nil }
    defer {
      try? input.close()
      try? output.close()
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: binary)
    p.arguments = GoalCommand.arguments
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["TERM_PROGRAM"] = nil
    p.environment = env
    p.standardInput = input
    p.standardOutput = output
    p.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { return nil }
    guard exited.wait(timeout: .now() + timeout) == .success else {
      p.terminate()
      return nil
    }
    guard p.terminationStatus == 0, let data = fm.contents(atPath: outPath) else { return nil }
    return parseGoalOutput(data)
  }
}
