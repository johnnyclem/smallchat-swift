import Foundation
import Testing
import SmallChatCore

/// spec/call-digest/vectors.json (smallchat.call.v1): RFC 8785 JCS and the
/// canonical call digest, byte for byte as @smallchat/core computes them.
@Suite("Conformance: call digest (spec/call-digest)")
struct CallDigestVectorTests {
    static let spec = try! SpecFixtures.json("call-digest/vectors.json")

    @Test("the domain is smallchat.call.v1")
    func domain() {
        #expect(Self.spec["domain"]?.stringValue == callDigestDomain)
    }

    @Test("every vector reproduces its JCS form and digest", arguments: Self.spec["vectors"]!.arrayValue)
    func vector(_ v: AnyCodableValue) throws {
        let name = v["name"]?.stringValue ?? "?"
        let toolId = try #require(v["toolId"]?.stringValue)
        let arguments = try #require(v["arguments"])
        #expect(try canonicalJSON(arguments) == v["jcs"]?.stringValue, "\(name)")
        #expect(try callDigest(toolId: toolId, arguments: arguments) == v["digest"]?.stringValue, "\(name)")
    }

    @Test("every invalid input is refused", arguments: Self.spec["invalid"]!.arrayValue)
    func invalid(_ v: AnyCodableValue) throws {
        let name = v["name"]?.stringValue ?? "?"
        let toolId = try #require(v["toolId"]?.stringValue)
        if toolId.unicodeScalars.contains("\u{FFFD}") {
            // A Swift String cannot hold a lone surrogate: the refusal happens
            // where the text enters Swift, in the JSON reader.
            #expect(throws: JSONParseError.self, "\(name)") {
                try parseJSON(#"{"toolId": "p/t\ud800"}"#)
            }
            return
        }
        let arguments: AnyCodableValue
        if let nonFinite = v["nonFinite"] {
            let key = try #require(nonFinite["key"]?.stringValue)
            let value: Double
            switch nonFinite["value"]?.stringValue {
            case "NaN": value = .nan
            case "Infinity": value = .infinity
            case "-Infinity": value = -.infinity
            default: Issue.record("unknown nonFinite value in \(name)"); return
            }
            arguments = .dict([key: .double(value)])
        } else {
            arguments = try #require(v["arguments"])
        }
        #expect(throws: (any Error).self, "\(name)") {
            try callDigest(toolId: toolId, arguments: arguments)
        }
    }

    @Test("numbers use the ECMAScript shortest round-trip form")
    func numberForms() throws {
        #expect(try ecmaScriptNumberString(1e21) == "1e+21")
        #expect(try ecmaScriptNumberString(1e20) == "100000000000000000000")
        #expect(try ecmaScriptNumberString(-0.0) == "0")
        #expect(try ecmaScriptNumberString(2.0) == "2")
        #expect(try ecmaScriptNumberString(1e-7) == "1e-7")
        #expect(try ecmaScriptNumberString(0.000001) == "0.000001")
        #expect(try ecmaScriptNumberString(123e-20) == "1.23e-18")
        #expect(try ecmaScriptNumberString(-1.5) == "-1.5")
        #expect(try ecmaScriptNumberString(Double.leastNonzeroMagnitude) == "5e-324")
        #expect(try ecmaScriptNumberString(Double(Float(0.1))) == "0.10000000149011612")
        #expect(throws: (any Error).self) { try ecmaScriptNumberString(.nan) }
    }
}
