import Foundation

var testCount = 0
var failureCount = 0

func test(_ name: String, _ body: () throws -> Void) {
  testCount += 1
  let before = failureCount
  do { try body() } catch {
    failureCount += 1
    print("FAIL \(name): threw \(error)")
  }
  if failureCount == before { print("ok   \(name)") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
  if a != b {
    failureCount += 1
    print("FAIL \((file as NSString).lastPathComponent):\(line) \(msg) — \(a) != \(b)")
  }
}

func expect(_ cond: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
  if !cond {
    failureCount += 1
    print("FAIL \((file as NSString).lastPathComponent):\(line) \(msg)")
  }
}

/// Every directory `makeTempDir` made, for `removeTempDirs()` at the end of the run.
private var tempDirs: [String] = []

func makeTempDir(_ prefix: String = "ah") -> String {
  for base in ["/tmp", NSTemporaryDirectory()] {
    var template = Array((base as NSString).appendingPathComponent("\(prefix).XXXXXX").utf8CString)
    if mkdtemp(&template) != nil {
      let dir = String(cString: template)
      tempDirs.append(dir)
      return dir
    }
  }
  fatalError("makeTempDir failed")
}

func removeTempDirs() {
  for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
  tempDirs = []
}

func fixture(_ name: String) -> Data {
  let root = (((#filePath as NSString).deletingLastPathComponent))
  let path = (root as NSString).appendingPathComponent("fixtures/\(name)")
  return FileManager.default.contents(atPath: path) ?? { fatalError("missing fixture: \(name)") }()
}
