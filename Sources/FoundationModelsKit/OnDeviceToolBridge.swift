import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Builds Apple's runtime schema type from a JSON Schema fragment.
///
/// `FoundationModels.Tool` normally derives its schema at compile time from a
/// `@Generable` type. ``ModelTool`` carries a JSON Schema instead, so the two
/// meet at `DynamicGenerationSchema`.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
enum DynamicSchemaBuilder {

    static func schema(named name: String, from json: JSONValue) throws -> GenerationSchema {
        try GenerationSchema(root: node(named: name, from: json), dependencies: [])
    }

    static func node(named name: String, from json: JSONValue) -> DynamicGenerationSchema {
        let description = json["description"]?.stringValue

        if case .array(let cases) = json["enum"] {
            let labels = cases.compactMap(\.stringValue)
            if !labels.isEmpty {
                return DynamicGenerationSchema(name: name, description: description, anyOf: labels)
            }
        }

        switch json["type"]?.stringValue {
        case "object":
            var properties: [DynamicGenerationSchema.Property] = []
            var required: Set<String> = []
            if case .array(let names) = json["required"] {
                required = Set(names.compactMap(\.stringValue))
            }
            if case .object(let fields) = json["properties"] ?? .null {
                // Sorted so the schema is stable across runs.
                for key in fields.keys.sorted() {
                    guard let value = fields[key] else { continue }
                    properties.append(
                        DynamicGenerationSchema.Property(
                            name: key,
                            description: value["description"]?.stringValue,
                            schema: node(named: key, from: value),
                            isOptional: !required.contains(key)
                        )
                    )
                }
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)

        case "array":
            let items = json["items"] ?? .object(["type": .string("string")])
            return DynamicGenerationSchema(
                arrayOf: node(named: "\(name)Item", from: items),
                minimumElements: nil,
                maximumElements: nil
            )

        case "integer":
            return DynamicGenerationSchema(type: Int.self, guides: [])
        case "number":
            return DynamicGenerationSchema(type: Double.self, guides: [])
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self, guides: [])
        default:
            return DynamicGenerationSchema(type: String.self, guides: [])
        }
    }
}

/// Presents a ``ModelTool`` to Apple's framework.
///
/// `Arguments` is `GeneratedContent` rather than a `@Generable` type, which is
/// what allows the schema to be built at runtime.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct OnDeviceToolAdapter: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let underlying: any ModelTool

    init(_ tool: any ModelTool) throws {
        self.name = tool.name
        self.description = tool.description
        self.parameters = try DynamicSchemaBuilder.schema(named: tool.name, from: tool.parameterSchema)
        self.underlying = tool
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let decoded = (try? JSONValue.decode(Data(arguments.jsonString.utf8))) ?? .object([:])
        return try await underlying.call(arguments: decoded)
    }
}
#endif
