import Foundation
import Testing
import SmallChatCore

@Suite("JSON text reader")
struct JSONTextTests {

    @Test("a repeated member name keeps the last value, as JSON.parse does")
    func exactDuplicateKeepsLast() throws {
        #expect(try parseJSON(#"{"a":1,"a":2}"#) == .dict(["a": .int(2)]))
        #expect(try parseJSON("{\"\u{e9}\":1,\"\u{e9}\":2}") == .dict(["\u{e9}": .int(2)]))
    }

    @Test("JCS-CANONICAL-EQUIV-KEYS: member names that differ in code points but are canonically equivalent are refused")
    func canonicallyEquivalentKeysRefused() throws {
        // U+00E9 and e + U+0301 are two members to JSON.parse and RFC 8785,
        // but one key to a Swift dictionary: silently dropping one would
        // canonicalize and digest something else than @smallchat/core does.
        let texts = [
            "{\"\u{e9}\":1,\"e\u{301}\":2}",
            #"{"é":1,"é":2}"#,
            "{\"x\":{\"\u{212b}\":1,\"\u{c5}\":2}}",
            "[{\"ok\":true},{\"e\u{301}\":1,\"\u{e9}\":2}]",
        ]
        for text in texts {
            #expect(throws: JSONParseError.self, "\(text)") { try parseJSON(text) }
        }
        // Either spelling alone is fine, and canonicalizes to its own bytes.
        let composed = try parseJSON("{\"\u{e9}\":1}")
        let decomposed = try parseJSON("{\"e\u{301}\":1}")
        #expect(try canonicalJSON(composed) == "{\"\u{e9}\":1}")
        #expect(try canonicalJSON(decomposed).unicodeScalars.elementsEqual("{\"e\u{301}\":1}".unicodeScalars))
    }
}
