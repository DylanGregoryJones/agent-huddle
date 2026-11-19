import AppKit
import SwiftUI

/// A floating corner panel that never takes keyboard focus or activates the app.
final class HuddlePanel: NSPanel {
  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 262, height: 40),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false   // the app is never active, so the panel must not hide with it
    isReleasedWhenClosed = false
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Every display as `Placement` wants them: global coordinates, the menu-bar display first.
  static func displays() -> [DisplayArea] {
    NSScreen.screens.map { DisplayArea(frame: $0.frame, visible: $0.visibleFrame) }
  }

  private static let savedKey = "panelTopLeft"

  /// Where the user last dropped the panel (its top-left, global coordinates), kept across restarts.
  var savedTopLeft: CGPoint? {
    get {
      guard let xy = UserDefaults.standard.array(forKey: Self.savedKey) as? [Double], xy.count == 2 else { return nil }
      return CGPoint(x: xy[0], y: xy[1])
    }
    set {
      if let p = newValue {
        UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: Self.savedKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
      }
    }
  }

  /// True while the user is dragging it: size changes then keep the top-left under the pointer.
  var isDragging = false

  /// At the saved spot (or top right of the main display), as tall as the content allows.
  func place(contentSize: NSSize) {
    let target: NSRect
    if isDragging {
      let height = ceil(contentSize.height)
      target = NSRect(x: frame.minX, y: frame.maxY - height, width: contentSize.width, height: height)
    } else {
      guard let f = Placement.frame(contentSize: contentSize, savedTopLeft: savedTopLeft, displays: Self.displays())
      else { return }
      target = f
    }
    if target != frame {
      setFrame(target, display: true)
      invalidateShadow()
    }
  }
}

/// Hosts the panel's SwiftUI. Takes the first click, so buttons work without bringing the panel forward,
/// and reports when its fitting size may have changed.
final class PanelHostingView: NSHostingView<PanelView> {
  var onFittingSizeChange: ((NSSize) -> Void)?
  /// Called after a drag ends and the drop point has been saved.
  var onDragEnd: (() -> Void)?
  /// The header's height: a press there, left of the X, drags the panel.
  var headerHeight: CGFloat = 0
  private var lastFittingSize = NSSize.zero
  private var checkScheduled = false
  /// Pointer and panel origin when the drag started, in screen coordinates.
  private var dragStart: (mouse: NSPoint, origin: NSPoint)?

  /// The X's strip at the header's right end, which stays a button.
  private static let closeButtonWidth: CGFloat = 28

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let panel = window as? HuddlePanel, inDragBand(convert(event.locationInWindow, from: nil)) else {
      super.mouseDown(with: event)
      return
    }
    dragStart = (NSEvent.mouseLocation, panel.frame.origin)
    panel.isDragging = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStart, let panel = window else {
      super.mouseDragged(with: event)
      return
    }
    let now = NSEvent.mouseLocation
    panel.setFrameOrigin(NSPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y))
  }

  override func mouseUp(with event: NSEvent) {
    guard let start = dragStart, let panel = window as? HuddlePanel else {
      super.mouseUp(with: event)
      return
    }
    dragStart = nil
    panel.isDragging = false
    // A click that barely moved isn't a drop: saving then would pin a fallback or pushed-up position.
    if Placement.isDrag(from: start.mouse, to: NSEvent.mouseLocation),
       let p = Placement.dropPoint(frame: panel.frame, displays: HuddlePanel.displays()) {
      panel.savedTopLeft = p
    }
    onDragEnd?()
  }

  private func inDragBand(_ p: NSPoint) -> Bool {
    guard headerHeight > 0, p.x < bounds.width - Self.closeButtonWidth else { return false }
    return isFlipped ? p.y <= headerHeight : p.y >= bounds.height - headerHeight
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    scheduleSizeCheck()
  }

  // Needed as well: growing invalidates the intrinsic size, but shrinking only shows up as a layout pass.
  override func layout() {
    super.layout()
    scheduleSizeCheck()
  }

  private func scheduleSizeCheck() {
    guard !checkScheduled else { return }
    checkScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.checkScheduled = false
        let size = self.fittingSize
        guard size != self.lastFittingSize else { return }
        self.lastFittingSize = size
        self.onFittingSizeChange?(size)
      }
    }
  }
}
