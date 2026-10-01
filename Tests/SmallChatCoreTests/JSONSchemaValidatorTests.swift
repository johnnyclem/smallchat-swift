import Foundation
import Testing
@testable import SmallChatCore

@Suite("JSONSchemaValidator")
struct JSONSchemaValidatorTests {

    private func errors(_ schema: String, _ instance: String) throws -> [ValidationError] {
        try JSONSchemaValidator(json: schema).validate(parseJSON(instance))
    }

    @Test("types, required and a closed schema")
    func objects() throws {
        let schema = #"{"type":"object","properties":{"title":{"type":"string"},"count":{"type":"integer"}},"required":["title"],"additionalProperties":false}"#
        #expect(try errors(schema, #"{"title":"x","count":2}"#).isEmpty)
        #expect(try errors(schema, #"{"title":"x","count":2.0}"#).isEmpty)

        let missing = try errors(schema, #"{"count":1}"#)
        #expect(missing.map(\.path) == ["/title"])
        #expect(missing.first?.message == #"missing required argument "title""#)

        let wrongType = try errors(schema, #"{"title":5}"#)
        #expect(wrongType.first?.message == #"argument "title" must be string, got integer 5"#)

        let unknown = try errors(schema, #"{"title":"x","extra":true}"#)
        #expect(unknown.first?.path == "/extra")
        #expect(unknown.first?.message.contains("does not allow it") == true)

        #expect(try errors(schema, #"{"title":"x","count":1.5}"#).count == 1)
    }

    @Test("an open schema accepts unknown arguments")
    func openSchema() throws {
        #expect(try errors(#"{"type":"object","properties":{"a":{"type":"string"}}}"#, #"{"a":"x","b":1}"#).isEmpty)
    }

    @Test("enum, const, numbers, strings, arrays")
    func assertions() throws {
        #expect(try errors(#"{"enum":["a","b"]}"#, #""c""#).count == 1)
        #expect(try errors(#"{"enum":[1,2]}"#, "1.0").isEmpty)
        #expect(try errors(#"{"const":{"x":[1]}}"#, #"{"x":[1]}"#).isEmpty)
        #expect(try errors(#"{"minimum":1,"exclusiveMaximum":10,"multipleOf":0.5}"#, "10").count == 1)
        #expect(try errors(#"{"minimum":1,"exclusiveMaximum":10,"multipleOf":0.5}"#, "2.5").isEmpty)
        #expect(try errors(#"{"minLength":2,"maxLength":3}"#, #""é😀""#).isEmpty)
        #expect(try errors(#"{"pattern":"^[a-z]+$"}"#, #""abc1""#).count == 1)
        #expect(try errors(#"{"type":"array","items":{"type":"integer"},"minItems":1,"maxItems":2,"uniqueItems":true}"#, "[1,1]").count == 1)
        #expect(try errors(#"{"type":"array","items":{"type":"integer"}}"#, #"[1,"x"]"#).map(\.path) == ["/1"])
        #expect(try errors(#"{"prefixItems":[{"type":"string"}],"items":{"type":"integer"}}"#, #"["a",1,2]"#).isEmpty)
        #expect(try errors(#"{"contains":{"const":3}}"#, "[1,2]").count == 1)
    }

    @Test("combinators, conditionals and local references")
    func composition() throws {
        #expect(try errors(#"{"anyOf":[{"type":"string"},{"type":"null"}]}"#, "null").isEmpty)
        #expect(try errors(#"{"oneOf":[{"type":"integer"},{"type":"number"}]}"#, "1").count == 1)
        #expect(try errors(#"{"not":{"type":"string"}}"#, #""x""#).count == 1)
        let conditional = #"{"if":{"properties":{"kind":{"const":"hash"}}},"then":{"properties":{"dims":{"type":"null"}}}}"#
        #expect(try errors(conditional, #"{"kind":"hash","dims":3}"#).count == 1)
        #expect(try errors(conditional, #"{"kind":"onnx","dims":3}"#).isEmpty)
        let refs = ##"{"$defs":{"id":{"type":"string","minLength":1}},"properties":{"a":{"$ref":"#/$defs/id"}}}"##
        #expect(try errors(refs, #"{"a":""}"#).count == 1)
        let recursive = ##"{"type":"object","properties":{"child":{"$ref":"#"}},"additionalProperties":false}"##
        #expect(try errors(recursive, #"{"child":{"child":{"x":1}}}"#).map(\.path) == ["/child/child/x"])
    }

    @Test("draft-07: tuple items, additionalItems, dependencies, $ref ignores siblings")
    func draft07() throws {
        let tuple = ##"{"$schema":"http://json-schema.org/draft-07/schema#","items":[{"type":"string"}],"additionalItems":false}"##
        #expect(try errors(tuple, #"["a",1]"#).count == 1)
        let deps = ##"{"$schema":"http://json-schema.org/draft-07/schema#","dependencies":{"a":["b"]}}"##
        #expect(try errors(deps, #"{"a":1}"#).count == 1)
        let draft4 = try JSONSchemaValidator(json: ##"{"$schema":"http://json-schema.org/draft-04/schema#","type":"string"}"##)
        #expect(draft4.dialect == .draft07)
    }

    @Test("unusable schemas fail closed")
    func failClosed() {
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: #"{"$schema":"https://example.com/my-dialect"}"#) }
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: #"{"unevaluatedProperties":false}"#) }
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: #"{"$ref":"https://example.com/other.json"}"#) }
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: #"{"pattern":"("}"#) }
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: #"{"type":"strng"}"#) }
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: #"{"exclusiveMinimum":true}"#) }
        #expect(throws: InputSchemaError.self) { try JSONSchemaValidator(json: "true") }
    }

    @Test("format and unknown keywords are annotations")
    func annotationsIgnored() throws {
        #expect(try errors(#"{"type":"string","format":"email","x-vendor":1}"#, #""not an email""#).isEmpty)
    }

    @Test("the artifact 1.0 schema compiles")
    func artifactSchemaCompiles() throws {
        let validator = try JSONSchemaValidator(json: artifactV1SchemaJSON)
        #expect(validator.dialect == .draft2020_12)
    }
}
