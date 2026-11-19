import SwiftUI

/// The Claude Code terminal mascot: the rects of the mock-up's `#clawd` symbol (viewBox 0 -1 16 12).
struct CreatureShape: Shape {
  private static let viewBox = CGRect(x: 0, y: -1, width: 16, height: 12)
  private static let rects: [CGRect] = [
    CGRect(x: 2, y: 0, width: 12, height: 2),
    CGRect(x: 2, y: 2, width: 2, height: 2), CGRect(x: 5, y: 2, width: 6, height: 2), CGRect(x: 12, y: 2, width: 2, height: 2),
    CGRect(x: 0, y: 4, width: 16, height: 2),
    CGRect(x: 2, y: 6, width: 12, height: 2),
    CGRect(x: 3, y: 8, width: 1, height: 2), CGRect(x: 5, y: 8, width: 1, height: 2),
    CGRect(x: 10, y: 8, width: 1, height: 2), CGRect(x: 12, y: 8, width: 1, height: 2),
  ]

  func path(in rect: CGRect) -> Path {
    // Same as SVG's default preserveAspectRatio (xMidYMid meet).
    let vb = Self.viewBox
    let s = min(rect.width / vb.width, rect.height / vb.height)
    let ox = rect.minX + (rect.width - vb.width * s) / 2 - vb.minX * s
    let oy = rect.minY + (rect.height - vb.height * s) / 2 - vb.minY * s
    var p = Path()
    for r in Self.rects {
      p.addRect(CGRect(x: ox + r.minX * s, y: oy + r.minY * s, width: r.width * s, height: r.height * s))
    }
    return p
  }
}

/// The row icon: the creature in the session's colour, with a state dot. It bobs while working.
struct CreatureIcon: View {
  let colorHex: String
  let state: AgentState

  var body: some View {
    ZStack {
      if state == .working {
        PhaseAnimator([0.0, -1.0]) { phase in
          creature.offset(y: phase)
        } animation: { _ in .easeInOut(duration: 0.6) }
      } else {
        creature
      }
    }
    .frame(width: 30, height: 30)
    .overlay(alignment: .bottomTrailing) {
      Circle()
        .fill(Ink.state(state))
        .overlay(Circle().strokeBorder(Ink.dotRing, lineWidth: 2))
        .frame(width: 9, height: 9)
        .offset(x: 2, y: 1)
    }
  }

  private var creature: some View {
    CreatureShape().fill(Color(hex: colorHex)).frame(width: 28, height: 21)
  }
}
