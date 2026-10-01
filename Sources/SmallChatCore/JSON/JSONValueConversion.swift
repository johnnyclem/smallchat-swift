import Foundation

// MARK: - Native values → AnyCodableValue

/// A native argument value that has no JSON form.
public struct NotJSONError: Error, Sendable, CustomStringConvertible {
    /// Where the value sits (`$.filter[0]`).
    public let path: String
    /// The value's type.
    public let typeName: String

    public init(path: String, typeName: String) {
        self.path = path
        self.typeName = typeName
    }

    public var description: String { "\(typeName) at \(path) is not a JSON value" }
}

/// The JSON value of a native tool argument: `AnyCodableValue`, strings,
/// booleans, integers, floating-point numbers, `NSNull`, `NSNumber`,
/// arrays and string-keyed dictionaries of these, and `SCObject`s (which
/// are unwrapped first). Throws `NotJSONError` for anything else, so a
/// call never validates or digests a value it cannot represent.
public func jsonValue(from value: any Sendable) throws -> AnyCodableValue {
    try jsonValue(from: value as Any, path: "$")
}

/// The JSON object of a native argument dictionary (see `jsonValue(from:)`).
public func jsonObject(from arguments: [String: any Sendable]) throws -> [String: AnyCodableValue] {
    var object: [String: AnyCodableValue] = [:]
    for (key, value) in arguments {
        object[key] = try jsonValue(from: value as Any, path: "$.\(key)")
    }
    return object
}

private func jsonValue(from value: Any, path: String) throws -> AnyCodableValue {
    // Exact type checks first: on Apple platforms `as? Bool` and `as? Int`
    // both match an NSNumber (and each other).
    let valueType = type(of: value)
    if valueType == Bool.self { return .bool(value as! Bool) }
    if valueType == Int.self { return .int(value as! Int) }
    if valueType == Double.self { return .double(value as! Double) }
    if valueType == String.self { return .string(value as! String) }
    if let codable = value as? AnyCodableValue { return codable }
    if let object = value as? SCObject { return try jsonValue(from: object.unwrap() as Any, path: path) }
    if valueType == Float.self { return .double(Double(value as! Float)) }
    if valueType == Int8.self { return .int(Int(value as! Int8)) }
    if valueType == Int16.self { return .int(Int(value as! Int16)) }
    if valueType == Int32.self { return .int(Int(value as! Int32)) }
    if valueType == Int64.self { return .int(Int(value as! Int64)) }
    if valueType == UInt8.self { return .int(Int(value as! UInt8)) }
    if valueType == UInt16.self { return .int(Int(value as! UInt16)) }
    if valueType == UInt32.self { return .int(Int(value as! UInt32)) }
    if valueType == UInt.self || valueType == UInt64.self {
        let wide = valueType == UInt.self ? UInt64(value as! UInt) : value as! UInt64
        return wide <= UInt64(Int.max) ? .int(Int(wide)) : .double(Double(wide))
    }
    if let string = value as? String { return .string(string) }
    if value is NSNull { return .null }
    if valueType is NSNumber.Type, let number = value as? NSNumber {
        switch String(cString: number.objCType) {
        case "c", "B": return .bool(number.boolValue)
        case "f", "d": return .double(number.doubleValue)
        default: return .int(number.intValue)
        }
    }
    // An Optional that holds nothing is JSON null.
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let wrapped = mirror.children.first?.value else { return .null }
        return try jsonValue(from: wrapped, path: path)
    }
    if let array = value as? [Any] {
        var items: [AnyCodableValue] = []
        items.reserveCapacity(array.count)
        for (i, item) in array.enumerated() {
            items.append(try jsonValue(from: item, path: "\(path)[\(i)]"))
        }
        return .array(items)
    }
    if let dict = value as? [String: Any] {
        var object: [String: AnyCodableValue] = [:]
        for (key, item) in dict {
            object[key] = try jsonValue(from: item, path: "\(path).\(key)")
        }
        return .dict(object)
    }
    throw NotJSONError(path: path, typeName: String(describing: valueType))
}
