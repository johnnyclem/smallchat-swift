import SmallChatCore

/// Process-wide id sequence for one kind of transport (`http-1`, `http-2`, ...).
///
/// Transports are created from arbitrary tasks, so the counter is lock-protected:
/// concurrent initializers always get distinct ids.
struct TransportIDSequence: Sendable {
    let prefix: String
    private let counter = PlatformLock(initialState: 0)

    init(prefix: String) {
        self.prefix = prefix
    }

    func next() -> String {
        let n = counter.withLock { value in
            value += 1
            return value
        }
        return "\(prefix)-\(n)"
    }
}
