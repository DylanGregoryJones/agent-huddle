import AppKit
import Carbon
import SwiftUI

signal(SIGPIPE, SIG_IGN)

@MainActor
func writePNG(_ view: some View, to path: String) -> Bool {
  let renderer = ImageRenderer(content: view)
  renderer.scale = 2
  guard let image = renderer.cgImage,
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
  return FileManager.default.createFile(atPath: path, contents: png)
}

/// A store whose server is never started: the render modes bind nothing.
@MainActor
func offlineStore() -> HuddleStore {
  HuddleStore(server: PermissionServer(socketPath: Paths.socketPath, onChange: { _ in }))
}

@MainActor
func renderDemo(to dir: String) -> Bool {
  let store = offlineStore()
  store.rows = DemoData.rows
  store.hookInstalled = true
  guard writePNG(PanelView(store: store, rendering: true), to: dir + "/demo-list.png") else { return false }
  store.goals[DemoData.webAppId] = .text(DemoData.webAppGoal)
  store.expandedId = DemoData.webAppId
  return writePNG(PanelView(store: store, rendering: true), to: dir + "/demo-detail.png")
}

/// One real tick with live data, rendered like the demo.
@MainActor
func renderLive(to dir: String) -> Bool {
  let store = offlineStore()
  store.refreshNow()
  return writePNG(PanelView(store: store, rendering: true), to: dir + "/live-list.png")
}

let arguments = CommandLine.arguments
for (flag, render) in [("--render-demo", renderDemo), ("--render-live", renderLive)] {
  if let i = arguments.firstIndex(of: flag), i + 1 < arguments.count {
    let dir = arguments[i + 1]
    exit(MainActor.assumeIsolated { render(dir) } ? 0 : 1)
  }
}

/// Brings the panel back when the app is opened again while it's running (Spotlight, Finder, the
/// Open launcher), which is the fallback if another app already holds the shortcut.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var onReopen: () -> Void = {}

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    onReopen()
    return false
  }
}

// One panel at a time.
let me = getpid()
if NSRunningApplication.runningApplications(withBundleIdentifier: "local.agenthuddle")
  .contains(where: { $0.processIdentifier != me }) {
  exit(0)
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)

  var onServerChange: () -> Void = {}
  let server = PermissionServer(socketPath: Paths.socketPath) { _ in onServerChange() }
  let store = HuddleStore(server: server, goalWriter: GoalWriter())
  do {
    try server.start()
  } catch {
    // Without the socket the hook steps aside and prompts stay in Terminal; the list still works.
    FileHandle.standardError.write(Data("Agent Huddle: permission socket unavailable: \(error)\n".utf8))
    store.serverDown = true
  }
  onServerChange = { [weak store] in MainActor.assumeIsolated { store?.tick() } }

  let panel = HuddlePanel()
  // X only hides the panel: the app and its permission socket keep running, and nothing pops it up again
  // by itself (the user hides it before sharing his screen). ⌃⌥A or opening the app brings it back.
  let hide = { panel.orderOut(nil) }
  let hosting = PanelHostingView(rootView: PanelView(store: store))
  var cap: CGFloat = 0
  /// Rebuilds the view when the display the panel sits on allows a different height.
  func refreshCap() {
    let c = Placement.maxHeight(savedTopLeft: panel.savedTopLeft, displays: HuddlePanel.displays()) ?? 800
    guard c != cap else { return }
    cap = c
    hosting.rootView = PanelView(store: store, maxHeight: c, onClose: hide,
                                 onHeaderHeight: { [weak hosting] h in hosting?.headerHeight = h })
  }
  refreshCap()
  hosting.onFittingSizeChange = { [weak panel] size in panel?.place(contentSize: size) }
  hosting.onDragEnd = { [weak panel, weak hosting] in
    guard let panel, let hosting else { return }
    refreshCap()
    panel.place(contentSize: hosting.fittingSize)
  }
  panel.contentView = hosting
  panel.place(contentSize: hosting.fittingSize)

  NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                         object: nil, queue: .main) { [weak panel, weak hosting] _ in
    MainActor.assumeIsolated {
      guard let panel, let hosting else { return }
      refreshCap()
      panel.place(contentSize: hosting.fittingSize)
    }
  }

  let show = {
    if !panel.isVisible { store.markLayoutChanged() }
    panel.place(contentSize: hosting.fittingSize)
    panel.orderFrontRegardless()
  }
  let delegate = AppDelegate()
  delegate.onReopen = show
  app.delegate = delegate
  let hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey)) {
    MainActor.assumeIsolated { panel.isVisible ? hide() : show() }
  }
  if hotKey == nil {
    FileHandle.standardError.write(Data("Agent Huddle: Control-Option-A is taken by another app\n".utf8))
  }

  show()
  store.startTicking()
  // The delegate (NSApp holds it weakly), the shortcut and the panel live as long as the app.
  withExtendedLifetime((delegate, hotKey, panel, hosting)) { app.run() }
}
