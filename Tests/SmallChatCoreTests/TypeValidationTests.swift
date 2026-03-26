import Foundation
import Testing
@testable import SmallChatCore

@Suite("TypeValidation")
struct TypeValidationTests {

    // MARK: - Helpers

    private func sig(_ params: SCParameterSlot...) -> SCMethodSignature {
        SCMethodSignature(parameters: params)
    }

    // MARK: - Type Mismatch

    @Test("Detects type mismatch: string expected, number given")
    func typeMismatchStringNumber() {
        let signature = sig(
            param("name", 0, .primitive(.string))
        )
        let result = validateArgumentTypes(signature, [42 as any Sendable])
        #expect(!result.valid)
        #expect(result.violations.count == 1)
        #expect(result.violations[0].kind == .typeMismatch)
        #expect(result.violations[0].parameterName == "name")
    }

    @Test("Detects type mismatch: number expected, string given")
    func typeMismatchNumberString() {
        let signature = sig(
            param("age", 0, .primitive(.number))
        )
        let result = validateArgumentTypes(signature, ["hello" as any Sendable])
        #expect(!result.valid)
        #expect(result.violations[0].kind == .typeMismatch)
    }

    @Test("Detects type mismatch: boolean expected, string given")
    func typeMismatchBooleanString() {
        let signature = sig(
            param("flag", 0, .primitive(.boolean))
        )
        let result = validateArgumentTypes(signature, ["true" as any Sendable])
        #expect(!result.valid)
        #expect(result.violations[0].kind == .typeMismatch)
    }

    @Test("Bool does not match number type")
    func boolDoesNotMatchNumber() {
        let signature = sig(
            param("count", 0, .primitive(.number))
        )
        let result = validateArgumentTypes(signature, [true as any Sendable])
        #expect(!result.valid)
        #expect(result.violations[0].kind == .typeMismatch)
    }

    @Test("Valid arguments pass validation")
    func validArgumentsPass() {
        let signature = sig(
            param("name", 0, .primitive(.string)),
            param("age", 1, .primitive(.number))
        )
        let result = validateArgumentTypes(signature, ["Alice" as any Sendable, 30 as any Sendable])
        #expect(result.valid)
        #expect(result.violations.isEmpty)
    }

    // MARK: - ISA Violation

    @Test("ISA violation when wrong SCObject subclass given")
    func isaViolation() {
        SCObjectRegistry.shared.register("Animal", superclass: "SCObject")
        SCObjectRegistry.shared.register("Vehicle", superclass: "SCObject")

        class Animal: SCObject { override var isa: String { "Animal" } }
        class Vehicle: SCObject { override var isa: String { "Vehicle" } }

        let signature = sig(
            param("pet", 0, .object(className: "Animal"))
        )
        let result = validateArgumentTypes(signature, [Vehicle() as any Sendable])
        #expect(!result.valid)
        #expect(result.violations.count == 1)
        #expect(result.violations[0].kind == .isaViolation)
    }

    @Test("Subclass matches parent type")
    func subclassMatchesParent() {
        SCObjectRegistry.shared.register("Pet", superclass: "SCObject")
        SCObjectRegistry.shared.register("Dog", superclass: "Pet")

        class Dog: SCObject { override var isa: String { "Dog" } }

        let signature = sig(
            param("animal", 0, .object(className: "Pet"))
        )
        let result = validateArgumentTypes(signature, [Dog() as any Sendable])
        #expect(result.valid)
    }

    // MARK: - Excess Arguments

    @Test("Detects excess arguments beyond arity")
    func excessArguments() {
        let signature = sig(
            param("name", 0, .primitive(.string))
        )
        let result = validateArgumentTypes(signature, [
            "Alice" as any Sendable,
            "extra" as any Sendable,
            42 as any Sendable,
        ])
        #expect(!result.valid)
        let excess = result.violations.filter { $0.kind == .excessArgument }
        #expect(excess.count == 2)
    }

    // MARK: - Missing Required

    @Test("Detects missing required argument")
    func missingRequired() {
        let signature = sig(
            param("name", 0, .primitive(.string)),
            param("age", 1, .primitive(.number))
        )
        let result = validateArgumentTypes(signature, ["Alice" as any Sendable])
        #expect(!result.valid)
        #expect(result.violations.count == 1)
        #expect(result.violations[0].kind == .missingRequired)
        #expect(result.violations[0].parameterName == "age")
    }

    @Test("Optional parameter does not trigger missing required")
    func optionalParamNoViolation() {
        let signature = sig(
            param("name", 0, .primitive(.string)),
            param("age", 1, .primitive(.number), required: false)
        )
        let result = validateArgumentTypes(signature, ["Alice" as any Sendable])
        #expect(result.valid)
    }

    // MARK: - Named Arguments

    @Test("Unknown named argument detected as excess")
    func unknownNamedArgument() {
        let signature = sig(
            param("name", 0, .primitive(.string))
        )
        let result = validateNamedArgumentTypes(signature, [
            "name": "Alice" as any Sendable,
            "injection": "malicious" as any Sendable,
        ])
        #expect(!result.valid)
        let excess = result.violations.filter { $0.kind == .excessArgument }
        #expect(excess.count == 1)
        #expect(excess[0].parameterName == "injection")
    }

    @Test("Named arguments validate types correctly")
    func namedArgumentTypesValidated() {
        let signature = sig(
            param("name", 0, .primitive(.string)),
            param("age", 1, .primitive(.number))
        )
        let result = validateNamedArgumentTypes(signature, [
            "name": 42 as any Sendable,
            "age": "not a number" as any Sendable,
        ])
        #expect(!result.valid)
        let mismatches = result.violations.filter { $0.kind == .typeMismatch }
        #expect(mismatches.count == 2)
    }

    @Test("Valid named arguments pass")
    func validNamedArgumentsPass() {
        let signature = sig(
            param("name", 0, .primitive(.string)),
            param("age", 1, .primitive(.number))
        )
        let result = validateNamedArgumentTypes(signature, [
            "name": "Alice" as any Sendable,
            "age": 30 as any Sendable,
        ])
        #expect(result.valid)
    }

    // MARK: - Union Types

    @Test("Union type accepts any member type")
    func unionTypeAccepts() {
        let signature = sig(
            param("value", 0, .union([.primitive(.string), .primitive(.number)]))
        )
        let r1 = validateArgumentTypes(signature, ["hello" as any Sendable])
        #expect(r1.valid)

        let r2 = validateArgumentTypes(signature, [42 as any Sendable])
        #expect(r2.valid)
    }

    @Test("Union type rejects non-member type")
    func unionTypeRejects() {
        let signature = sig(
            param("value", 0, .union([.primitive(.string), .primitive(.number)]))
        )
        let result = validateArgumentTypes(signature, [true as any Sendable])
        #expect(!result.valid)
    }

    // MARK: - Any Type

    @Test("Any type accepts everything")
    func anyTypeAccepts() {
        let signature = sig(
            param("value", 0, .any)
        )
        let r1 = validateArgumentTypes(signature, ["hello" as any Sendable])
        #expect(r1.valid)
        let r2 = validateArgumentTypes(signature, [42 as any Sendable])
        #expect(r2.valid)
        let r3 = validateArgumentTypes(signature, [true as any Sendable])
        #expect(r3.valid)
    }

    // MARK: - Zero-Arity

    @Test("Zero-arity signature validates empty args")
    func zeroArityValid() {
        let signature = SCMethodSignature(parameters: [])
        let result = validateArgumentTypes(signature, [])
        #expect(result.valid)
    }

    @Test("Zero-arity signature rejects extra args")
    func zeroArityRejectsExtra() {
        let signature = SCMethodSignature(parameters: [])
        let result = validateArgumentTypes(signature, ["extra" as any Sendable])
        #expect(!result.valid)
        #expect(result.violations[0].kind == .excessArgument)
    }
}
