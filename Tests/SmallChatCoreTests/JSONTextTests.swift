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

    @Test("SW-QUORUM-3: a string keeps a leading U+FEFF, at its start and after an escape, as JSON.parse does")
    func leadingByteOrderMarkKept() throws {
        func scalars(_ value: AnyCodableValue) -> [UInt32]? {
            if case .string(let s) = value { return s.unicodeScalars.map(\.value) }
            return nil
        }
        #expect(scalars(try parseJSON("\"\u{FEFF}sess_b\"")) == [0xFEFF] + "sess_b".unicodeScalars.map(\.value))
        #expect(scalars(try parseJSON("\"\u{FEFF}\"")) == [0xFEFF])
        #expect(scalars(try parseJSON("\"a\\n\u{FEFF}b\"")) == [0x61, 0x0A, 0xFEFF, 0x62])
        #expect(scalars(try parseJSON("\"a\u{FEFF}\"")) == [0x61, 0xFEFF])
        guard case .dict(let object) = try parseJSON("{\"\u{FEFF}k\":1}") else {
            Issue.record("not an object")
            return
        }
        #expect(object.keys.map { $0.unicodeScalars.map(\.value) } == [[0xFEFF, 0x6B]])
        #expect(try canonicalJSON(parseJSON("[\"\u{FEFF}x\"]")).unicodeScalars.elementsEqual("[\"\u{FEFF}x\"]".unicodeScalars))

        // The document's own byte order mark is still read past, and the string's kept
        #expect(scalars(try parseJSON([0xEF, 0xBB, 0xBF] + Array("\"\u{FEFF}x\"".utf8))) == [0xFEFF, 0x78])

        // Bytes that aren't UTF-8 are still refused: a stray continuation byte, an
        // overlong form, an encoded surrogate, a truncated sequence
        for bad: [UInt8] in [[0x22, 0x80, 0x22], [0x22, 0xC0, 0xAF, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22], [0x22, 0xE2, 0x82, 0x22], [0x22, 0x61, 0xFF, 0x22]] {
            #expect(throws: JSONParseError.self, "\(bad)") { try parseJSON(bad) }
        }
    }
}
