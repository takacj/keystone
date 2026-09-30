import Foundation

public struct Tenant: Sendable, Hashable, Identifiable, Decodable {
    public let tenantId: String
    public let displayName: String?
    public let defaultDomain: String?
    public var id: String { tenantId }

    public init(tenantId: String, displayName: String? = nil, defaultDomain: String? = nil) {
        self.tenantId = tenantId
        self.displayName = displayName
        self.defaultDomain = defaultDomain
    }
}

public struct Subscription: Sendable, Hashable, Identifiable, Decodable {
    public let subscriptionId: String
    public let displayName: String
    public let state: String?
    public let tenantId: String?
    public var id: String { subscriptionId }

    public init(subscriptionId: String, displayName: String, state: String? = nil, tenantId: String? = nil) {
        self.subscriptionId = subscriptionId
        self.displayName = displayName
        self.state = state
        self.tenantId = tenantId
    }
}

public struct Vault: Sendable, Hashable, Identifiable, Decodable {
    /// Full ARM resource id.
    public let id: String
    public let name: String
    public let location: String
    public let resourceGroup: String
    public let subscriptionId: String
    public let vaultUri: URL
    public let tenantId: String?
    public let enableRbacAuthorization: Bool
    /// Absent in ARM responses means soft-delete is on (enforced platform-wide).
    public let enableSoftDelete: Bool
    public let enablePurgeProtection: Bool
    public let softDeleteRetentionInDays: Int?

    public init(
        id: String, name: String, location: String, resourceGroup: String, subscriptionId: String,
        vaultUri: URL, tenantId: String? = nil, enableRbacAuthorization: Bool = false,
        enableSoftDelete: Bool = true, enablePurgeProtection: Bool = false,
        softDeleteRetentionInDays: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.resourceGroup = resourceGroup
        self.subscriptionId = subscriptionId
        self.vaultUri = vaultUri
        self.tenantId = tenantId
        self.enableRbacAuthorization = enableRbacAuthorization
        self.enableSoftDelete = enableSoftDelete
        self.enablePurgeProtection = enablePurgeProtection
        self.softDeleteRetentionInDays = softDeleteRetentionInDays
    }

    private enum CodingKeys: String, CodingKey { case id, name, location, properties }
    private struct Properties: Decodable {
        let vaultUri: String?
        let tenantId: String?
        let enableRbacAuthorization: Bool?
        let enableSoftDelete: Bool?
        let enablePurgeProtection: Bool?
        let softDeleteRetentionInDays: Int?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let p = try c.decode(Properties.self, forKey: .properties)
        guard let uriString = p.vaultUri, let uri = URL(string: uriString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .properties, in: c, debugDescription: "missing or invalid vaultUri")
        }
        self.init(
            id: id, name: name,
            location: try c.decodeIfPresent(String.self, forKey: .location) ?? "",
            resourceGroup: Self.segment("resourceGroups", in: id) ?? "",
            subscriptionId: Self.segment("subscriptions", in: id) ?? "",
            vaultUri: uri, tenantId: p.tenantId,
            enableRbacAuthorization: p.enableRbacAuthorization ?? false,
            enableSoftDelete: p.enableSoftDelete ?? true,
            enablePurgeProtection: p.enablePurgeProtection ?? false,
            softDeleteRetentionInDays: p.softDeleteRetentionInDays)
    }

    /// Value following `key` (case-insensitive) in an ARM resource id.
    static func segment(_ key: String, in id: String) -> String? {
        let parts = id.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
            i + 1 < parts.count
        else { return nil }
        return parts[i + 1]
    }
}
