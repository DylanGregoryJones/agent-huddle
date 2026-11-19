import SwiftUI

extension Color {
  /// "#RRGGBB" in sRGB. Anything unparsable is black.
  init(hex: String) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let v = digits.count == 6 ? UInt32(digits, radix: 16) ?? 0 : 0
    self.init(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: 1)
  }
}

/// The panel's colours, taken from the approved mock-ups.
enum Ink {
  static let primary = Color(hex: "#F2F2F4")
  static let secondary = Color(hex: "#A8A8B0")
  static let label = Color(hex: "#8E8E96")
  static let detail = Color(hex: "#D8D8DE")
  static let command = Color(hex: "#EAEAEA")
  static let jump = Color(hex: "#C8C8D0")
  static let askDoing = Color(hex: "#FFC66B")
  static let amber = Color(hex: "#FF9F0A")
  static let blue = Color(hex: "#0A84FF")
  static let dotRing = Color(hex: "#1C1C20")
  static let panel = Color(white: 0.11).opacity(0.9)

  static func state(_ s: AgentState) -> Color {
    switch s {
    case .working: return Color(hex: "#34C759")
    case .needsYou: return Color(hex: "#FF9F0A")
    case .idle: return Color(hex: "#8E8E93")
    }
  }
}
