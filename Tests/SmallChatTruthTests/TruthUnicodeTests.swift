import Foundation
import Testing
import SmallChatCore
@testable import SmallChatTruth

// Identity keys are Unicode NFKC, default-ignorable code points removed,
// trimmed, lowercased (truth format v2, "Identities"). Stenographer and
// short-hand compute them with their runtime's ICU: on Node 22 that is ICU
// 77.1, Unicode 16.0. These tests hold SmallChatTruth to the same keys
// whatever Unicode version the platform's Foundation or Swift runtime knows.

/// `s` spelled in OUTLINED LATIN CAPITAL LETTERs (U+1CCD6..U+1CCEF, new in
/// Unicode 16.0), each of which has a <font> decomposition to A..Z.
private func outlined(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { Unicode.Scalar($0.value - 0x41 + 0x1CCD6)! }))
}

/// A TB two agent sessions settled together, by `author` (who signs it) and `member` (the second member), as one line.
private func quorumLine(author: String, member: String) -> String {
    chainTruthLines([
        #"{"id":"TB-Q","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"\#(author)","claim":"searchV1 is gone; searchV2 replaced it.","evidence":[{"kind":"commit","ref":"c4fe0b1"},{"kind":"file","ref":"src/api/search.ts:1"}],"signedBy":"\#(author)","literals":[{"dead":"searchV1","current":"searchV2"}],"quorum":[{"author":"agent:claude-code","agentSessionId":"sess_a","ts":"2026-09-01T10:13:00.000Z","evidence":[{"kind":"commit","ref":"c4fe0b1"}]},{"author":"\#(member)","agentSessionId":"sess_b","ts":"2026-09-01T10:14:00.000Z","evidence":[{"kind":"file","ref":"src/api/search.ts:1"}]}],"status":"active"}"#,
    ])[0]
}

/// The message the codec refuses `line` with, or nil when it reads it.
private func refusal(_ line: String) -> String? {
    do {
        _ = try TruthFormat.decode(line)
        return nil
    } catch {
        return String(describing: error)
    }
}

/// The code points of `s`, for comparing keys code point for code point (not by canonical equivalence).
private func scalars(_ s: String) -> [UInt32] {
    s.unicodeScalars.map(\.value)
}

private func hex(_ v: UInt32) -> String {
    String(v, radix: 16, uppercase: true)
}

@Suite("Identity keys (Unicode 16.0)")
struct TruthUnicodeIdentityTests {

    @Test("SW-UNICODE-1: outlined letters fold as Unicode 16.0's NFKC folds them, so they name who they spell")
    func outlinedLetters() throws {
        let codex = "agent:" + outlined("CODEX")
        let ai = outlined("AI")
        #expect(codex.unicodeScalars.map(\.value) == [0x61, 0x67, 0x65, 0x6E, 0x74, 0x3A, 0x1CCD8, 0x1CCE4, 0x1CCD9, 0x1CCDA, 0x1CCED])
        #expect(Array(identityKey(codex).utf8) == Array("agent:codex".utf8))
        #expect(sameIdentity(codex, "agent:codex"))
        #expect(isAnonymousIdentity(ai))
        #expect(identityIssue(ai) != nil)
        #expect(isReservedIdentity(outlined("MIGRATION")))

        // Case 120 of the three-way differential run, verbatim: the writer is agent:codex by key, so
        // it is a quorum member and signs its TB (rule 2). Stenographer and short-hand take it as truth.
        let tb120 = #"{"schemaVersion":2,"seq":1,"id":"TBQ","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"\#(codex)","claim":"searchV1 is gone; searchV2 replaced it.","evidence":[{"kind":"commit","ref":"c4fe0b1"},{"kind":"file","ref":"src/api/search.ts:1"}],"signedBy":"agent:codex","literals":[{"dead":"searchV1","current":"searchV2"}],"quorum":[{"author":"agent:claude-code","agentSessionId":"sess_a","ts":"2026-09-01T10:13:00.000Z","evidence":[{"kind":"commit","ref":"c4fe0b1"}]},{"author":"agent:codex","agentSessionId":"sess_b","ts":"2026-09-01T10:14:00.000Z","evidence":[{"kind":"file","ref":"src/api/search.ts:1"}]}],"status":"active","x-steno":{"origin":"local","provenance":{"kind":"manual"},"agentSessionId":null,"targetRef":null,"links":[]},"prevHash":null,"hash":"ec468c677644b3fde830b521bab82613577e5b181bd07eb7fa9685d9e61be7ec"}"#
        #expect(try TruthFormat.hash(line: tb120) == "ec468c677644b3fde830b521bab82613577e5b181bd07eb7fa9685d9e61be7ec")
        #expect(throws: Never.self) { try TruthFormat.decode(tb120) }
        let signers = try TruthSignerRegistry(signers: [TruthSigner(id: "agent:*", role: .agent)])
        for options in [TruthReadOptions(), TruthReadOptions(signers: signers)] {
            let read = TruthWiki.parse(lines: [tb120], options: options)
            #expect(read.errors.isEmpty, "\(read.errors)")
            #expect(read.entries.first?.inadmissible == nil)
            #expect(read.entries.map(TruthWiki.classify) == [.groundTruth])
        }

        // Case 161: quorum member 1's author keys to "ai", which is anonymous (rule 1)
        let tb161 = #"{"schemaVersion":2,"seq":1,"id":"TBQ","type":"TB","ts":"2026-09-01T10:14:00.000Z","author":"agent:codex","claim":"searchV1 is gone; searchV2 replaced it.","evidence":[{"kind":"commit","ref":"c4fe0b1"},{"kind":"file","ref":"src/api/search.ts:1"}],"signedBy":"agent:codex","literals":[{"dead":"searchV1","current":"searchV2"}],"quorum":[{"author":"\#(ai)","agentSessionId":"sess_a","ts":"2026-09-01T10:13:00.000Z","evidence":[{"kind":"commit","ref":"c4fe0b1"}]},{"author":"agent:codex","agentSessionId":"sess_b","ts":"2026-09-01T10:14:00.000Z","evidence":[{"kind":"file","ref":"src/api/search.ts:1"}]}],"status":"active","x-steno":{"origin":"local","provenance":{"kind":"manual"},"agentSessionId":null,"targetRef":null,"links":[]},"prevHash":null,"hash":"aa4c3e6a7d12b9bb56be4bd5e2990e1633cf4b9102644f5e5d7d7462be9043bd"}"#
        #expect(try TruthFormat.hash(line: tb161) == "aa4c3e6a7d12b9bb56be4bd5e2990e1633cf4b9102644f5e5d7d7462be9043bd")
        do {
            _ = try TruthFormat.decode(tb161)
            Issue.record("case 161 was accepted")
        } catch {
            #expect(String(describing: error).contains("quorum member 1: '\(ai)' is anonymous or generic (rule 1)"), "\(error)")
        }
        #expect(TruthWiki.parse(lines: [tb161]).entries.isEmpty)

        // Case 162: an open UV whose author keys to "ai" (stenographer's line, hash and all)
        let uv162 = #"{"schemaVersion":2,"seq":1,"id":"UV-1","type":"UV","ts":"2026-09-01T10:00:00.000Z","author":"\#(ai)","assertion":"searchV1 is still called.","basis":"a log line","verifyBy":{"kind":"ask","value":"ops"},"contests":null,"status":"open","prevHash":null,"hash":"60927b66ad4725981d1091bd5edbbe804ce3956b9df3325b2f326491de45a349"}"#
        #expect(try TruthFormat.hash(line: uv162) == "60927b66ad4725981d1091bd5edbbe804ce3956b9df3325b2f326491de45a349")
        #expect(throws: TruthLineError.self) { try TruthFormat.decode(uv162) }
        #expect(TruthWiki.parse(lines: [uv162]).entries.isEmpty)
    }

    @Test("SW-UNICODE-2: keys are Unicode 16.0's: its compositions, classes and cased letters, and nothing from a later version")
    func unicode16NotLater() throws {
        // Expected keys are stenographer's identityKey on node 22.22 (ICU 77.1, Unicode 16.0)
        let cases: [(input: String, key: String)] = [
            // TULU-TIGALARI VOWEL SIGN AI (U+113C5, 16.0) is U+113C2 twice, canonically: NFKC composes it
            ("agent:\u{113C2}\u{113C2}", "agent:\u{113C5}"),
            // ARABIC PEPET (U+0897, 16.0) has combining class 230, so it follows a class 220 mark
            ("agent:a\u{0897}\u{0316}", "agent:a\u{0316}\u{0897}"),
            // Unicode 16.0 lowercases LATIN CAPITAL LETTER RAMS HORN (U+A7CB, 16.0) to U+0264
            ("Agent:\u{A7CB}", "agent:\u{0264}"),
            // ʕ (U+0295) is a lowercase letter in Unicode 16.0 (17.0 makes it a caseless Lo), so the Σ after it is word-final
            ("agent:\u{0295}\u{03A3}", "agent:\u{0295}\u{03C2}"),
            // LATIN CAPITAL LETTER PHARYNGEAL VOICED FRICATIVE (U+A7CE) is new in 17.0: unassigned in 16.0, so it has no case
            ("agent:\u{A7CE}", "agent:\u{A7CE}"),
            // MODIFIER LETTER CAPITAL S (U+A7F1, 17.0, <super> S) is unassigned in 16.0 too: no decomposition
            ("agent:\u{A7F1}", "agent:\u{A7F1}"),
        ]
        for (input, key) in cases {
            #expect(scalars(identityKey(input)) == scalars(key), "\(scalars(input))")
        }

        // Rule 2 compares those keys: stenographer reads the first and third lines and refuses the others
        #expect(refusal(quorumLine(author: "agent:\u{113C5}", member: "agent:\u{113C2}\u{113C2}")) == nil)
        #expect(refusal(quorumLine(author: "agent:a\u{0897}\u{0316}", member: "agent:a\u{0316}\u{0897}")) == nil)
        #expect(refusal(quorumLine(author: "agent:\u{0295}\u{03A3}", member: "agent:\u{0295}\u{03C2}")) == nil)
        #expect(refusal(quorumLine(author: "agent:\u{0295}\u{03A3}", member: "agent:\u{0295}\u{03C3}"))?.contains("is not a quorum member") == true)
        #expect(refusal(quorumLine(author: "agent:\u{A7CE}", member: "agent:\u{A7CF}"))?.contains("is not a quorum member") == true)

        // The signer registry stores a name as Unicode 16.0's NFC (stenographer's canonicalIdentity) and looks it up by key
        let registry = try TruthSignerRegistry(signers: [
            TruthSigner(id: "agent:\u{113C2}\u{113C2}", role: .agent),
            TruthSigner(id: "agent:\u{113C5}", role: .agent),
        ])
        let listed = try #require(registry.lookup("AGENT:\u{113C5}"))
        #expect(scalars(listed.id) == scalars("agent:\u{113C5}"))
        #expect(listed.role == .agent)
        #expect(throws: TruthError.self) {
            try TruthSignerRegistry(signers: [
                TruthSigner(id: "agent:\u{113C5}", role: .agent),
                TruthSigner(id: "kim", role: .human, aliases: ["agent:\u{113C2}\u{113C2}"]),
            ])
        }
    }

    @Test("SW-UNICODE-3: the tables agree with Node 22's ICU (Unicode 16.0) on every code point")
    func everyCodePoint() throws {
        let vectors = try UnicodeVectors.load()
        #expect(vectors.unicode == "16.0" && Unicode16.version == "16.0.0")

        // identityKey of every code point, the default-ignorables, white space and Σ among them
        var mismatches: [String] = []
        for v in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(v) else { continue }
            let expected = vectors.keys[v] ?? (vectors.removed.contains(v) ? [] : [v])
            let key = scalars(identityKey(String(Character(scalar))))
            if key != expected { mismatches.append("U+\(hex(v)): \(key.map(hex)) is not \(expected.map(hex))") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) keys differ, among them \(mismatches.prefix(20))")

        // NFC composes exactly the primary composites ICU composes, Hangul syllables aside
        #expect(Set(Unicode16.compositions.values) == vectors.composites)
        for v in vectors.composites {
            let composite = String(Character(Unicode.Scalar(v)!))
            #expect(scalars(Unicode16.nfc(Unicode16.nfd(composite))) == [v], "U+\(hex(v))")
        }

        // Canonical combining classes, as NFD orders marks: the same code points are marks, and two
        // marks are of one class exactly when ICU's NFD finds them so
        var marks: Set<UInt32> = []
        var classOf: [UInt32: UInt32] = [:]
        for (codePoints, name) in vectors.combiningClasses {
            for v in codePoints {
                marks.insert(v)
                classOf[v] = name
            }
        }
        let decomposable = Set(Unicode16.canonicalDecompositions.keys)
        #expect(marks == Set(Unicode16.combiningClasses.keys).subtracting(decomposable))
        var names: [UInt8: UInt32] = [:]
        for (v, name) in classOf {
            let cc = Unicode16.combiningClass(Unicode.Scalar(v)!)
            #expect(cc == Unicode16.combiningClass(Unicode.Scalar(name)!), "U+\(hex(v))")
            #expect(names.updateValue(name, forKey: cc).map { $0 == name } ?? true, "class \(cc) named twice")
        }

        // The classes Final_Sigma reads, as ICU's toLowerCase reads them
        let ignorable = Set(Unicode16.caseIgnorableRanges.flatMap { $0 })
        let cased = Set(Unicode16.casedRanges.flatMap { $0 })
        #expect(ignorable == vectors.caseIgnorable)
        #expect(cased.subtracting(ignorable) == vectors.casedNotIgnorable)

        // Strings: composition, reordering, Hangul, Final_Sigma and default-ignorables in context
        for (input, key) in vectors.strings {
            #expect(scalars(identityKey(input)) == scalars(key), "\(scalars(input))")
        }
        for (input, nfc) in vectors.nfc {
            #expect(scalars(Unicode16.nfc(input)) == scalars(nfc), "\(scalars(input))")
        }
    }
}

/// Tests/Fixtures/unicode-16/identity-keys.json: what stenographer's identityKey, NFC, NFD and
/// toLowerCase do on Node 22 (ICU 77.1, Unicode 16.0), written by Scripts/generate-unicode-tables.mjs.
private struct UnicodeVectors {
    var unicode = ""
    /// identityKey of every code point whose key is neither itself nor empty.
    var keys: [UInt32: [UInt32]] = [:]
    /// The code points whose key is empty.
    var removed: Set<UInt32> = []
    var composites: Set<UInt32> = []
    /// The marks of each class, named by the class's lowest code point.
    var combiningClasses: [(codePoints: ClosedRange<UInt32>, name: UInt32)] = []
    var caseIgnorable: Set<UInt32> = []
    var casedNotIgnorable: Set<UInt32> = []
    var strings: [(String, String)] = []
    var nfc: [(String, String)] = []

    static func load() throws -> UnicodeVectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/unicode-16/identity-keys.json")
        guard case .dict(let file) = try parseJSON(try Data(contentsOf: url)) else { throw TruthLineError("identity-keys.json is not an object") }
        func list(_ name: String) -> [String] {
            guard case .array(let items)? = file[name] else { return [] }
            return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        func pairs(_ name: String) -> [(String, String)] {
            guard case .array(let items)? = file[name] else { return [] }
            return items.compactMap { item in
                guard case .array(let pair) = item, pair.count == 2, case .string(let a) = pair[0], case .string(let b) = pair[1] else { return nil }
                return (text(a), text(b))
            }
        }
        func hex<S: StringProtocol>(_ s: S) -> UInt32 { UInt32(s, radix: 16)! }
        func range<S: StringProtocol>(_ s: S) -> ClosedRange<UInt32> {
            let bounds = s.split(separator: "-")
            return hex(bounds[0])...hex(bounds[bounds.count - 1])
        }
        /// Space-separated code points in hex, as a string.
        func text(_ s: String) -> String {
            String(String.UnicodeScalarView(s.split(separator: " ").map { Unicode.Scalar(hex($0))! }))
        }

        var vectors = UnicodeVectors()
        if case .string(let version)? = file["unicode"] { vectors.unicode = version }
        // `cp:k1,k2,…`, `A-B:T` (A+i to T+i) and `A-B/2:T` (A+2i to T+2i)
        for entry in list("keys") {
            let parts = entry.split(separator: ":")
            let key = parts[1].split(separator: ",").map { hex($0) }
            let source = parts[0].split(separator: "/")
            let codePoints = range(source[0])
            let step = source.count == 2 ? Int(source[1])! : 1
            if codePoints.count == 1 {
                vectors.keys[codePoints.lowerBound] = key
            } else {
                for v in stride(from: codePoints.lowerBound, through: codePoints.upperBound, by: step) {
                    vectors.keys[v] = [key[0] + v - codePoints.lowerBound]
                }
            }
        }
        vectors.removed = Set(list("removed").flatMap { range($0) })
        vectors.composites = Set(list("composites").flatMap { range($0) })
        vectors.combiningClasses = list("combiningClasses").map { entry in
            let parts = entry.split(separator: ":")
            return (range(parts[0]), hex(parts[1]))
        }
        vectors.caseIgnorable = Set(list("caseIgnorable").flatMap { range($0) })
        vectors.casedNotIgnorable = Set(list("casedNotIgnorable").flatMap { range($0) })
        vectors.strings = pairs("strings")
        vectors.nfc = pairs("nfc")
        return vectors
    }
}
