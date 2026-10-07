import Foundation

/// A JSON value. Used for tool schemas and arguments so they stay `Sendable`
/// and `Codable` without pulling in a JSON library.
public enum JSONValue: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .number(let v):   try container.encode(v)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }
}

public extension JSONValue {
    /// The value as a Foundation object, for `JSONSerialization`.
    var foundationValue: Any {
        switch self {
        case .null:          return NSNull()
        case .bool(let v):   return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v):  return v.map(\.foundationValue)
        case .object(let v): return v.mapValues(\.foundationValue)
        }
    }

    /// Builds a value from `JSONSerialization` output.
    init(foundationValue: Any) {
        switch foundationValue {
        case is NSNull:
            self = .null
        // Must precede any Bool case: NSNumber(1) bridges to Bool as true.
        case let v as NSNumber:
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
        case let v as String:
            self = .string(v)
        case let v as [Any]:
            self = .array(v.map(JSONValue.init(foundationValue:)))
        case let v as [String: Any]:
            self = .object(v.mapValues(JSONValue.init(foundationValue:)))
        default:
            self = .null
        }
    }

    /// Decodes raw JSON bytes.
    static func decode(_ data: Data) throws -> JSONValue {
        JSONValue(foundationValue: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

/// Something the model can call.
///
/// ```swift
/// struct Weather: Tool {
///     let name = "get_weather"
///     let description = "Current weather for a city."
///     let parameterSchema: JSONValue = .object([
///         "type": .string("object"),
///         "properties": .object([
///             "city": .object(["type": .string("string")])
///         ]),
///         "required": .array([.string("city")])
///     ])
///
///     func call(arguments: JSONValue) async throws -> String {
///         guard let city = arguments["city"]?.stringValue else {
///             throw ToolError.invalidArguments("city is required")
///         }
///         return "18°C and clear in \(city)"
///     }
/// }
/// ```
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }

    /// JSON Schema describing the arguments, as the provider expects them.
    var parameterSchema: JSONValue { get }

    /// Runs the tool. The returned string goes back to the model verbatim.
    func call(arguments: JSONValue) async throws -> String
}

public enum ToolError: LocalizedError, Equatable {
    case invalidArguments(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): return "Invalid tool arguments: \(detail)"
        case .executionFailed(let detail):  return "Tool execution failed: \(detail)"
        }
    }
}

/// One tool invocation requested by the model.
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Looks up tools by name and runs them.
public struct ToolRegistry: Sendable {
    private let tools: [String: any Tool]

    public init(_ tools: [any Tool]) {
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var isEmpty: Bool { tools.isEmpty }
    public var all: [any Tool] { Array(tools.values) }
    public var names: [String] { Array(tools.keys).sorted() }

    public func tool(named name: String) -> (any Tool)? { tools[name] }

    /// Runs a call, or throws ``LanguageModelError/toolNotSupported(_:)`` if
    /// the model asked for something that is not registered.
    public func run(_ call: ToolCall) async throws -> String {
        guard let tool = tools[call.name] else {
            throw LanguageModelError.toolNotSupported(call.name)
        }
        return try await tool.call(arguments: call.arguments)
    }
}
