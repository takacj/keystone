import Foundation

/// Last selection plus favorites/recents for one account. Contains no secrets, only ids.
public struct AccountContextState: Codable, Sendable, Equatable {
    public var tenantId: String?
    public var subscriptionId: String?
    /// ARM resource id of the last selected vault.
    public var vaultId: String?
    /// ARM resource ids, in the order the user favorited them.
    public var favorites: [String]
    /// ARM resource ids, most recent first.
    public var recents: [String]

    public init(
        tenantId: String? = nil, subscriptionId: String? = nil, vaultId: String? = nil,
        favorites: [String] = [], recents: [String] = []
    ) {
        self.tenantId = tenantId
        self.subscriptionId = subscriptionId
        self.vaultId = vaultId
        self.favorites = favorites
        self.recents = recents
    }
}

/// JSON file (default: `~/Library/Application Support/Secreter/context.json`) keyed by account id.
public struct ContextStateStore: Sendable {
    public static let maxRecents = 10

    public let fileURL: URL

    public init(fileURL: URL = ContextStateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Secreter", isDirectory: true)
            .appendingPathComponent("context.json")
    }

    public func load(accountID: UUID) -> AccountContextState {
        readAll()[accountID.uuidString] ?? AccountContextState()
    }

    public func save(_ state: AccountContextState, accountID: UUID) {
        var all = readAll()
        all[accountID.uuidString] = state
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func remove(accountID: UUID) {
        var all = readAll()
        guard all.removeValue(forKey: accountID.uuidString) != nil,
            let data = try? JSONEncoder().encode(all)
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func readAll() -> [String: AccountContextState] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: AccountContextState].self, from: data)) ?? [:]
    }
}
