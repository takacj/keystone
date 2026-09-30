import Foundation
import KeyVaultSecrets
import Testing

@testable import Keystone

@MainActor
@Suite struct SecretsModelTests {
    private func item(_ name: String, enabled: Bool = true, exp: Date? = nil, tags: [String: String]? = nil)
        -> SecretItem
    {
        var attrs: [String: Any] = ["enabled": enabled]
        if let exp { attrs["exp"] = Int(exp.timeIntervalSince1970) }
        let json: [String: Any] = [
            "id": "https://v.vault.azure.net/secrets/\(name)", "attributes": attrs, "tags": tags ?? [:],
        ]
        return try! JSONDecoder().decode(SecretItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func model(_ items: [SecretItem]) -> SecretsModel {
        let m = SecretsModel()
        m.setRowsForTesting(items.map(SecretRow.init))
        return m
    }

    @Test func fuzzyFilterHighlights() {
        let m = model([item("api-key"), item("db-conn"), item("jwt")])
        m.filterText = "dbc"
        #expect(m.visible.map(\.name) == ["db-conn"])
        #expect(m.highlights["db-conn"] == [0..<2, 3..<4])
    }

    @Test func chips() {
        let now = Date()
        let m = model([
            item("on"), item("off", enabled: false),
            item("soon", exp: now.addingTimeInterval(5 * 86400)),
            item("old", exp: now.addingTimeInterval(-86400)),
            item("tagged", tags: ["env": "prod"]),
        ])
        m.toggle(.disabled)
        #expect(m.visible.map(\.name) == ["off"])
        m.toggle(.enabled)  // exclusive with disabled
        #expect(!m.chips.contains(.disabled))
        m.clearFilters()
        m.toggle(.expiring)
        #expect(m.visible.map(\.name) == ["soon"])
        m.toggle(.expired)
        #expect(m.visible.map(\.name) == ["old"])
        m.clearFilters()
        m.tagFilter = "env=prod"
        #expect(m.visible.map(\.name) == ["tagged"])
    }

    @Test func sortAndSelectedNames() {
        let m = model([item("b"), item("a"), item("c")])
        #expect(m.visible.map(\.name) == ["a", "b", "c"])
        m.sortOrder = [KeyPathComparator(\.name, order: .reverse)]
        #expect(m.visible.map(\.name) == ["c", "b", "a"])
        m.selection = ["a", "c"]
        #expect(m.selectedNames() == ["c", "a"])
    }
}
