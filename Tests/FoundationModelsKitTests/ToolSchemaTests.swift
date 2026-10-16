import Foundation
import Testing
@testable import FoundationModelsKit

#if canImport(FoundationModels)
import FoundationModels

/// Converting a JSON Schema to Apple's runtime schema type is what lets one
/// `ModelTool` run both on-device and against a cloud provider. A silent
/// failure here breaks tools on-device only, which is easy to miss.
///
/// Swift Testing does not allow `@available` on `@Test`, so each case checks
/// at runtime and no-ops on older systems.
@Suite("Dynamic tool schema")
struct DynamicSchemaTests {

    private func build(_ json: JSONValue) throws {
        guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        _ = try DynamicSchemaBuilder.schema(named: "t", from: json)
    }

    @Test func convertsFlatObject() throws {
        try build(.object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")]),
        ]))
    }

    @Test func convertsEveryScalarType() throws {
        try build(.object([
            "type": .string("object"),
            "properties": .object([
                "s": .object(["type": .string("string")]),
                "i": .object(["type": .string("integer")]),
                "n": .object(["type": .string("number")]),
                "b": .object(["type": .string("boolean")]),
            ]),
        ]))
    }

    @Test func convertsArraysAndNestedObjects() throws {
        try build(.object([
            "type": .string("object"),
            "properties": .object([
                "tags": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
                "address": .object([
                    "type": .string("object"),
                    "properties": .object(["zip": .object(["type": .string("string")])]),
                ]),
            ]),
        ]))
    }

    @Test func convertsEnums() throws {
        try build(.object([
            "type": .string("object"),
            "properties": .object([
                "unit": .object(["enum": .array([.string("c"), .string("f")])]),
            ]),
        ]))
    }

    @Test func toleratesSchemaWithNoProperties() throws {
        try build(.object(["type": .string("object")]))
    }

    @Test func toleratesArrayWithoutItems() throws {
        // Providers sometimes omit `items`; defaulting beats throwing.
        try build(.object([
            "type": .string("object"),
            "properties": .object(["xs": .object(["type": .string("array")])]),
        ]))
    }

    @Test func toleratesUnknownType() throws {
        try build(.object([
            "type": .string("object"),
            "properties": .object(["x": .object(["type": .string("nonsense")])]),
        ]))
    }

    @Test func propertyOrderIsStable() throws {
        guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // Dictionary iteration is unordered; the builder sorts so the schema
        // sent to the model does not change between runs.
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "z": .object(["type": .string("string")]),
                "a": .object(["type": .string("string")]),
                "m": .object(["type": .string("string")]),
            ]),
        ])
        let first = String(describing: try DynamicSchemaBuilder.schema(named: "t", from: schema))
        for _ in 0..<5 {
            let again = String(describing: try DynamicSchemaBuilder.schema(named: "t", from: schema))
            #expect(again == first)
        }
    }

    @Test func adapterCarriesNameAndDescription() throws {
        guard #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        struct Probe: ModelTool {
            let name = "probe"
            let description = "A probe."
            let parameterSchema = JSONValue.object(["type": .string("object")])
            func call(arguments: JSONValue) async throws -> String { "" }
        }
        let adapter = try OnDeviceToolAdapter(Probe())
        #expect(adapter.name == "probe")
        #expect(adapter.description == "A probe.")
    }
}
#endif
