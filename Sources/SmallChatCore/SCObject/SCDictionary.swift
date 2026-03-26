import Foundation

public final class SCDictionary: SCObject, @unchecked Sendable {
    private static let registered: Bool = {
        SCObjectRegistry.shared.register("SCDictionary", superclass: "SCObject")
        return true
    }()

    private let storage: OSAllocatedUnfairLock<[String: SCObject]>

    override public var isa: String { "SCDictionary" }

    public init(entries: [String: SCObject] = [:]) {
        self.storage = OSAllocatedUnfairLock(initialState: entries)
        super.init()
        _ = Self.registered
    }

    public var count: Int { storage.withLock { $0.count } }

    public func objectForKey(_ key: String) -> SCObject? {
        storage.withLock { $0[key] }
    }

    public func setObject(_ key: String, obj: SCObject) {
        storage.withLock { $0[key] = obj }
    }

    public func allKeys() -> [String] {
        storage.withLock { Array($0.keys) }
    }

    public func allValues() -> [SCObject] {
        storage.withLock { Array($0.values) }
    }

    override public var description: String {
        let keys = allKeys()
        let keyList = keys.prefix(5).joined(separator: ", ")
        let suffix = keys.count > 5 ? "..." : ""
        return "<SCDictionary id=\(id) keys=[\(keyList)\(suffix)]>"
    }

    override public func unwrap() -> any Sendable {
        storage.withLock { entries in
            var result: [String: any Sendable] = [:]
            for (key, value) in entries {
                result[key] = value.unwrap()
            }
            return result
        }
    }
}
