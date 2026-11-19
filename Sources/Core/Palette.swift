import Foundation

func stableHash(_ s: String) -> UInt64 {
  var h: UInt64 = 0xcbf29ce484222325
  for b in s.utf8 {
    h ^= UInt64(b)
    h = h &* 0x100000001b3
  }
  return h
}

struct ColourAssigner {
  static let palette = ["#D97757", "#5B8DEF", "#A77BF3", "#3FBF8A", "#EF6FA8", "#E8C547", "#4FC3D9", "#9BC53D"]

  private var bySession: [String: Int] = [:]
  private var lastByFolder: [String: Int] = [:]

  /// `active` is ordered by startedAt, ascending. Returns sessionId -> palette index.
  mutating func assign(_ active: [(sessionId: String, folder: String)]) -> [String: Int] {
    let activeIds = Set(active.map { $0.sessionId })
    bySession = bySession.filter { activeIds.contains($0.key) }
    let count = Self.palette.count
    for s in active {
      if bySession[s.sessionId] != nil { continue }
      let used = Set(bySession.values)
      if let c = lastByFolder[s.folder], !used.contains(c) {
        bySession[s.sessionId] = c
      } else if let free = (0..<count).first(where: { !used.contains($0) }) {
        bySession[s.sessionId] = free
      } else {
        bySession[s.sessionId] = Int(stableHash(s.sessionId) % UInt64(count))
      }
    }
    for s in active { lastByFolder[s.folder] = bySession[s.sessionId] }
    return bySession
  }
}
