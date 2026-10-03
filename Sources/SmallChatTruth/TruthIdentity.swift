import Foundation
import SmallChatCore

// MARK: - Identities (truth format v2, "Identities")
//
// `author` and `signedBy` name someone who stands behind an entry. A reader
// refuses a line whose identity is anonymous or generic, contains a control
// character, or is reserved where it doesn't belong (`migration` authors
// only an unsigned backfilled TB; `detector:*` authors only PROPOSAL lines).
// Identities compare by key — Unicode NFKC, default-ignorable code points
// removed, trimmed, lowercased — so `Assistant` and `ａｓｓｉｓｔａｎｔ` are
// both refused, and `Alice` and `alice` are one person. Lines keep
// identities as written.

/// Identities that cannot stand behind anything — mirrors stenographer's floor.
private let anonymousIdentities: Set<String> = [
    "", "system", "assistant", "agent", "ai", "bot", "anonymous",
    "unknown", "user", "human", "admin", "null", "none", "me",
]

/// Reserved for stenographer's backfill of pre-assertion tombstones (an unsigned TB).
public let truthMigrationAuthor = "migration"

/// Reserved prefix for the pipelines that file proposals.
public let truthDetectorPrefix = "detector:"

/// Whitespace as ECMAScript's `String.prototype.trim` and `\s` see it:
/// tab, VT, FF, space, NBSP, BOM, every space separator (Zs), and the line
/// terminators LF, CR, U+2028 and U+2029.
func isECMAScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029: return true
    default: return scalar.properties.generalCategory == .spaceSeparator
    }
}

/// `s.trim()` as ECMAScript trims (see `isECMAScriptWhitespace`).
func ecmaScriptTrim(_ s: String) -> String {
    let scalars = s.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isECMAScriptWhitespace($0) }) else { return "" }
    let last = scalars.lastIndex(where: { !isECMAScriptWhitespace($0) })!
    return String(scalars[first...last])
}

/// `s.toLowerCase()` as ECMAScript lowercases: each scalar's full lowercase
/// mapping, and Final_Sigma, the one context Unicode's default mapping has.
/// `String.lowercased()` maps every Σ to σ; at the end of a word (after a
/// cased letter, and before none, case-ignorables skipped both ways, as ICU
/// skips them) Σ is ς. So `ΟΔΥΣΣΕΥΣ` is `οδυσσευς`, as in stenographer.
func ecmaScriptLowercased(_ s: String) -> String {
    guard s.unicodeScalars.contains("\u{03A3}") else { return s.lowercased() }
    let scalars = Array(s.unicodeScalars)
    /// Whether the first scalar at `indices` that isn't case-ignorable is cased.
    func reachesCased(_ indices: some Sequence<Int>) -> Bool {
        for i in indices where !scalars[i].properties.isCaseIgnorable {
            return scalars[i].properties.isCased
        }
        return false
    }
    var out = String.UnicodeScalarView()
    for (i, scalar) in scalars.enumerated() {
        if scalar == "\u{03A3}" {
            let final = reachesCased(stride(from: i - 1, through: 0, by: -1)) && !reachesCased(i + 1 ..< scalars.count)
            out.append(final ? "\u{03C2}" : "\u{03C3}")
        } else {
            out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
        }
    }
    return String(out)
}

/// `s.startsWith(prefix)` as ECMAScript compares, code unit for code unit.
/// `String.hasPrefix` compares Characters, so to it `agent:` followed by a
/// combining mark (one Character with the `:`) doesn't start with `agent:`.
func hasCodeUnitPrefix(_ s: String, _ prefix: String) -> Bool {
    s.utf8.starts(with: prefix.utf8)
}

/// The comparison form of an identity: NFKC (full-width and ligature
/// look-alikes fold), default-ignorable code points removed, trimmed,
/// lowercased (as ECMAScript lowercases, see `ecmaScriptLowercased`).
/// Compare two keys byte for byte (`sameIdentity`), not with `==`.
public func identityKey(_ identity: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in identity.precomposedStringWithCompatibilityMapping.unicodeScalars
    where !scalar.properties.isDefaultIgnorableCodePoint {
        scalars.append(scalar)
    }
    return ecmaScriptLowercased(ecmaScriptTrim(String(scalars)))
}

/// Whether two identities are one by key: their `identityKey`s compared
/// byte for byte, as stenographer compares them (code unit for code unit).
/// `String ==` compares canonical equivalence, and a key is not always in a
/// normal form (removing default-ignorables after NFKC can leave marks out
/// of order): `agent:a\u{0316}\u{034F}\u{0301}` keys to `agent:a` + U+0316
/// U+0301 and `agent:\u{00E1}\u{0316}` to `agent:á` + U+0316, which `==`
/// calls equal and stenographer calls two names.
func sameIdentity(_ a: String, _ b: String) -> Bool {
    identityKey(a).utf8.elementsEqual(identityKey(b).utf8)
}

/// An anonymous or generic identity (`system`, `Assistant`, `ａｉ`, …).
public func isAnonymousIdentity(_ identity: String) -> Bool {
    anonymousIdentities.contains(identityKey(identity))
}

/// `migration` and `detector:*` belong to stenographer's internal write paths.
public func isReservedIdentity(_ identity: String) -> Bool {
    let key = identityKey(identity)
    return key == truthMigrationAuthor || hasCodeUnitPrefix(key, truthDetectorPrefix)
}

/// Control characters (Unicode Cc: newlines, escapes) have no place in a name someone stands behind.
public func hasControlCharacters(_ identity: String) -> Bool {
    identity.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

/// Why `identity` can't stand behind a line, or nil when it can.
/// `allowDetector` admits `detector:*` (PROPOSAL authors).
public func identityIssue(_ identity: String, allowDetector: Bool = false) -> String? {
    if isAnonymousIdentity(identity) {
        return "anonymous or generic identities cannot assert truth (got \"\(identity)\") — use a registered human handle or agent identity"
    }
    if hasControlCharacters(identity) {
        return "identities cannot contain control characters"
    }
    if isReservedIdentity(identity) {
        if allowDetector, hasCodeUnitPrefix(identityKey(identity), truthDetectorPrefix) { return nil }
        return "'\(truthMigrationAuthor)' and '\(truthDetectorPrefix)*' are reserved for the backfill and detector paths (got \"\(identity)\")"
    }
    return nil
}

/// Throws unless `author` may write toward the truth ledger: a specific,
/// accountable identity (a person's handle, an agent identity, or, with
/// `allowDetector`, a `detector:<name>` pipeline).
public func assertAccountableAuthor(_ author: String, allowDetector: Bool = false) throws {
    if isAnonymousIdentity(author) { throw TruthError.anonymousAuthor(author) }
    if let issue = identityIssue(author, allowDetector: allowDetector) {
        throw TruthError.malformedLine(line: 0, reason: issue)
    }
}

// MARK: - Signer registry (stenographer's signers.json)

/// One listed signer. A trailing `*` in `id` (`agent:*`) matches any
/// identity with that prefix.
public struct TruthSigner: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case human, agent, detector
    }

    public let id: String
    public let role: Role
    /// Other spellings that resolve to `id`.
    public let aliases: [String]

    public init(id: String, role: Role, aliases: [String] = []) {
        self.id = id
        self.role = role
        self.aliases = aliases
    }
}

/// The allowlist stenographer's import consults (`{"signers": [{id, role, aliases?, keys?}]}`):
/// names and roles, not credentials. With one, a TB is truth only when its
/// author and signer are listed as a person or an agent, and a UV only when
/// its author is; a TRANSITION by someone it doesn't list is held; and an
/// agent, for the agent quorum, is an identity it lists with role `agent`.
/// Nothing here authenticates anyone. An entry's `keys` (public keys,
/// `[{alg, id, publicKey}]`) are reserved for key signing in 1.x: 1.0 reads
/// past them, as it does any field it doesn't define.
public struct TruthSignerRegistry: Sendable {
    /// By the key's UTF-8 bytes, as stenographer's Map compares keys: a
    /// `String` key would match canonically equivalent keys (`sameIdentity`).
    private var exact: [[UInt8]: (id: String, role: TruthSigner.Role)] = [:]
    /// Longest prefix first, so `agent:ci:*` can narrow `agent:*`.
    private var prefixes: [(prefix: String, role: TruthSigner.Role)] = []

    /// Throws on an empty id or a name listed for two signers.
    public init(signers: [TruthSigner]) throws {
        for (i, signer) in signers.enumerated() {
            let id = ecmaScriptTrim(signer.id.precomposedStringWithCanonicalMapping)
            guard !id.isEmpty else {
                throw TruthError.malformedLine(line: 0, reason: "signer registry: signers[\(i)].id must be a non-empty string")
            }
            // By scalar, as `endsWith('*')`: a `*` after a prepended mark is one Character with it
            if id.unicodeScalars.last == "*" {
                prefixes.append((identityKey(String(id.unicodeScalars.dropLast())), signer.role))
                continue
            }
            for name in [id] + signer.aliases {
                let key = Array(identityKey(name).utf8)
                if let prior = exact[key], !prior.id.utf8.elementsEqual(id.utf8) {
                    throw TruthError.malformedLine(line: 0, reason: "signer registry: '\(name)' names both '\(prior.id)' and '\(id)'")
                }
                exact[key] = (id, signer.role)
            }
        }
        prefixes.sort { $0.prefix.utf16.count > $1.prefix.utf16.count }
    }

    /// Reads stenographer's `signers.json`.
    public init(json data: Data) throws {
        guard case .dict(let file) = try parseJSON(data), case .array(let list)? = file["signers"] else {
            throw TruthError.malformedLine(line: 0, reason: "signer registry: expected { \"signers\": [...] }")
        }
        var signers: [TruthSigner] = []
        for (i, item) in list.enumerated() {
            guard case .dict(let signer) = item, case .string(let id)? = signer["id"],
                  case .string(let roleName)? = signer["role"], let role = TruthSigner.Role(rawValue: roleName)
            else {
                throw TruthError.malformedLine(line: 0, reason: "signer registry: signers[\(i)] needs a string id and a role (human, agent or detector)")
            }
            var aliases: [String] = []
            if case .array(let names)? = signer["aliases"] {
                aliases = names.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            }
            signers.append(TruthSigner(id: id, role: role, aliases: aliases))
        }
        try self.init(signers: signers)
    }

    /// The listed signer `identity` resolves to (by identity key), or nil.
    public func lookup(_ identity: String) -> (id: String, role: TruthSigner.Role)? {
        let key = identityKey(identity)
        if let listed = exact[Array(key.utf8)] { return listed }
        if let match = prefixes.first(where: { hasCodeUnitPrefix(key, $0.prefix) && key.utf16.count > $0.prefix.utf16.count }) {
            return (identity, match.role)
        }
        return nil
    }

    /// Listed as a person or an agent: someone whose entries can count.
    func lists(_ identity: String) -> Bool {
        guard let role = lookup(identity)?.role else { return false }
        return role == .human || role == .agent
    }
}
