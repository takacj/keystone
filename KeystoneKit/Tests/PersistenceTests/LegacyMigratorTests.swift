import Foundation
import Testing

@testable import Persistence

@Suite struct LegacyMigratorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "keystone-migrator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func suite() -> UserDefaults {
        let name = "keystone-migrator-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func movesLegacyDirectory() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Secreter")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appendingPathComponent("accounts.json"))
        let migrator = LegacyMigrator(applicationSupport: root, defaults: suite(), legacyDefaults: { nil })
        #expect(migrator.migrateDirectory())
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Keystone/accounts.json").path))
    }

    @Test func keepsExistingNewDirectory() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Secreter", "Keystone"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let migrator = LegacyMigrator(applicationSupport: root, defaults: suite(), legacyDefaults: { nil })
        #expect(!migrator.migrateDirectory())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Secreter").path))
    }

    @Test func noopWithoutLegacyDirectory() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let migrator = LegacyMigrator(applicationSupport: root, defaults: suite(), legacyDefaults: { nil })
        #expect(!migrator.migrateDirectory())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Keystone").path))
    }

    @Test func copiesDefaultsOnceWithoutOverwriting() {
        let defaults = suite()
        defaults.set(5, forKey: "kept")
        let legacy: [String: Any] = ["kept": 1, "prodPatterns": ["prod"]]
        let migrator = LegacyMigrator(defaults: defaults, legacyDefaults: { legacy })
        #expect(migrator.migrateDefaults())
        #expect(defaults.integer(forKey: "kept") == 5)
        #expect(defaults.stringArray(forKey: "prodPatterns") == ["prod"])
        defaults.removeObject(forKey: "prodPatterns")
        #expect(!migrator.migrateDefaults())
        #expect(defaults.object(forKey: "prodPatterns") == nil)
    }
}
