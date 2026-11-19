import SwiftUI

/// The expanded part of a row: folder, how long it has run, what it's working towards, the whole
/// pending request, the last prompt, steps and reply.
struct DetailView: View {
  let row: AgentRow
  let goal: GoalDisplay?
  let jumpMessage: String?
  let open: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text(row.folder).lineLimit(1).truncationMode(.middle)
        if !row.runningFor.isEmpty { Text(row.runningFor).lineLimit(1).fixedSize() }
      }
      .font(.system(size: 10))
      .foregroundColor(Ink.label)
      .frame(height: 15)
      .padding(.top, 2)

      if let goal {
        label("Working towards")
        switch goal {
        case .working:
          Text("Working it out…").foregroundColor(Ink.label)
        case .text(let s):
          Text(s)
            .lineHeight(15.4, natural: 14)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let full = row.fullRequest {
        label("Full request")
        FullRequestBox(text: full)
      }
      if let asked = row.youAsked {
        label("You asked")
        quote(asked)
      }
      if !row.steps.isEmpty {
        label("Last steps")
        ForEach(Array(row.steps.enumerated()), id: \.offset) { _, step in
          HStack(spacing: 6) {
            Text(step.age).foregroundColor(Ink.label).frame(width: 34, alignment: .leading)
            Text(step.text).lineLimit(1).truncationMode(.tail)
          }
          .frame(height: 16.5)
        }
      }
      if let said = row.claudeSaid {
        label("Claude last said")
        quote(said)
      }

      Button("Open in Terminal", action: open)
        .buttonStyle(PillButtonStyle(fill: Ink.blue, text: .white))
        .padding(.top, 9)
      if let jumpMessage {
        Text(jumpMessage)
          .font(.system(size: 10))
          .foregroundColor(Ink.askDoing)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .padding(.top, 5)
      }
    }
    .font(.system(size: 11))
    .foregroundColor(Ink.detail)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 2)
    .padding(.bottom, 10)
    .padding(.leading, 50)
    .padding(.trailing, 11)
    .background(Color.white.opacity(0.05))
  }

  private func label(_ s: String) -> some View {
    Text(s.uppercased())
      .font(.system(size: 9))
      .tracking(0.54)
      .foregroundColor(Ink.label)
      .frame(height: 13.5)
      .padding(.top, 8)
      .padding(.bottom, 3)
  }

  private func quote(_ s: String) -> some View {
    Text("\"" + s + "\"")
      .lineHeight(15.4, natural: 14)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 5)
      .padding(.horizontal, 7)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
  }
}

/// Everything the pending request asks (already capped at 2,000 characters), in Menlo and
/// selectable. Long requests scroll inside a box about twelve lines tall.
private struct FullRequestBox: View {
  let text: String

  @Environment(\.huddleRendering) private var rendering

  private static let lineHeight: CGFloat = 13.5
  private static let maxLines = 12
  /// Menlo 10 is about 6 pt a character; the box's text is about 185 pt wide.
  private static let charsPerLine = 30

  /// Lines the text will take once wrapped, estimated, and enough to decide whether to scroll.
  private var estimatedLines: Int {
    text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
      .reduce(0) { $0 + max(1, ($1.count + Self.charsPerLine - 1) / Self.charsPerLine) }
  }

  var body: some View {
    let content = Text(text)
      .font(.custom("Menlo", size: 10))
      .foregroundColor(Ink.command)
      .lineHeight(Self.lineHeight, natural: 11)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 5)
      .padding(.horizontal, 7)
    Group {
      if estimatedLines <= Self.maxLines {
        content
      } else if rendering {   // ImageRenderer can't draw a scroll view: show the top of it
        content.frame(height: Self.boxHeight, alignment: .top).clipped()
      } else {
        ScrollView(.vertical) { content }.frame(height: Self.boxHeight)
      }
    }
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
  }

  private static var boxHeight: CGFloat { CGFloat(maxLines) * lineHeight + 10 }
}
