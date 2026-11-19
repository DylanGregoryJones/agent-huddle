import SwiftUI

/// The whole panel: header, then one row per agent. Rows scroll once the panel would pass `maxHeight`.
struct PanelView: View {
  @ObservedObject var store: HuddleStore
  var maxHeight: CGFloat = .greatestFiniteMagnitude
  /// The render modes: a solid card, because ImageRenderer can't draw materials, and permission
  /// cards whose click guard counts from the request, because a single frame can't wait to be seen.
  var rendering = false
  var onClose: () -> Void = {}
  /// Told the header's height, which is the strip that drags the panel.
  var onHeaderHeight: (CGFloat) -> Void = { _ in }

  @State private var headerHeight: CGFloat = 0
  @State private var rowsHeight: CGFloat = 0

  /// The border takes its own space, as in the mock-up's CSS.
  private let border: CGFloat = 1

  var body: some View {
    VStack(spacing: 0) {
      header
        .opacity(store.rows.isEmpty ? 0.6 : 1)
        .reportHeight { headerHeight = $0; onHeaderHeight($0) }
      if !store.rows.isEmpty {
        let rowsCap = maxHeight - 2 * border - headerHeight
        if rowsHeight > rowsCap {
          ScrollView(.vertical) { rowStack }
            .frame(height: max(0, rowsCap))
        } else {
          rowStack
        }
      }
    }
    .padding(border)
    .frame(width: 262)
    .background(background)
    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(Color.white.opacity(0.12), lineWidth: border))
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, .dark)
    .environment(\.huddleRendering, rendering)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Agent huddle")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(Ink.primary)
        Spacer(minLength: 4)
        Text(headerCount(store.rows))
          .font(.system(size: 11))
          .foregroundColor(Ink.secondary)
          .lineLimit(1)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Ink.secondary)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Agent Huddle")
      }
      .frame(height: 16.5)
      if let note = headerNote {
        Text(note)
          .font(.system(size: 10))
          .foregroundColor(Ink.amber)
          .frame(height: 15)
      }
    }
    .padding(.top, 8)
    .padding(.bottom, 6)
    .padding(.horizontal, 11)
  }

  /// Why Allow and Deny can't appear, if they can't. A missing hook comes first: reinstalling
  /// fixes it and restarts the panel too.
  private var headerNote: String? {
    if !store.hookInstalled { return "Permission buttons off · reinstall" }
    if store.serverDown { return "Permission buttons off · retrying" }
    return nil
  }

  private var rowStack: some View {
    VStack(spacing: 0) {
      ForEach(store.rows) { row in
        AgentRowView(row: row, store: store)
      }
    }
    .reportHeight { rowsHeight = $0 }
  }

  @ViewBuilder private var background: some View {
    if rendering {
      Ink.panel
    } else {
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        Ink.panel
      }
    }
  }
}

private struct HuddleRenderingKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// True inside `PanelView(rendering: true)`.
  var huddleRendering: Bool {
    get { self[HuddleRenderingKey.self] }
    set { self[HuddleRenderingKey.self] = newValue }
  }
}

extension View {
  /// Spaces lines like the mock-ups' CSS `line-height`: the extra goes between lines and half above
  /// and below. `natural` is SwiftUI's own line height for the font (measured: 14 for 11 pt system, 11 for Menlo 10).
  func lineHeight(_ height: CGFloat, natural: CGFloat) -> some View {
    let extra = max(0, height - natural)
    return lineSpacing(extra).padding(.vertical, extra / 2)
  }
}

private extension View {
  /// Calls `onChange` with this view's laid-out height, now and whenever it changes.
  func reportHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
    background(GeometryReader { g in
      Color.clear
        .onAppear { onChange(g.size.height) }
        .onChange(of: g.size.height) { _, h in onChange(h) }
    })
  }
}
