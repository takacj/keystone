import Foundation

/// In-memory LRU of fetched secret bundles (values included). Never persisted or logged.
/// Clear on context switch and on lock.
public final class SecretValueCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let vault: String
        public let name: String
        public let version: String?

        public init(vault: String, name: String, version: String? = nil) {
            self.vault = vault
            self.name = name
            self.version = version
        }
    }

    public static let shared = SecretValueCache()

    public let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: SecretBundle] = [:]
    private var order: [Key] = []  // least recently used first

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { lock.withLock { entries.count } }

    public func get(_ key: Key) -> SecretBundle? {
        lock.withLock {
            guard let hit = entries[key] else { return nil }
            touch(key)
            return hit
        }
    }

    public func set(_ key: Key, _ bundle: SecretBundle) {
        lock.withLock {
            entries[key] = bundle
            touch(key)
            while order.count > capacity { entries[order.removeFirst()] = nil }
        }
    }

    public func remove(_ key: Key) {
        lock.withLock {
            entries[key] = nil
            order.removeAll { $0 == key }
        }
    }

    public func clear() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
