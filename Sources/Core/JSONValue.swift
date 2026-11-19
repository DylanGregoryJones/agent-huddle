import Foundation

indirect enum JSONValue: Equatable {
  case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

  init(any: Any) {
    switch any {
    case let n as NSNumber:
      if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
    case let s as String: self = .string(s)
    case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
    case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
    default: self = .null
    }
  }

  static func parse(_ data: Data) -> JSONValue? {
    guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
    return JSONValue(any: obj)
  }

  subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  var string: String? { if case .string(let s) = self { return s }; return nil }
  var double: Double? { if case .number(let d) = self { return d }; return nil }
  var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
  var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}
