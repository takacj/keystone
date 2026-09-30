import Foundation

/// Secret attributes; dates travel as Unix epoch seconds on the wire.
public struct SecretAttributes: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var notBefore: Date?
    public var expires: Date?
    public var created: Date?
    public var updated: Date?
    public var recoveryLevel: String?
    public var recoverableDays: Int?

    public init(
        enabled: Bool? = nil, notBefore: Date? = nil, expires: Date? = nil,
        created: Date? = nil, updated: Date? = nil,
        recoveryLevel: String? = nil, recoverableDays: Int? = nil
    ) {
        self.enabled = enabled
        self.notBefore = notBefore
        self.expires = expires
        self.created = created
        self.updated = updated
        self.recoveryLevel = recoveryLevel
        self.recoverableDays = recoverableDays
    }

    enum CodingKeys: String, CodingKey {
        case enabled, recoveryLevel, recoverableDays, created, updated
        case notBefore = "nbf"
        case expires = "exp"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ k: CodingKeys) throws -> Date? {
            try c.decodeIfPresent(Double.self, forKey: k).map { Date(timeIntervalSince1970: $0) }
        }
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        notBefore = try date(.notBefore)
        expires = try date(.expires)
        created = try date(.created)
        updated = try date(.updated)
        recoveryLevel = try c.decodeIfPresent(String.self, forKey: .recoveryLevel)
        recoverableDays = try c.decodeIfPresent(Int.self, forKey: .recoverableDays)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(notBefore.map { Int($0.timeIntervalSince1970) }, forKey: .notBefore)
        try c.encodeIfPresent(expires.map { Int($0.timeIntervalSince1970) }, forKey: .expires)
        // created/updated/recovery* are server-managed; never sent.
    }
}

/// List item (metadata only, no value).
public struct SecretItem: Codable, Sendable, Equatable, Identifiable {
    /// Full secret identifier URL, e.g. `https://v.vault.azure.net/secrets/name[/version]`.
    public let id: String
    public var attributes: SecretAttributes?
    public var tags: [String: String]?
    public var contentType: String?
    public var managed: Bool?

    public var name: String { SecretID.parse(id)?.name ?? id }
    public var version: String? { SecretID.parse(id)?.version }
}

/// Secret with value. `Debug`/`description` never include the value.
public struct SecretBundle: Codable, Sendable, Equatable, Identifiable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let id: String
    public var value: String?
    public var contentType: String?
    public var attributes: SecretAttributes?
    public var tags: [String: String]?
    public var kid: String?
    public var managed: Bool?

    public var name: String { SecretID.parse(id)?.name ?? id }
    public var version: String? { SecretID.parse(id)?.version }
    public var description: String { "SecretBundle(id: \(id), value: <redacted>)" }
    public var debugDescription: String { description }
}

/// Deleted-secret list item.
public struct DeletedSecretItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var recoveryId: String?
    public var attributes: SecretAttributes?
    public var tags: [String: String]?
    public var contentType: String?
    public var managed: Bool?
    public var scheduledPurgeDate: Date?
    public var deletedDate: Date?

    public var name: String { SecretID.parse(id)?.name ?? id }

    enum CodingKeys: String, CodingKey {
        case id, recoveryId, attributes, tags, contentType, managed, scheduledPurgeDate, deletedDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        recoveryId = try c.decodeIfPresent(String.self, forKey: .recoveryId)
        attributes = try c.decodeIfPresent(SecretAttributes.self, forKey: .attributes)
        tags = try c.decodeIfPresent([String: String].self, forKey: .tags)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed)
        scheduledPurgeDate = try c.decodeIfPresent(Double.self, forKey: .scheduledPurgeDate)
            .map { Date(timeIntervalSince1970: $0) }
        deletedDate = try c.decodeIfPresent(Double.self, forKey: .deletedDate)
            .map { Date(timeIntervalSince1970: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(recoveryId, forKey: .recoveryId)
        try c.encodeIfPresent(attributes, forKey: .attributes)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(managed, forKey: .managed)
        try c.encodeIfPresent(scheduledPurgeDate?.timeIntervalSince1970, forKey: .scheduledPurgeDate)
        try c.encodeIfPresent(deletedDate?.timeIntervalSince1970, forKey: .deletedDate)
    }
}

/// Response of DELETE /secrets/{name}: the deleted secret including its value.
public struct DeletedSecretBundle: Codable, Sendable, Equatable, CustomStringConvertible {
    public let id: String
    public var value: String?
    public var contentType: String?
    public var attributes: SecretAttributes?
    public var tags: [String: String]?
    public var recoveryId: String?
    public var scheduledPurgeDate: Date?
    public var deletedDate: Date?

    public var description: String { "DeletedSecretBundle(id: \(id), value: <redacted>)" }

    enum CodingKeys: String, CodingKey {
        case id, value, contentType, attributes, tags, recoveryId, scheduledPurgeDate, deletedDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        attributes = try c.decodeIfPresent(SecretAttributes.self, forKey: .attributes)
        tags = try c.decodeIfPresent([String: String].self, forKey: .tags)
        recoveryId = try c.decodeIfPresent(String.self, forKey: .recoveryId)
        scheduledPurgeDate = try c.decodeIfPresent(Double.self, forKey: .scheduledPurgeDate)
            .map { Date(timeIntervalSince1970: $0) }
        deletedDate = try c.decodeIfPresent(Double.self, forKey: .deletedDate)
            .map { Date(timeIntervalSince1970: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(attributes, forKey: .attributes)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(recoveryId, forKey: .recoveryId)
        try c.encodeIfPresent(scheduledPurgeDate?.timeIntervalSince1970, forKey: .scheduledPurgeDate)
        try c.encodeIfPresent(deletedDate?.timeIntervalSince1970, forKey: .deletedDate)
    }
}

/// Request body for PUT /secrets/{name}.
public struct SetSecretRequest: Encodable, Sendable {
    public var value: String
    public var contentType: String?
    public var tags: [String: String]?
    public var attributes: SecretAttributes?

    public init(
        value: String, contentType: String? = nil, tags: [String: String]? = nil,
        attributes: SecretAttributes? = nil
    ) {
        self.value = value
        self.contentType = contentType
        self.tags = tags
        self.attributes = attributes
    }
}

/// Request body for PATCH /secrets/{name}/{version}. `nil` fields are left unchanged.
public struct UpdateSecretRequest: Encodable, Sendable {
    public var contentType: String?
    public var tags: [String: String]?
    public var attributes: SecretAttributes?

    public init(
        contentType: String? = nil, tags: [String: String]? = nil, attributes: SecretAttributes? = nil
    ) {
        self.contentType = contentType
        self.tags = tags
        self.attributes = attributes
    }
}

/// Parsed secret identifier URL.
public enum SecretID {
    public static func parse(_ id: String) -> (name: String, version: String?)? {
        guard let url = URL(string: id) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "secrets" || parts[0] == "deletedsecrets" else { return nil }
        return (parts[1], parts.count > 2 ? parts[2] : nil)
    }
}
