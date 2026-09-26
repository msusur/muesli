import Foundation

/// A minimal JSON value that keeps object keys in insertion order.
///
/// `JSONSerialization` and `JSONEncoder` don't preserve key order, and property
/// order in a JSON Schema matters: models fill fields in the order they're
/// declared, so `summary` should come before the fields derived from it. Also
/// keeps request bodies byte-stable, which is friendly to prompt caching.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([Member])

    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public static func object(_ members: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(members.map { Member($0.key, $0.value) })
    }

    public func serialized() -> String {
        switch self {
        case .string(let s): Self.escape(s)
        case .int(let i): String(i)
        case .bool(let b): b ? "true" : "false"
        case .array(let items): "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let members):
            "{" + members.map { Self.escape($0.key) + ":" + $0.value.serialized() }.joined(separator: ",") + "}"
        }
    }

    public func data() -> Data { Data(serialized().utf8) }

    static func escape(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
