import Foundation
import SmallChatCore

/// JSON serialization and deserialization helpers for the transport layer.
///
/// Mirrors the TypeScript `serialization.ts` module.
public enum TransportSerialization {

    // MARK: - JSON Encode

    /// Encode a value as JSON `Data`.
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(value)
    }

    /// Encode a dictionary of `AnySendable` values as JSON `Data`.
    public static func encodeArgs(_ args: [String: AnySendable]) throws -> Data {
        var dict: [String: Any] = [:]
        for (key, value) in args {
            dict[key] = jsonCompatible(value.value)
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// Convert an argument value to something `JSONSerialization` accepts:
    /// `AnyCodableValue` (and arrays/dictionaries of it) become Foundation
    /// values; everything else is returned unchanged.
    public static func jsonCompatible(_ value: Any) -> Any {
        switch value {
        case let codable as AnyCodableValue:
            switch codable {
            case .string(let s): return s
            case .int(let i): return i
            case .double(let d): return d
            case .bool(let b): return b
            case .null: return NSNull()
            case .array(let items): return items.map { jsonCompatible($0) }
            case .dict(let dict): return dict.mapValues { jsonCompatible($0) }
            }
        case let sendable as AnySendable:
            return jsonCompatible(sendable.value)
        case let array as [Any]:
            return array.map { jsonCompatible($0) }
        case let dict as [String: Any]:
            return dict.mapValues { jsonCompatible($0) }
        default:
            return value
        }
    }

    // MARK: - JSON Decode

    /// Decode JSON `Data` into the given `Decodable` type.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Decode JSON `Data` into a dictionary.
    public static func decodeDictionary(from data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportError.invalidResponse(message: "Expected JSON dictionary")
        }
        return dict
    }

    // MARK: - Query Parameter Serialization

    /// Serialize a value for use as a URL query parameter or path segment
    /// (before percent-encoding). Booleans are `true`/`false`, arrays are
    /// comma-joined, objects are JSON.
    public static func serializeQueryValue(_ value: Any) -> String {
        let value = jsonCompatible(value)
        // Exact type checks: on Apple platforms `as? Bool` and `as? Int` both
        // match an NSNumber (and each other), so test what the value really is.
        let valueType = type(of: value)
        if valueType == Bool.self { return (value as! Bool) ? "true" : "false" }
        if valueType == Int.self { return String(value as! Int) }
        if valueType == Double.self { return String(value as! Double) }
        if let string = value as? String { return string }
        if valueType is NSNumber.Type, let number = value as? NSNumber {
            if String(cString: number.objCType) == "c" { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let array = value as? [Any] {
            return array.map { serializeQueryValue($0) }.joined(separator: ",")
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    /// Percent-encode a path segment or query component: everything except
    /// RFC 3986 unreserved characters (`A-Z a-z 0-9 - . _ ~`) is escaped, so
    /// `/ ? # & = +` and spaces in a value can never change the URL's shape.
    public static func percentEncodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Names of the `{name}` placeholders in a route path, in order.
    public static func pathPlaceholders(in path: String) -> [String] {
        var names: [String] = []
        var rest = Substring(path)
        while let open = rest.firstIndex(of: "{"),
              let close = rest[open...].firstIndex(of: "}") {
            let name = String(rest[rest.index(after: open)..<close])
            if !name.isEmpty { names.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    // MARK: - Input Serialization

    /// Serialized HTTP request components.
    public struct SerializedRequest: Sendable {
        public let url: String
        public let method: HTTPMethod
        public let headers: [String: String]
        public let body: Data?
    }

    /// Serialize tool arguments into HTTP request components.
    ///
    /// - Every `{name}` placeholder in the path is replaced by the argument of
    ///   that name, percent-encoded as one path segment. A placeholder with no
    ///   argument is an error: the request is never sent with a literal `{name}`.
    /// - Declared query params go in the query string. For GET and HEAD when
    ///   the route declares no query params, and for DELETE without a route,
    ///   every argument not used in the path goes in the query string.
    /// - Otherwise the arguments not used in the path or query (or exactly the
    ///   declared body params) are the JSON body.
    public static func serializeInput(
        baseURL: String,
        path: String,
        method: HTTPMethod,
        args: [String: AnySendable],
        route: HTTPTransportRoute?
    ) throws -> SerializedRequest {
        var headers = route?.headers ?? [:]

        // Path params: the declared ones plus any placeholder in the path.
        var path = path
        var pathParams = Set(route?.pathParams ?? [])
        for name in pathPlaceholders(in: path) {
            pathParams.insert(name)
            guard let value = args[name] else {
                throw TransportError.invalidRequest(message: "Missing value for path parameter '\(name)' in \(path)")
            }
            path = path.replacingOccurrences(
                of: "{\(name)}",
                with: percentEncodeComponent(serializeQueryValue(value.value))
            )
        }

        // Query params
        let isGetLike = method == .GET || method == .HEAD
        let hasBody = !isGetLike
        let declaredQuery = route?.queryParams ?? []
        var queryNames: [String]
        if declaredQuery.isEmpty && (isGetLike || (route == nil && method == .DELETE)) {
            queryNames = args.keys.filter { !pathParams.contains($0) }.sorted()
        } else {
            queryNames = declaredQuery
        }
        queryNames = queryNames.filter { args[$0] != nil }
        let query = queryNames.map { name in
            "\(percentEncodeComponent(name))=\(percentEncodeComponent(serializeQueryValue(args[name]!.value)))"
        }.joined(separator: "&")

        // Full URL
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var fullURL = cleanPath.isEmpty ? base : "\(base)/\(cleanPath)"
        if !query.isEmpty {
            fullURL += "?\(query)"
        }

        // Body
        var body: Data?
        if hasBody {
            let queryParams = Set(queryNames)
            let bodyParams = route?.bodyParams ?? []
            var bodyDict: [String: Any] = [:]
            if !bodyParams.isEmpty {
                for param in bodyParams {
                    if let value = args[param] {
                        bodyDict[param] = jsonCompatible(value.value)
                    }
                }
            } else {
                // Exclude path and query params, send the rest as body
                for (key, value) in args where !pathParams.contains(key) && !queryParams.contains(key) {
                    bodyDict[key] = jsonCompatible(value.value)
                }
            }

            if !bodyDict.isEmpty {
                guard JSONSerialization.isValidJSONObject(bodyDict) else {
                    throw TransportError.invalidRequest(message: "Arguments are not representable as JSON")
                }
                body = try JSONSerialization.data(withJSONObject: bodyDict)
                if headers["Content-Type"] == nil {
                    headers["Content-Type"] = "application/json"
                }
            }
        }

        return SerializedRequest(url: fullURL, method: method, headers: headers, body: body)
    }

    /// Serialize tool arguments into HTTP request components based on a route.
    public static func serializeInput(
        baseURL: String,
        args: [String: AnySendable],
        route: HTTPTransportRoute
    ) throws -> SerializedRequest {
        try serializeInput(baseURL: baseURL, path: route.path, method: route.method, args: args, route: route)
    }

    // MARK: - Output Parsing

    /// Parse an HTTP response into a `TransportOutput`.
    ///
    /// Content-Type routing:
    ///   - `application/json` → parsed JSON
    ///   - `text/*` → UTF-8 string
    ///   - binary types → base64-encoded
    ///   - 204 No Content → nil body
    public static func parseHTTPResponse(
        statusCode: Int,
        headers: [String: String],
        data: Data?
    ) -> TransportOutput {
        if statusCode == 204 || (data?.isEmpty ?? true) {
            return TransportOutput(
                statusCode: statusCode,
                headers: headers,
                body: nil,
                metadata: [:]
            )
        }

        return TransportOutput(
            statusCode: statusCode,
            headers: headers,
            body: data,
            metadata: [:]
        )
    }

    /// Check if a content type represents binary data.
    public static func isBinaryContentType(_ contentType: String) -> Bool {
        let binary = [
            "application/octet-stream", "image/", "audio/",
            "video/", "application/pdf", "application/zip",
        ]
        return binary.contains(where: { contentType.contains($0) })
    }
}
