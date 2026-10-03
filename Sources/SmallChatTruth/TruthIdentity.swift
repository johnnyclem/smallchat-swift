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

/// The comparison form of an identity: NFKC (full-width and ligature
/// look-alikes fold), default-ignorable code points removed, trimmed,
/// lowercased.
public func identityKey(_ identity: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in identity.precomposedStringWithCompatibilityMapping.unicodeScalars
    where !scalar.properties.isDefaultIgnorableCodePoint {
        scalars.append(scalar)
    }
    return ecmaScriptTrim(String(scalars)).lowercased()
}

/// An anonymous or generic identity (`system`, `Assistant`, `ａｉ`, …).
public func isAnonymousIdentity(_ identity: String) -> Bool {
    anonymousIdentities.contains(identityKey(identity))
}

/// `migration` and `detector:*` belong to stenographer's internal write paths.
public func isReservedIdentity(_ identity: String) -> Bool {
    let key = identityKey(identity)
    return key == truthMigrationAuthor || key.hasPrefix(truthDetectorPrefix)
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
        if allowDetector, identityKey(identity).hasPrefix(truthDetectorPrefix) { return nil }
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
    private var exact: [String: (id: String, role: TruthSigner.Role)] = [:]
    /// Longest prefix first, so `agent:ci:*` can narrow `agent:*`.
    private var prefixes: [(prefix: String, role: TruthSigner.Role)] = []

    /// Throws on an empty id or a name listed for two signers.
    public init(signers: [TruthSigner]) throws {
        for (i, signer) in signers.enumerated() {
            let id = ecmaScriptTrim(signer.id.precomposedStringWithCanonicalMapping)
            guard !id.isEmpty else {
                throw TruthError.malformedLine(line: 0, reason: "signer registry: signers[\(i)].id must be a non-empty string")
            }
            if id.hasSuffix("*") {
                prefixes.append((identityKey(String(id.dropLast())), signer.role))
                continue
            }
            for name in [id] + signer.aliases {
                let key = identityKey(name)
                if let prior = exact[key], prior.id != id {
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
        if let listed = exact[key] { return listed }
        if let match = prefixes.first(where: { key.hasPrefix($0.prefix) && key.utf16.count > $0.prefix.utf16.count }) {
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
