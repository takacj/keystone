import Foundation
import Testing

@testable import KeyVaultSecrets

@Suite struct SecretValueCacheTests {
    private func bundle(_ name: String) -> SecretBundle {
        try! JSONDecoder().decode(
            SecretBundle.self, from: Data(#"{"id":"https://v.vault.azure.net/secrets/\#(name)","value":"x"}"#.utf8))
    }

    private func key(_ name: String) -> SecretValueCache.Key { .init(vault: "v", name: name) }

    @Test func evictsLeastRecentlyUsed() {
        let c = SecretValueCache(capacity: 2)
        c.set(key("a"), bundle("a"))
        c.set(key("b"), bundle("b"))
        _ = c.get(key("a"))  // a is now most recent
        c.set(key("c"), bundle("c"))
        #expect(c.get(key("b")) == nil)
        #expect(c.get(key("a")) != nil)
        #expect(c.get(key("c")) != nil)
        #expect(c.count == 2)
    }

    @Test func clearAndRemove() {
        let c = SecretValueCache()
        c.set(key("a"), bundle("a"))
        c.set(key("b"), bundle("b"))
        c.remove(key("a"))
        #expect(c.get(key("a")) == nil)
        c.clear()
        #expect(c.count == 0)
    }
}
