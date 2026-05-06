import Foundation
import OrderedCollections

/// CachedView -- a resolved view entry stored in `ViewCache`.
public struct CachedView: Sendable {
    public let appId: String
    public let uri: String
    public let content: String
    public let appVersion: String?
    public let contentFingerprint: String?
    public internal(set) var hitCount: Int

    public init(
        appId: String,
        uri: String,
        content: String,
        appVersion: String? = nil,
        contentFingerprint: String? = nil
    ) {
        self.appId = appId
        self.uri = uri
        self.content = content
        self.appVersion = appVersion
        self.contentFingerprint = contentFingerprint
        self.hitCount = 1
    }
}

/// ViewCache -- LRU cache for resolved App views.
///
/// Parallel to `ResolutionCache` but for the App/UI layer.
/// Entries are tagged with `appVersion` and `contentFingerprint` at store-time.
/// On lookup, stale entries (version mismatch) are evicted transparently so the
/// caller sees a cache miss and re-resolves.
public actor ViewCache {
    private var cache: OrderedDictionary<String, CachedView>
    private let maxSize: Int
    private var appVersions: [String: String] = [:]     // appId → current version
    private var contentFingerprints: [String: String] = [:]  // appId → fingerprint

    public init(maxSize: Int = 512) {
        self.cache = OrderedDictionary()
        self.maxSize = maxSize
    }

    // MARK: - Lookup & Store

    /// Hot path. Returns `nil` on cache miss or stale entry.
    public func lookup(_ selector: ComponentSelector) -> CachedView? {
        let key = selector.canonical
        guard var cached = cache[key] else { return nil }

        // Stale check: app version
        if let cv = cached.appVersion,
           let current = appVersions[cached.appId],
           cv != current {
            cache.removeValue(forKey: key)
            return nil
        }

        // Stale check: content fingerprint
        if let cf = cached.contentFingerprint,
           let current = contentFingerprints[cached.appId],
           cf != current {
            cache.removeValue(forKey: key)
            return nil
        }

        // Promote to MRU end
        cache.removeValue(forKey: key)
        cached.hitCount += 1
        cache[key] = cached
        return cached
    }

    /// Store a resolved view. Evicts the LRU entry when at capacity.
    public func store(_ selector: ComponentSelector, view: CachedView) {
        let key = selector.canonical
        if cache.count >= maxSize && cache[key] == nil {
            cache.removeFirst()
        }
        cache[key] = view
    }

    // MARK: - Invalidation

    /// Flush all entries.
    public func flush() {
        cache.removeAll()
    }

    /// Remove all cached entries for a specific app.
    public func flushApp(_ appId: String) {
        cache = cache.filter { $0.value.appId != appId }
    }

    // MARK: - Version Management

    /// Set the current version for an app. Stale entries auto-expire on next lookup.
    public func setAppVersion(_ appId: String, _ version: String) {
        appVersions[appId] = version
    }

    /// Set the content fingerprint for an app. Stale entries auto-expire on next lookup.
    public func setContentFingerprint(_ appId: String, _ fingerprint: String) {
        contentFingerprints[appId] = fingerprint
    }

    public var size: Int { cache.count }
}
