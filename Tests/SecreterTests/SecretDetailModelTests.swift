import Foundation
import KeyVaultSecrets
import Testing

@testable import Secreter

@MainActor
@Suite struct SecretDetailModelTests {
    private func bundle(_ value: String) -> SecretBundle {
        let json = ["id": "https://v.vault.azure.net/secrets/s", "value": value]
        return try! JSONDecoder().decode(SecretBundle.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func loaded(_ value: String, remask: TimeInterval = 20, copied: @escaping (String) -> Void = { _ in })
        async -> SecretDetailModel
    {
        let cache = SecretValueCache()
        let m = SecretDetailModel(cache: cache, remaskSeconds: { remask }, writePasteboard: copied)
        // Seed through the cache path: vault is required, so use the test hook.
        m.setBundleForTesting(bundle(value))
        return m
    }

    @Test func prettyJSON() {
        #expect(SecretDetailModel.prettyJSON(#"{"b":1,"a":[true]}"#)?.contains("\n  \"a\"") == true)
        #expect(SecretDetailModel.prettyJSON("plain") == nil)
        #expect(SecretDetailModel.prettyJSON("{broken") == nil)
        #expect(SecretDetailModel.prettyJSON("123") == nil)
    }

    @Test func revealThenManualMask() async {
        let m = await loaded("v")
        #expect(!m.isRevealed)
        m.toggleReveal()
        #expect(m.isRevealed)
        m.toggleReveal()
        #expect(!m.isRevealed)
    }

    @Test func autoRemask() async throws {
        let m = await loaded("v")
        m.remaskSeconds = { 0.01 }
        m.reveal()
        #expect(m.isRevealed)
        try await Task.sleep(for: .seconds(1.3))  // minimum re-mask is 1 s
        #expect(!m.isRevealed)
    }

    @Test func copyWritesValueAndShowsToast() async {
        var copied: String?
        let m = await loaded("s3cret") { copied = $0 }
        m.copy()
        #expect(copied == "s3cret")
        #expect(m.showCopiedToast)
    }

    @Test func clearDropsValueAndCache() async {
        let m = await loaded("v")
        m.reveal()
        m.clear()
        #expect(m.value == nil)
        #expect(!m.isRevealed)
    }

    @Test func formatJSONToggle() async {
        let m = await loaded(#"{"a":1}"#)
        #expect(m.isJSON)
        #expect(m.displayValue == #"{"a":1}"#)
        m.formatJSON = true
        #expect(m.displayValue.contains("\n"))
    }
}
