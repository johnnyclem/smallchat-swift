import Foundation

public final class SCArray: SCObject, @unchecked Sendable {
    private static let registered: Bool = {
        SCObjectRegistry.shared.register("SCArray", superclass: "SCObject")
        return true
    }()

    private let storage: OSAllocatedUnfairLock<[SCObject]>

    override public var isa: String { "SCArray" }

    public init(items: [SCObject] = []) {
        self.storage = OSAllocatedUnfairLock(initialState: items)
        super.init()
        _ = Self.registered
    }

    public var count: Int { storage.withLock { $0.count } }

    public func objectAtIndex(_ index: Int) -> SCObject? {
        storage.withLock { items in
            items.indices.contains(index) ? items[index] : nil
        }
    }

    public func addObject(_ obj: SCObject) {
        storage.withLock { $0.append(obj) }
    }

    public func allObjects() -> [SCObject] {
        storage.withLock { $0 }
    }

    override public var description: String {
        "<SCArray id=\(id) count=\(count)>"
    }

    override public func unwrap() -> any Sendable {
        storage.withLock { items in
            items.map { $0.unwrap() } as [any Sendable]
        }
    }
}
