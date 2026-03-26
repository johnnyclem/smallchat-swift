import Testing
import Foundation
@testable import SmallChatCore

@Suite("TypeValidation")
struct TypeValidationTests {

    // MARK: - Type mismatch

    @Test("Detects string where number expected")
    func typeMismatchStringForNumber() {
        let sig = createSignature([param("count", 0, SCType.number())])
        let result = validateArgumentTypes(sig, ["not a number" as any Sendable])

        #expect(!result.valid)
        #expect(result.violations.count == 1)
        #expect(result.violations[0].kind == .typeMismatch)
        #expect(result.violations[0].parameterName == "count")
        #expect(result.violations[0].expected == "number")
        #expect(result.violations[0].received == "string")
    }

    @Test("Detects number where string expected")
    func typeMismatchNumberForString() {
        let sig = createSignature([param("name", 0, SCType.string())])
        let result = validateArgumentTypes(sig, [42 as any Sendable])

        #expect(!result.valid)
        #expect(result.violations[0].kind == .typeMismatch)
    }

    @Test("Detects boolean where number expected")
    func typeMismatchBoolForNumber() {
        let sig = createSignature([param("count", 0, SCType.number())])
        let result = validateArgumentTypes(sig, [true as any Sendable])

        #expect(!result.valid)
        #expect(result.violations[0].kind == .typeMismatch)
    }

    @Test("Accepts correct primitive types")
    func acceptsCorrectPrimitives() {
        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("age", 1, SCType.number()),
            param("active", 2, SCType.boolean()),
        ])
        let result = validateArgumentTypes(sig, [
            "Alice" as any Sendable,
            30 as any Sendable,
            true as any Sendable,
        ])

        #expect(result.valid)
        #expect(result.violations.isEmpty)
    }

    // MARK: - ISA violation

    @Test("Detects SCObject class hierarchy violation")
    func isaViolation() {
        SCObjectRegistry.shared.register("Animal", superclass: "SCObject")
        SCObjectRegistry.shared.register("Dog", superclass: "Animal")
        SCObjectRegistry.shared.register("Car", superclass: "SCObject")

        let sig = createSignature([param("pet", 0, SCType.object("Animal"))])

        // Car is not an Animal
        let car = CarObject()
        let result = validateArgumentTypes(sig, [car as any Sendable])

        #expect(!result.valid)
        #expect(result.violations.count == 1)
        #expect(result.violations[0].kind == .isaViolation)
    }

    @Test("Accepts SCObject subclass for parent type")
    func acceptsSubclass() {
        SCObjectRegistry.shared.register("Animal", superclass: "SCObject")
        SCObjectRegistry.shared.register("Dog", superclass: "Animal")

        let sig = createSignature([param("pet", 0, SCType.object("Animal"))])

        let dog = DogObject()
        let result = validateArgumentTypes(sig, [dog as any Sendable])

        #expect(result.valid)
    }

    // MARK: - Excess arguments

    @Test("Detects excess positional arguments")
    func excessArguments() {
        let sig = createSignature([param("name", 0, SCType.string())])
        let result = validateArgumentTypes(sig, [
            "Alice" as any Sendable,
            "extra" as any Sendable,
            42 as any Sendable,
        ])

        #expect(!result.valid)
        let excessViolations = result.violations.filter { $0.kind == .excessArgument }
        #expect(excessViolations.count == 2)
    }

    // MARK: - Missing required

    @Test("Detects missing required arguments")
    func missingRequired() {
        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("age", 1, SCType.number()),
        ])
        let result = validateArgumentTypes(sig, ["Alice" as any Sendable])

        #expect(!result.valid)
        let missing = result.violations.filter { $0.kind == .missingRequired }
        #expect(missing.count == 1)
        #expect(missing[0].parameterName == "age")
    }

    @Test("Optional parameters do not cause missing required violation")
    func optionalNotRequired() {
        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("title", 1, SCType.string(), required: false),
        ])
        let result = validateArgumentTypes(sig, ["Alice" as any Sendable])

        #expect(result.valid)
    }

    @Test("Parameters with defaults do not cause missing required violation")
    func defaultsNotRequired() {
        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("greeting", 1, SCType.string(), required: true, defaultValue: "Hello"),
        ])
        let result = validateArgumentTypes(sig, ["Alice" as any Sendable])

        #expect(result.valid)
    }

    // MARK: - Named argument validation

    @Test("Named args detects unknown argument names")
    func namedArgsUnknownName() {
        let sig = createSignature([param("name", 0, SCType.string())])

        let result = validateNamedArgumentTypes(sig, [
            "name": "Alice" as any Sendable,
            "injected": "payload" as any Sendable,
        ])

        #expect(!result.valid)
        let excess = result.violations.filter { $0.kind == .excessArgument }
        #expect(excess.count == 1)
        #expect(excess[0].parameterName == "injected")
    }

    @Test("Named args validates types correctly")
    func namedArgsTypeValidation() {
        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("age", 1, SCType.number()),
        ])

        let result = validateNamedArgumentTypes(sig, [
            "name": "Alice" as any Sendable,
            "age": "not a number" as any Sendable,
        ])

        #expect(!result.valid)
        let mismatch = result.violations.filter { $0.kind == .typeMismatch }
        #expect(mismatch.count == 1)
    }

    // MARK: - Union types

    @Test("Union type accepts any member type")
    func unionTypeAccepts() {
        let sig = createSignature([
            param("value", 0, SCType.union(SCType.string(), SCType.number())),
        ])

        let strResult = validateArgumentTypes(sig, ["hello" as any Sendable])
        #expect(strResult.valid)

        let numResult = validateArgumentTypes(sig, [42 as any Sendable])
        #expect(numResult.valid)
    }

    @Test("Union type rejects non-member type")
    func unionTypeRejects() {
        let sig = createSignature([
            param("value", 0, SCType.union(SCType.string(), SCType.number())),
        ])

        let result = validateArgumentTypes(sig, [true as any Sendable])
        #expect(!result.valid)
    }

    // MARK: - Any type

    @Test("Any type accepts all values")
    func anyTypeAcceptsAll() {
        let sig = createSignature([param("data", 0, SCType.any())])

        #expect(validateArgumentTypes(sig, ["string" as any Sendable]).valid)
        #expect(validateArgumentTypes(sig, [42 as any Sendable]).valid)
        #expect(validateArgumentTypes(sig, [true as any Sendable]).valid)
    }

    // MARK: - Empty signature

    @Test("Void signature with no args is valid")
    func voidSignatureValid() {
        let sig = createSignature([])
        let result = validateArgumentTypes(sig, [])
        #expect(result.valid)
    }

    @Test("Void signature with excess args is invalid")
    func voidSignatureExcess() {
        let sig = createSignature([])
        let result = validateArgumentTypes(sig, ["extra" as any Sendable])
        #expect(!result.valid)
    }

    // MARK: - Multiple violations

    @Test("Reports all violations in a single pass")
    func multipleViolations() {
        let sig = createSignature([
            param("name", 0, SCType.string()),
            param("age", 1, SCType.number()),
            param("active", 2, SCType.boolean()),
        ])

        let result = validateArgumentTypes(sig, [
            42 as any Sendable,           // wrong: number instead of string
            "thirty" as any Sendable,     // wrong: string instead of number
            "yes" as any Sendable,        // wrong: string instead of boolean
        ])

        #expect(!result.valid)
        #expect(result.violations.count == 3)
    }
}

// MARK: - Test SCObject subclasses

private final class DogObject: SCObject, @unchecked Sendable {
    override var isa: String { "Dog" }
}

private final class CarObject: SCObject, @unchecked Sendable {
    override var isa: String { "Car" }
}
