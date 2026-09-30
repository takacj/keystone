import Foundation

/// A signed-in Azure account with its own isolated `AZURE_CONFIG_DIR`.
public struct AccountProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public var displayName: String
    public var upn: String
    public var homeTenantId: String
    public var profileDir: URL

    public init(id: UUID, displayName: String, upn: String, homeTenantId: String, profileDir: URL) {
        self.id = id
        self.displayName = displayName
        self.upn = upn
        self.homeTenantId = homeTenantId
        self.profileDir = profileDir
    }
}

/// Options for `az login`.
public struct AccountLoginOptions: Sendable, Equatable {
    public var useDeviceCode: Bool
    public var tenant: String?

    public init(useDeviceCode: Bool = false, tenant: String? = nil) {
        self.useDeviceCode = useDeviceCode
        self.tenant = tenant
    }

    var arguments: [String] {
        var args = ["login", "-o", "json"]
        if useDeviceCode { args.append("--use-device-code") }
        if let tenant, !tenant.isEmpty { args += ["--tenant", tenant] }
        return args
    }
}

public enum ProfileStoreError: Error, Equatable, LocalizedError {
    case accountNotFound(UUID)
    case invalidAccountInfo(String)
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accountNotFound(let id): "Account \(id) not found."
        case .invalidAccountInfo(let m): "Could not read account info from az: \(m)"
        case .storageFailed(let m): "Could not save accounts: \(m)"
        }
    }
}

/// Result of `az account show`, reduced to what Secreter needs.
struct AzureAccountInfo: Equatable {
    let upn: String
    let homeTenantId: String

    static func parse(_ json: String) throws -> AzureAccountInfo {
        struct Raw: Decodable {
            struct User: Decodable { let name: String? }
            let user: User?
            let tenantId: String?
            let homeTenantId: String?
        }
        guard let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw ProfileStoreError.invalidAccountInfo("invalid JSON")
        }
        guard let upn = raw.user?.name, !upn.isEmpty else {
            throw ProfileStoreError.invalidAccountInfo("missing user.name")
        }
        guard let tenant = raw.homeTenantId ?? raw.tenantId, !tenant.isEmpty else {
            throw ProfileStoreError.invalidAccountInfo("missing tenant")
        }
        return AzureAccountInfo(upn: upn, homeTenantId: tenant)
    }
}
