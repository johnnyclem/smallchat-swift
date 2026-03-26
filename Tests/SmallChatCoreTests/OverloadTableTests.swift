import Testing
import Foundation
@testable import SmallChatCore

/// Minimal mock IMP for testing overload resolution.
final class MockIMP: ToolIMP, @unchecked Sendable {
    let providerId: String
    let toolName: String
    let transportType: TransportType = .local
    let schema: ToolSchema? = nil

    init(providerId: String = "test", toolName: String = "mock") {
        self.providerId = providerId
        self.toolName = toolName
    }

    func loadSchema() async throws -> ToolSchema {
        ToolSchema(name: toolName, description: "", inputSchema: JSONSchemaType(type: "object"))
    }

    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        ToolResult(content: "ok")
    }
}

@Suite("OverloadTable")
struct OverloadTableTests {

    // MARK: - Resolution priority

    @Test("Exact type match wins over any-typed overload")
    func exactWinsOverAny() throws {
        let table = OverloadTable(selectorCanonical: "search")

        // Overload 1: (string)
        let sig1 = createSignature([param("query", 0, SCType.string())])
        try table.register(sig1, imp: MockIMP(toolName: "searchByString"))

        // Overload 2: (any)
        let sig2 = createSignature([param("query", 0, SCType.any())])
        try table.register(sig2, imp: MockIMP(toolName: "searchByAny"))

        let result = try table.resolve(["hello" as any Sendable])
        #expect(result?.entry.imp.toolName == "searchByString")
        #expect(result?.matchQuality == .exact)
    }

    @Test("Higher arity preferred as tiebreaker")
    func higherArityPreferred() throws {
        let table = OverloadTable(selectorCanonical: "format")

        // Overload 1: (string)
        let sig1 = createSignature([param("text", 0, SCType.string())])
        try table.register(sig1, imp: MockIMP(toolName: "formatSimple"))

        // Overload 2: (string, number)
        let sig2 = createSignature([
            param("text", 0, SCType.string()),
            param("width", 1, SCType.number()),
        ])
        try table.register(sig2, imp: MockIMP(toolName: "formatWithWidth"))

        let result = try table.resolve(["hello" as any Sendable, 80 as any Sendable])
        #expect(result?.entry.imp.toolName == "formatWithWidth")
    }

    // MARK: - Ambiguity detection

    @Test("Ambiguous overloads with same arity and score throw error")
    func ambiguityDetected() throws {
        let table = OverloadTable(selectorCanonical: "process")

        let sig1 = createSignature([param("input", 0, SCType.any())])
        try table.register(sig1, imp: MockIMP(toolName: "processA"))

        let sig2 = createSignature([param("data", 0, SCType.any())])
        try table.register(sig2, imp: MockIMP(toolName: "processB"))

        #expect(throws: OverloadAmbiguityError.self) {
            _ = try table.resolve(["test" as any Sendable])
        }
    }

    @Test("Developer-defined overload wins over semantic overload in ambiguity")
    func devDefinedWinsOverSemantic() throws {
        let table = OverloadTable(selectorCanonical: "run")

        let sig1 = createSignature([param("cmd", 0, SCType.string())])
        try table.register(sig1, imp: MockIMP(toolName: "devRun"), isSemanticOverload: false)

        let sig2 = createSignature([param("command", 0, SCType.any())])
        try table.register(sig2, imp: MockIMP(toolName: "semanticRun"), isSemanticOverload: true)

        let result = try table.resolve(["ls" as any Sendable])
        #expect(result?.entry.imp.toolName == "devRun")
    }

    // MARK: - Duplicate registration

    @Test("Duplicate signature key throws DuplicateOverloadError")
    func duplicateRegistrationThrows() throws {
        let table = OverloadTable(selectorCanonical: "test")

        let sig = createSignature([param("x", 0, SCType.string())])
        try table.register(sig, imp: MockIMP(toolName: "first"))

        #expect(throws: DuplicateOverloadError.self) {
            try table.register(sig, imp: MockIMP(toolName: "second"))
        }
    }

    // MARK: - Validation (hardened path)

    @Test("validateAndResolve rejects type mismatch")
    func validateAndResolveRejects() throws {
        let table = OverloadTable(selectorCanonical: "send")

        let sig = createSignature([param("message", 0, SCType.string())])
        try table.register(sig, imp: MockIMP(toolName: "send"))

        #expect(throws: SignatureValidationError.self) {
            _ = try table.validateAndResolve([42 as any Sendable])
        }
    }

    @Test("validateAndResolve passes for correct types")
    func validateAndResolveAccepts() throws {
        let table = OverloadTable(selectorCanonical: "send")

        let sig = createSignature([param("message", 0, SCType.string())])
        try table.register(sig, imp: MockIMP(toolName: "send"))

        let result = try table.validateAndResolve(["hello" as any Sendable])
        #expect(result != nil)
        #expect(result?.matchQuality == .exact)
    }

    // MARK: - Named argument resolution

    @Test("resolveNamed maps named args to positional")
    func resolveNamedMaps() throws {
        let table = OverloadTable(selectorCanonical: "greet")

        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("age", 1, SCType.number()),
        ])
        try table.register(sig, imp: MockIMP(toolName: "greet"))

        let result = try table.resolveNamed(["name": "Alice" as any Sendable, "age": 30 as any Sendable])
        #expect(result != nil)
        #expect(result?.entry.imp.toolName == "greet")
    }

    @Test("validateAndResolveNamed rejects unknown argument names")
    func validateAndResolveNamedRejectsUnknown() throws {
        let table = OverloadTable(selectorCanonical: "greet")

        let sig = createSignature([param("name", 0, SCType.string())])
        try table.register(sig, imp: MockIMP(toolName: "greet"))

        #expect(throws: SignatureValidationError.self) {
            _ = try table.validateAndResolveNamed([
                "name": "Alice" as any Sendable,
                "injection": "payload" as any Sendable,
            ])
        }
    }

    // MARK: - Inspection

    @Test("allOverloads and size report correctly")
    func inspection() throws {
        let table = OverloadTable(selectorCanonical: "test")
        #expect(table.size == 0)

        let sig = createSignature([param("x", 0, SCType.string())])
        try table.register(sig, imp: MockIMP())

        #expect(table.size == 1)
        #expect(table.allOverloads().count == 1)
        #expect(table.hasSignature("string"))
        #expect(!table.hasSignature("number"))
    }

    @Test("Returns nil when no overload matches")
    func noMatchReturnsNil() throws {
        let table = OverloadTable(selectorCanonical: "test")

        let sig = createSignature([param("x", 0, SCType.number())])
        try table.register(sig, imp: MockIMP())

        let result = try table.resolve(["not a number" as any Sendable])
        #expect(result == nil)
    }
}
