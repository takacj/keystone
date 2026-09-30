import Foundation

/// UserDefaults-backed settings helpers shared by the Settings scene (plan §6.4).
enum SettingsDefaults {
    static let defaultLockIdleMinutes = 10
    static let defaultRemaskSeconds = 20

    /// Normalizes a pattern list: trims, lowercases, drops empties and duplicates (order kept).
    static func normalizedPatterns(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func patterns(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: ProdGuard.defaultsKey) ?? ProdGuard.defaultPatterns
    }

    static func setPatterns(_ patterns: [String], defaults: UserDefaults = .standard) {
        defaults.set(normalizedPatterns(patterns), forKey: ProdGuard.defaultsKey)
    }

    static func resetPatterns(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ProdGuard.defaultsKey)
    }
}
