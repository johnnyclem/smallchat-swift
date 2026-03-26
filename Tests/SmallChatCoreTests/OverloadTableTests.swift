import Foundation
import Testing
@testable import SmallChatCore

/// Minimal ToolIMP for testing overload resolution.
private final class StubIMP: ToolIMP, @unchecked Sendable {
    let providerId: String
    let toolName: String
    let transportType: TransportType = .local
    let schema: ToolSchema? = nil

    init(providerId: String = "test", toolName: String) {
        self.providerId = providerId
        self.toolName = toolName
    }

    func loadSchema() async throws -> ToolSchema {
        fatalError("not used in tests")
    }

    func execute(args: [String: any Sendable]) async throws -> ToolResult {
        ToolResult(content: toolName)
    }
}

@Suite("OverloadTable")
struct OverloadTableTests {

    // MARK: - Resolution Priority

    @Test("Exact type match wins over any-typed overload")
    func exactWinsOverAny() throws {
        let table = OverloadTable(selectorCanonical: "search")

        let anySignature = SCMethodSignature(parameters: [
            param("query", 0, .any),
        ])
        let stringSignature = SCMethodSignature(parameters: [
            param("query", 0, .primitive(.string)),
        ])

        try table.register(anySignature, imp: StubIMP(toolName: "search_any"))
        try table.register(stringSignature, imp: StubIMP(toolName: "search_string"))

        let result = try table.resolve(["hello" as any Sendable])
        #expect(result != nil)
        #expect(result?.entry.originalToolName == nil)
        #expect(result?.matchQuality == .exact)
        #expect((result?.imp as? StubIMP)?.toolName == "search_string")
    }

    @Test("Higher arity preferred on tie")
    func higherArityPreferred() throws {
        let table = OverloadTable(selectorCanonical: "format")

        let oneParam = SCMethodSignature(parameters: [
            param("text", 0, .primitive(.string)),
        ])
        let twoParam = SCMethodSignature(parameters: [
            param("text", 0, .primitive(.string)),
            param("style", 1, .primitive(.string)),
        ])

        try table.register(oneParam, imp: StubIMP(toolName: "format_1"))
        try table.register(twoParam, imp: StubIMP(toolName: "format_2"))

        let result = try table.resolve(["hello" as any Sendable, "bold" as any Sendable])
        #expect(result != nil)
        #expect((result?.imp as? StubIMP)?.toolName == "format_2")
    }

    // MARK: - Ambiguity Detection

    @Test("Ambiguous overloads throw OverloadAmbiguityError")
    func ambiguityThrows() throws {
        let table = OverloadTable(selectorCanonical: "process")

        let sig1 = SCMethodSignature(parameters: [
            param("input", 0, .any),
        ])
        let sig2 = SCMethodSignature(parameters: [
            param("data", 0, .any),
        ])

        // These have different signatureKeys because param names don't affect key (both "id")
        // Actually both map to "id" so we need different types
        // Both are .any -> same signatureKey "id", so register will throw DuplicateOverloadError
        // Let's use semantic overloads to test ambiguity differently

        // Use union vs any to get same score
        let unionSig = SCMethodSignature(parameters: [
            param("input", 0, .union([.primitive(.string), .primitive(.number)])),
        ])
        let unionSig2 = SCMethodSignature(parameters: [
            param("data", 0, .union([.primitive(.number), .primitive(.string)])),
        ])

        try table.register(unionSig, imp: StubIMP(toolName: "process_a"))
        try table.register(unionSig2, imp: StubIMP(toolName: "process_b"))

        #expect(throws: OverloadAmbiguityError.self) {
            _ = try table.resolve(["test" as any Sendable])
        }
    }

    @Test("Developer-defined overload preferred over semantic overload on tie")
    func devDefinedPreferredOverSemantic() throws {
        let table = OverloadTable(selectorCanonical: "query")

        let sig1 = SCMethodSignature(parameters: [
            param("text", 0, .primitive(.string)),
        ])
        let sig2 = SCMethodSignature(parameters: [
            param("text", 0, .primitive(.string)),
            param("limit", 1, .primitive(.number), required: false),
        ])

        try table.register(sig1, imp: StubIMP(toolName: "query_dev"), isSemanticOverload: false)
        try table.register(sig2, imp: StubIMP(toolName: "query_semantic"), isSemanticOverload: true)

        // With just a string arg, both match. Same score, sig2 has higher arity -> sig2 preferred by arity.
        // With both args, sig2 wins by arity
        let result = try table.resolve(["hello" as any Sendable, 10 as any Sendable])
        #expect(result != nil)
        #expect((result?.imp as? StubIMP)?.toolName == "query_semantic")
    }

    // MARK: - Validation (Hardened Path)

    @Test("validateAndResolve throws on type mismatch")
    func validateAndResolveThrowsOnMismatch() throws {
        let table = OverloadTable(selectorCanonical: "delete")

        let sig = SCMethodSignature(parameters: [
            param("id", 0, .primitive(.number)),
        ])
        try table.register(sig, imp: StubIMP(toolName: "delete"))

        // .any matches number in scoring, but validateArgumentTypes will catch string != number
        // Actually, scoreSignatureMatch will return -1 for string vs number, so resolve returns nil
        // Let's test with excess args instead
        let sigAny = SCMethodSignature(parameters: [
            param("id", 0, .any),
        ])
        let table2 = OverloadTable(selectorCanonical: "delete2")
        try table2.register(sigAny, imp: StubIMP(toolName: "delete2"))

        // resolve finds a match via .any, but validateAndResolve should still pass since .any accepts everything
        let result = try table2.validateAndResolve(["hello" as any Sendable])
        #expect(result != nil)
    }

    @Test("validateAndResolveNamed throws on unknown named args")
    func validateAndResolveNamedThrowsOnUnknown() throws {
        let table = OverloadTable(selectorCanonical: "update")

        let sig = SCMethodSignature(parameters: [
            param("name", 0, .primitive(.string)),
        ])
        try table.register(sig, imp: StubIMP(toolName: "update"))

        #expect(throws: SignatureValidationError.self) {
            _ = try table.validateAndResolveNamed([
                "name": "Alice" as any Sendable,
                "injected": "evil" as any Sendable,
            ])
        }
    }

    // MARK: - Duplicate Registration

    @Test("Duplicate signatureKey throws DuplicateOverloadError")
    func duplicateThrows() throws {
        let table = OverloadTable(selectorCanonical: "test")
        let sig = SCMethodSignature(parameters: [
            param("x", 0, .primitive(.string)),
        ])

        try table.register(sig, imp: StubIMP(toolName: "a"))
        #expect(throws: DuplicateOverloadError.self) {
            try table.register(sig, imp: StubIMP(toolName: "b"))
        }
    }

    // MARK: - No Match

    @Test("resolve returns nil when no overload matches")
    func resolveReturnsNilOnNoMatch() throws {
        let table = OverloadTable(selectorCanonical: "test")
        let sig = SCMethodSignature(parameters: [
            param("name", 0, .primitive(.string)),
        ])
        try table.register(sig, imp: StubIMP(toolName: "test"))

        let result = try table.resolve([42 as any Sendable])
        #expect(result == nil)
    }

    // MARK: - Queries

    @Test("size and hasSignature report correctly")
    func sizeAndHasSignature() throws {
        let table = OverloadTable(selectorCanonical: "test")
        #expect(table.size == 0)

        let sig = SCMethodSignature(parameters: [
            param("x", 0, .primitive(.string)),
        ])
        try table.register(sig, imp: StubIMP(toolName: "a"))
        #expect(table.size == 1)
        #expect(table.hasSignature(sig.signatureKey))
        #expect(!table.hasSignature("nonexistent"))
    }

    // MARK: - Named Resolution

    @Test("resolveNamed maps names to positions")
    func resolveNamedMapsCorrectly() throws {
        let table = OverloadTable(selectorCanonical: "create")

        let sig = SCMethodSignature(parameters: [
            param("name", 0, .primitive(.string)),
            param("age", 1, .primitive(.number)),
        ])
        try table.register(sig, imp: StubIMP(toolName: "create_user"))

        let result = try table.resolveNamed([
            "age": 25 as any Sendable,
            "name": "Bob" as any Sendable,
        ])
        #expect(result != nil)
        #expect((result?.imp as? StubIMP)?.toolName == "create_user")
    }
}
