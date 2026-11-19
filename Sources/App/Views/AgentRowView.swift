import SwiftUI

/// One agent: the icon, name and doing line, plus its permission card when a request is waiting
/// and its detail when expanded.
struct AgentRowView: View {
  let row: AgentRow
  @ObservedObject var store: HuddleStore

  private var expanded: Bool { store.expandedId == row.id }
  private var needsYou: Bool { row.state == .needsYou }
  private var jumpMessage: String? { store.jumpMessages[row.id] }

  var body: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(needsYou ? Ink.amber.opacity(0.35) : Color.white.opacity(0.06))
        .frame(height: 1)
      line
      if let pending = row.pending, let text = row.cardText {
        PermissionCard(text: text, pending: pending, layoutChangedAt: store.layoutChangedAt,
                       deny: { store.deny(row) }, allow: { store.allow(row) })
          .id(pending.id)   // a fresh card, and a fresh click guard, for every request
      }
      if expanded {
        DetailView(row: row, goal: store.goals[row.id], jumpMessage: jumpMessage, open: { store.jump(row) })
      }
    }
    .background(needsYou ? Ink.amber.opacity(0.13) : Color.clear)
  }

  private var line: some View {
    HStack(spacing: 9) {
      CreatureIcon(colorHex: ColourAssigner.palette[row.colorIndex % ColourAssigner.palette.count], state: row.state)
      VStack(alignment: .leading, spacing: 0) {
        Text(row.name)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(Ink.primary)
          .lineLimit(1)
          .frame(height: 18)
        doingLine
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: { store.jump(row) }) {
        Text(">_")
          .font(.custom("Menlo-Bold", size: 9))
          .foregroundColor(Ink.jump)
          .padding(.vertical, 3)
          .padding(.horizontal, 5)
          .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open in Terminal")
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 11)
    .background(expanded && !needsYou ? Color.white.opacity(0.05) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { store.expandedId = expanded ? nil : row.id }
  }

  /// One line, cut with "…". "Needs permission · answer in Terminal" and "Needs you · answer in
  /// Terminal" may take two lines instead, so the words that say what to do aren't the ones cut,
  /// and a failed jump's message (shown here while the row is closed) up to four.
  @ViewBuilder private var doingLine: some View {
    let message = expanded ? nil : jumpMessage
    let text = Text(message ?? row.doing)
      .font(.system(size: 11))
      .foregroundColor(needsYou ? Ink.askDoing : Ink.secondary)
      .truncationMode(.tail)
    if row.answerInTerminal || message != nil {
      text
        .lineLimit(message != nil ? 4 : 2)
        .lineHeight(16.5, natural: 14)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      text
        .lineLimit(1)
        .frame(height: 16.5)
    }
  }
}

/// What's being asked, with Deny and Allow. The buttons ignore clicks until 0.5 s after the card
/// appears, counted from when it was first shown (that can be well after the request arrived), and
/// again for 0.5 s after anything moves the rows, so an Allow that slides under the pointer can't take a click.
struct PermissionCard: View {
  let text: String
  let pending: PendingRequest
  let layoutChangedAt: Date
  let deny: () -> Void
  let allow: () -> Void

  @Environment(\.huddleRendering) private var rendering
  @State private var shownAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(text)
        .font(.custom("Menlo", size: 10))
        .foregroundColor(Ink.command)
        .lineLimit(3)
        .truncationMode(.tail)
        .lineHeight(13.5, natural: 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .padding(.top, 2)
        .padding(.bottom, 8)
      buttons
        .padding(.bottom, 10)
    }
    .padding(.leading, 50)
    .padding(.trailing, 11)
    .padding(.vertical, 1)
    .onAppear { if shownAt == nil { shownAt = Date() } }
  }

  /// The render modes draw one frame, so there the guard counts from the request instead.
  private var guardStart: Date? {
    rendering ? pending.receivedAt : shownAt.map { max(pending.receivedAt, $0, layoutChangedAt) }
  }

  @ViewBuilder private var buttons: some View {
    if let start = guardStart {
      TimelineView(.periodic(from: start, by: 0.25)) { context in
        buttonRow(armed: context.date >= start.addingTimeInterval(0.5))
      }
    } else {
      buttonRow(armed: false)
    }
  }

  private func buttonRow(armed: Bool) -> some View {
    HStack(spacing: 6) {
      Button("Deny", action: deny).buttonStyle(PillButtonStyle(fill: Color.white.opacity(0.1), text: Ink.primary))
      Button("Allow", action: allow).buttonStyle(PillButtonStyle(fill: Ink.blue, text: .white))
    }
    .disabled(!armed)
  }
}

/// The mock-ups' rounded, full-width button.
struct PillButtonStyle: ButtonStyle {
  let fill: Color
  let text: Color

  func makeBody(configuration: Configuration) -> some View {
    PillLabel(label: configuration.label, pressed: configuration.isPressed, fill: fill, text: text)
  }

  private struct PillLabel<Label: View>: View {
    let label: Label
    let pressed: Bool
    let fill: Color
    let text: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      label
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(text)
        .frame(maxWidth: .infinity)
        .frame(height: 16.5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(fill))
        .contentShape(Rectangle())
        .opacity(!enabled ? 0.45 : pressed ? 0.75 : 1)
    }
  }
}
