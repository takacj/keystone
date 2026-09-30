import Foundation

/// Pure production-context detector (plan §7). Case-insensitive token-prefix match of each pattern
/// (names split on non-alphanumerics; a token matches if it equals or starts with the pattern: `kv-production` matches `prod`, `delivery` doesn't match `live`) against the subscription display name and the vault name.
struct ProdGuard: Equatable {
    static let defaultsKey = "prodPatterns"
    static let defaultPatterns = ["prod", "prd", "live"]

    let patterns: [String]

    init(patterns: [String] = ProdGuard.defaultPatterns) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Patterns from `UserDefaults` key `prodPatterns` ([String]); defaults when unset.
    static func current(defaults: UserDefaults = .standard) -> ProdGuard {
        ProdGuard(patterns: defaults.stringArray(forKey: defaultsKey) ?? defaultPatterns)
    }

    func matches(_ name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        let all = Self.tokens(name)
        return patterns.contains { pattern in
            let parts = Self.tokens(pattern)
            guard !parts.isEmpty, all.count >= parts.count else { return false }
            // Consecutive tokens; all but the last must equal, the last may merely start with its part.
            return (0...(all.count - parts.count)).contains { start in
                parts.indices.allSatisfy { i in
                    let t = all[start + i]
                    return i == parts.count - 1 ? t.hasPrefix(parts[i]) : t == parts[i]
                }
            }
        }
    }

    static func tokens(_ s: String) -> [String] {
        s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    func isProduction(subscriptionName: String?, vaultName: String?) -> Bool {
        matches(subscriptionName) || matches(vaultName)
    }
}

extension ContextModel {
    /// True when the selected subscription or vault matches a prod pattern.
    var isProduction: Bool {
        ProdGuard.current().isProduction(
            subscriptionName: selectedSubscription?.displayName, vaultName: selectedVault?.name)
    }
}
