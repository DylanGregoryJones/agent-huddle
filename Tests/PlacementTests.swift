import CoreGraphics
import Foundation

func placementTests() {
  let main = DisplayArea(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                         visible: CGRect(x: 0, y: 0, width: 1000, height: 770))
  let second = DisplayArea(frame: CGRect(x: 1000, y: 0, width: 1000, height: 600),
                           visible: CGRect(x: 1000, y: 0, width: 1000, height: 600))
  let displays = [main, second]
  func size(_ h: CGFloat) -> CGSize { CGSize(width: 262, height: h) }
  let defaultFrame = CGRect(x: 728, y: 560, width: 262, height: 200)

  test("placement: no saved point sits top right of the main display") {
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: nil, displays: displays), defaultFrame)
  }
  test("placement: a saved point keeps its top-left") {
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: CGPoint(x: 1100, y: 500), displays: displays),
                CGRect(x: 1100, y: 300, width: 262, height: 200))
  }
  test("placement: growing past the bottom pushes it up") {
    expectEqual(Placement.frame(contentSize: size(300), savedTopLeft: CGPoint(x: 1100, y: 150), displays: displays),
                CGRect(x: 1100, y: 10, width: 262, height: 300))
  }
  test("placement: shrinking again brings it back down to the saved top") {
    expectEqual(Placement.frame(contentSize: size(100), savedTopLeft: CGPoint(x: 1100, y: 150), displays: displays),
                CGRect(x: 1100, y: 50, width: 262, height: 100))
  }
  test("placement: kept inside the display horizontally") {
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: CGPoint(x: 1900, y: 500), displays: displays)?.minX,
                1738)
  }
  test("placement: never taller than the display allows") {
    expectEqual(Placement.frame(contentSize: size(900), savedTopLeft: CGPoint(x: 1100, y: 500), displays: displays),
                CGRect(x: 1100, y: 10, width: 262, height: 580))
  }
  test("placement: a saved point on no display falls back to the default") {
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: CGPoint(x: 5000, y: 500), displays: displays),
                defaultFrame)
  }
  test("placement: a saved point above the visible area stays under the menu bar") {
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: CGPoint(x: 100, y: 790), displays: displays)?.maxY,
                770)
  }
  test("placement: fractional heights round up") {
    expectEqual(Placement.frame(contentSize: size(200.4), savedTopLeft: nil, displays: displays)?.height, 201)
  }
  test("placement: no displays gives no frame") {
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: nil, displays: []), nil)
  }
  test("placement: max height follows the saved point's display") {
    expectEqual(Placement.maxHeight(savedTopLeft: CGPoint(x: 1100, y: 500), displays: displays), 580)
    expectEqual(Placement.maxHeight(savedTopLeft: nil, displays: displays), 750)
    expectEqual(Placement.maxHeight(savedTopLeft: nil, displays: []), nil)
  }
  test("placement: a drop inside a display is saved as dropped") {
    expectEqual(Placement.dropPoint(frame: CGRect(x: 1200, y: 100, width: 262, height: 200), displays: displays),
                CGPoint(x: 1200, y: 300))
  }
  test("placement: a drop straddling two displays goes to the one holding its centre") {
    expectEqual(Placement.dropPoint(frame: CGRect(x: 950, y: 300, width: 262, height: 200), displays: displays)?.x,
                1000)
  }
  test("placement: a drop past the right edge is pulled back in") {
    expectEqual(Placement.dropPoint(frame: CGRect(x: 1900, y: 300, width: 262, height: 200), displays: displays)?.x,
                1738)
  }
  test("placement: a drop on no display isn't saved") {
    expectEqual(Placement.dropPoint(frame: CGRect(x: 5000, y: 300, width: 262, height: 200), displays: displays), nil)
  }
  test("placement: a drop above the visible area is saved under the menu bar") {
    expectEqual(Placement.dropPoint(frame: CGRect(x: 100, y: 700, width: 262, height: 200), displays: displays),
                CGPoint(x: 100, y: 770))
  }
  test("placement: a drop straddling two displays stays on the one holding its centre") {
    let saved = Placement.dropPoint(frame: CGRect(x: 950, y: 300, width: 262, height: 200), displays: displays)
    expectEqual(Placement.frame(contentSize: size(200), savedTopLeft: saved, displays: displays)?.minX, 1000)
  }
  test("placement: a drop over a gap stays on the display it was dropped on") {
    let saved = Placement.dropPoint(frame: CGRect(x: 1000, y: 500, width: 262, height: 400), displays: displays)
    expectEqual(Placement.frame(contentSize: size(400), savedTopLeft: saved, displays: displays)?.minX, 1000)
  }
  test("placement: a point on the edge between displays belongs to the right-hand one") {
    expectEqual(Placement.display(containing: CGPoint(x: 1000, y: 500), in: displays), second)
    expectEqual(Placement.display(containing: CGPoint(x: 999, y: 500), in: displays), main)
  }
  test("placement: a click that barely moves isn't a drag") {
    expect(!Placement.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 12)))
    expect(Placement.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 14, y: 10)))
  }
  test("placement: a drop whose centre is in a gap goes to the display it overlaps most") {
    // Centre (1131, 700) is above `second` (top 600) but the frame overlaps it by 100 pt.
    expectEqual(Placement.dropPoint(frame: CGRect(x: 1000, y: 500, width: 262, height: 400), displays: displays),
                CGPoint(x: 1000, y: 600))
  }
}
