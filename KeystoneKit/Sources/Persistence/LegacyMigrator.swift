import Foundation

/// One-time migration of user data from the app's former name ("Secreter") to "Keystone".
public struct LegacyMigrator {
    static let legacyDirectoryName = "Secreter"
    static let legacyDefaultsDomain = "com.jtakac.secreter"
    public static let migratedFlagKey = "legacyDefaultsMigrated"

    private let fileManager: FileManager
    private let applicationSupport: URL
    private let defaults: UserDefaults
    private let legacyDefaults: () -> [String: Any]?

    public init(
        fileManager: FileManager = .default,
        applicationSupport: URL? = nil,
        defaults: UserDefaults = .standard,
        legacyDefaults: (() -> [String: Any]?)? = nil
    ) {
        self.fileManager = fileManager
        self.applicationSupport =
            applicationSupport ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.defaults = defaults
        self.legacyDefaults =
            legacyDefaults ?? { UserDefaults.standard.persistentDomain(forName: Self.legacyDefaultsDomain) }
    }

    /// Runs both migrations. Call before anything reads storage.
    public func run() {
        migrateDirectory()
        migrateDefaults()
    }

    /// Moves `Application Support/Secreter` to `Application Support/Keystone` when only the old one exists.
    @discardableResult
    public func migrateDirectory() -> Bool {
        let old = applicationSupport.appendingPathComponent(Self.legacyDirectoryName, isDirectory: true)
        let new = applicationSupport.appendingPathComponent("Keystone", isDirectory: true)
        guard !fileManager.fileExists(atPath: new.path), fileManager.fileExists(atPath: old.path) else { return false }
        do {
            try fileManager.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }

    /// Copies keys from the legacy defaults domain that are not yet set; runs once (flag).
    @discardableResult
    public func migrateDefaults() -> Bool {
        guard !defaults.bool(forKey: Self.migratedFlagKey) else { return false }
        if let old = legacyDefaults() {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: Self.migratedFlagKey)
        return true
    }
}
