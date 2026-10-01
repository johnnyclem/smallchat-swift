import Foundation

// MARK: - JSON text → AnyCodableValue

/// A JSON text that could not be parsed.
public struct JSONParseError: Error, Sendable, CustomStringConvertible {
    /// Byte offset (UTF-8) where parsing failed.
    public let offset: Int
    public let reason: String

    public init(offset: Int, reason: String) {
        self.offset = offset
        self.reason = reason
    }

    public var description: String { "Invalid JSON at byte \(offset): \(reason)" }
}

/// What the JSON reader does with a `\u` escape that leaves a lone UTF-16
/// surrogate (which a Swift `String` cannot hold).
public enum LoneSurrogatePolicy: Sendable {
    /// Refuse the text (the default).
    case reject
    /// Read it as U+FFFD, as a UTF-8 encoder would write it.
    case replace
}

/// Parse a JSON text (RFC 8259) into an `AnyCodableValue`.
///
/// Numbers are read the way ECMAScript's `JSON.parse` reads them: as the
/// nearest IEEE-754 double (`1E30`, `4.50` and `-0` are all accepted). A
/// number written without a fraction or exponent whose value is an integer
/// of magnitude at most 2^53 becomes `.int`; every other number is
/// `.double`. Canonicalization (`canonicalJSON`) formats both the same way,
/// so the distinction never changes a digest.
///
/// Unlike Foundation's decoders this keeps every number exactly as a
/// TypeScript peer sees it, which is what content hashes and call digests
/// need. Duplicate object keys keep the last value (as `JSON.parse` does).
/// Two member names that differ in code points but are canonically
/// equivalent (`"\u00e9"` and `"e\u0301"`) are refused: `JSON.parse` and
/// RFC 8785 keep both members, a Swift dictionary would silently keep one.
/// A `\u` escape that leaves a lone UTF-16 surrogate is refused by
/// default, since a Swift `String` cannot hold one (`LoneSurrogatePolicy`).
public func parseJSON(_ text: String, loneSurrogates: LoneSurrogatePolicy = .reject) throws -> AnyCodableValue {
    try parseJSON(Array(text.utf8), loneSurrogates: loneSurrogates)
}

/// Parse UTF-8 JSON bytes. See `parseJSON(_:loneSurrogates:)`.
public func parseJSON(_ data: Data, loneSurrogates: LoneSurrogatePolicy = .reject) throws -> AnyCodableValue {
    try parseJSON([UInt8](data), loneSurrogates: loneSurrogates)
}

/// Parse UTF-8 JSON bytes. See `parseJSON(_:loneSurrogates:)`.
public func parseJSON(_ bytes: [UInt8], loneSurrogates: LoneSurrogatePolicy = .reject) throws -> AnyCodableValue {
    var parser = JSONTextParser(bytes: bytes, loneSurrogates: loneSurrogates)
    // A UTF-8 byte order mark is not JSON, but files written by some editors carry one.
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
    parser.skipWhitespace()
    let value = try parser.parseValue(depth: 0)
    parser.skipWhitespace()
    guard parser.index == bytes.count else {
        throw parser.error("unexpected data after the JSON value")
    }
    return value
}

private struct JSONTextParser {
    let bytes: [UInt8]
    let loneSurrogates: LoneSurrogatePolicy
    var index = 0

    /// Nesting deeper than this is refused (protects the stack).
    static let maxDepth = 512

    init(bytes: [UInt8], loneSurrogates: LoneSurrogatePolicy) {
        self.bytes = bytes
        self.loneSurrogates = loneSurrogates
    }

    /// A lone surrogate: refused, or read as U+FFFD.
    func loneSurrogate(_ scalars: inout String.UnicodeScalarView) throws {
        guard loneSurrogates == .replace else { throw error("lone UTF-16 surrogate in a \\u escape") }
        scalars.append("\u{FFFD}")
    }

    func error(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> AnyCodableValue {
        guard depth <= Self.maxDepth else { throw error("nesting deeper than \(Self.maxDepth)") }
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<(index + utf8.count)]) == utf8 else {
            throw error("expected \(literal)")
        }
        index += utf8.count
    }

    mutating func parseObject(depth: Int) throws -> AnyCodableValue {
        index += 1  // {
        var object: [String: AnyCodableValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .dict(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw error("expected an object key")
            }
            let keyOffset = index
            let key = try parseString()
            // Swift String keys compare by canonical equivalence: a different
            // spelling of a name already present would replace that member.
            if let existing = object.index(forKey: key),
               !object[existing].key.unicodeScalars.elementsEqual(key.unicodeScalars) {
                throw JSONParseError(offset: keyOffset, reason: "two member names are canonically equivalent but not identical; an object cannot hold both")
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .dict(object) }
            throw error("expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> AnyCodableValue {
        index += 1  // [
        var items: [AnyCodableValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw error("expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        index += 1  // opening quote
        var scalars = String.UnicodeScalarView()
        var runStart = index
        func flushRun(_ end: Int, into scalars: inout String.UnicodeScalarView) throws {
            guard end > runStart else { return }
            guard let run = String(bytes: bytes[runStart..<end], encoding: .utf8) else {
                throw JSONParseError(offset: runStart, reason: "invalid UTF-8 in a string")
            }
            scalars.append(contentsOf: run.unicodeScalars)
        }
        while true {
            guard index < bytes.count else { throw error("unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                try flushRun(index, into: &scalars)
                index += 1
                return String(scalars)
            }
            if byte < 0x20 { throw error("unescaped control character in a string") }
            if byte != UInt8(ascii: "\\") {
                index += 1
                continue
            }
            try flushRun(index, into: &scalars)
            index += 1
            guard index < bytes.count else { throw error("unterminated escape") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                let unit = try parseHex4()
                if (0xD800...0xDBFF).contains(unit) {
                    let save = index
                    if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                            scalars.append(Unicode.Scalar(value)!)
                        } else {
                            index = save  // the next escape is read on its own
                            try loneSurrogate(&scalars)
                        }
                    } else {
                        try loneSurrogate(&scalars)
                    }
                } else if (0xDC00...0xDFFF).contains(unit) {
                    try loneSurrogate(&scalars)
                } else {
                    scalars.append(Unicode.Scalar(UInt32(unit))!)
                }
            default:
                throw error("invalid escape")
            }
            runStart = index
        }
    }

    mutating func parseHex4() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw error("truncated \\u escape") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit in a \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    mutating func parseNumber() throws -> AnyCodableValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error("truncated number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        } else {
            throw error("invalid number")
        }
        var isInteger = true
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            let digits = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > digits else { throw error("expected digits after '.'") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            let digits = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > digits else { throw error("expected exponent digits") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let double = Double(text) else {
            throw JSONParseError(offset: start, reason: "invalid number \(text)")
        }
        // Overflow (1e400) is Infinity in JSON.parse; it has no JSON form to round-trip.
        guard double.isFinite else {
            throw JSONParseError(offset: start, reason: "number \(text) is out of range")
        }
        if isInteger, double.magnitude <= 9_007_199_254_740_992, !(double == 0 && double.sign == .minus) {
            return .int(Int(double))
        }
        return .double(double)
    }
}
