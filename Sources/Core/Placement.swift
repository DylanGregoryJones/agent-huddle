import CoreGraphics
import Foundation

/// One display, in global Cocoa coordinates (origin bottom-left, y up): its whole frame and the part
/// not covered by the menu bar or Dock.
struct DisplayArea: Equatable {
  let frame: CGRect
  let visible: CGRect
}

/// Where the panel goes. the user drags it by its top bar; the point saved is the panel's top-left. The top
/// stays there as the list grows, unless the panel would run off the bottom of its display.
/// `displays[0]` is the main display (the one with the menu bar).
enum Placement {
  static let margin: CGFloat = 10

  /// The display a top-left point belongs to. A top-left owns the display to its right and below, so a
  /// point on the edge between two side-by-side displays belongs to the right-hand one: x in
  /// [minX, maxX), y in (minY, maxY]. Failing that, the first display within 1 pt of it.
  static func display(containing topLeft: CGPoint, in displays: [DisplayArea]) -> DisplayArea? {
    displays.first { f in
      let r = f.frame
      return topLeft.x >= r.minX && topLeft.x < r.maxX && topLeft.y > r.minY && topLeft.y <= r.maxY
    } ?? displays.first { $0.frame.insetBy(dx: -1, dy: -1).contains(topLeft) }
  }

  /// The panel's frame for content of `contentSize`. nil only when there are no displays.
  static func frame(contentSize: CGSize, savedTopLeft: CGPoint?, displays: [DisplayArea]) -> CGRect? {
    guard let main = displays.first else { return nil }
    let width = contentSize.width
    if let saved = savedTopLeft, let d = display(containing: saved, in: displays) {
      let v = d.visible
      let height = cappedHeight(contentSize.height, on: v)
      let top = max(min(saved.y, v.maxY), v.minY + margin + height)
      let x = min(max(saved.x, v.minX), v.maxX - width)
      return CGRect(x: x, y: top - height, width: width, height: height)
    }
    let v = main.visible
    let height = cappedHeight(contentSize.height, on: v)
    return CGRect(x: v.maxX - margin - width, y: v.maxY - margin - height, width: width, height: height)
  }

  /// The tallest the panel may be on the display it will sit on.
  static func maxHeight(savedTopLeft: CGPoint?, displays: [DisplayArea]) -> CGFloat? {
    guard let main = displays.first else { return nil }
    let d = savedTopLeft.flatMap { display(containing: $0, in: displays) } ?? main
    return d.visible.height - 2 * margin
  }

  /// The top-left to save after a drop at `frame`: on the display holding the frame's centre, else the
  /// one it overlaps most, pulled inside that display's visible area. nil when it overlaps no display.
  static func dropPoint(frame: CGRect, displays: [DisplayArea]) -> CGPoint? {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    let d = displays.first { $0.frame.contains(centre) } ?? displays
      .map { ($0, overlapArea($0.frame, frame)) }
      .filter { $0.1 > 0 }
      .max { $0.1 < $1.1 }?.0
    guard let d else { return nil }
    let v = d.visible
    let height = min(frame.height, v.height - 2 * margin)
    let x = min(max(frame.minX, v.minX), v.maxX - frame.width)
    let top = min(max(frame.maxY, v.minY + margin + height), v.maxY)
    return CGPoint(x: x, y: top)
  }

  /// How far the pointer must move before a press on the top bar counts as a drag rather than a click.
  static let dragThreshold: CGFloat = 3

  static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
    hypot(end.x - start.x, end.y - start.y) > dragThreshold
  }

  private static func cappedHeight(_ h: CGFloat, on visible: CGRect) -> CGFloat {
    min(ceil(h), visible.height - 2 * margin)
  }

  private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    return i.isNull ? 0 : i.width * i.height
  }
}
