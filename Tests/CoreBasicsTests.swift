import Foundation

func coreBasicsTests() {
  test("JSONValue parses nested objects and bools") {
    let v = JSONValue.parse(Data(#"{"a":{"b":[1,true,null,"x"]}}"#.utf8))
    expectEqual(v?["a"]?["b"]?.array, [.number(1), .bool(true), .null, .string("x")])
  }
  test("JSONValue rejects garbage") { expect(JSONValue.parse(Data("{nope".utf8)) == nil) }
  test("Paths honour overrides") {
    setenv("AGENT_HUDDLE_DIR", "/tmp/ahx", 1); defer { unsetenv("AGENT_HUDDLE_DIR") }
    expectEqual(Paths.socketPath, "/tmp/ahx/huddle.sock")
  }
  test("abbreviate replaces home") {
    expectEqual(Paths.abbreviate(Paths.home + "/web-app"), "~/web-app")
    expectEqual(Paths.abbreviate("/opt/x"), "/opt/x")
  }
}
