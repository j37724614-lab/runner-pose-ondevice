import Foundation

/// A JSON document with ordered keys: the result documents (long_jump_result.json,
/// review_overlay.json) are built as the Python dicts are, key by key, so the phone writes the
/// same fields, nulls and number types as the server and the frontend reads either.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public init(_ value: Double?) { self = value.map(JSONValue.double) ?? .null }
    public init(_ value: Int?) { self = value.map(JSONValue.int) ?? .null }
    public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    public init(_ value: Bool?) { self = value.map(JSONValue.bool) ?? .null }

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var intValue: Int? { if case .int(let i) = self { return i } else { return nil } }

    /// A number as Double (int or double).
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    // MARK: - Serialisation (Python json.dumps conventions)

    /// JSON text like Python's `json.dumps(value, indent=indent, ensure_ascii=False)`: insertion
    /// order, `", "` / `": "` separators, floats in shortest round-trip form with a decimal point
    /// (`2.0`, not `2`), non-finite floats as `NaN` / `Infinity`.
    public func serialized(indent: Int? = 2) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int?, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += Self.pythonFloat(d)
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += indent == nil ? ", " : "," }
                Self.newline(&out, indent, level + 1)
                item.write(into: &out, indent: indent, level: level + 1)
            }
            Self.newline(&out, indent, level)
            out += "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{"
            for (n, (key, value)) in object.enumerated() {
                if n > 0 { out += indent == nil ? ", " : "," }
                Self.newline(&out, indent, level + 1)
                Self.writeString(key, into: &out)
                out += ": "
                value.write(into: &out, indent: indent, level: level + 1)
            }
            Self.newline(&out, indent, level)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, _ indent: Int?, _ level: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: " ", count: indent * level)
    }

    static func pythonFloat(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        let text = "\(d)"  // shortest round-trip, like Python's repr
        if text.contains(".") || text.contains("e") || text.contains("n") { return text }
        return text + ".0"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// Ordered JSON object: keys keep their insertion order; assigning nil removes a key.
public struct JSONObject: Sendable, Equatable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func makeIterator() -> AnyIterator<(String, JSONValue)> {
        var iterator = keys.makeIterator()
        let storage = self.storage
        return AnyIterator {
            guard let key = iterator.next() else { return nil }
            return (key, storage[key]!)
        }
    }

    /// Order-insensitive equality (JSON objects are unordered).
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.storage == rhs.storage
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Codable (reading result documents and test fixtures)

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            let dictionary = try container.decode([String: JSONValue].self)
            var object = JSONObject()
            for key in dictionary.keys.sorted() { object[key] = dictionary[key] }
            self = .object(object)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o):
            var dictionary: [String: JSONValue] = [:]
            for (key, value) in o { dictionary[key] = value }
            try container.encode(dictionary)
        }
    }
}
