import Foundation
import Testing

@testable import Persistence

@Test func contextStateRoundTripsPerAccount() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("context.json")
    let store = ContextStateStore(fileURL: url)
    let a = UUID()
    let b = UUID()
    #expect(store.load(accountID: a) == AccountContextState())
    let state = AccountContextState(
        tenantId: "t", subscriptionId: "s", vaultId: "v", favorites: ["f"], recents: ["r1", "r2"])
    store.save(state, accountID: a)
    #expect(store.load(accountID: a) == state)
    #expect(store.load(accountID: b) == AccountContextState())
    store.remove(accountID: a)
    #expect(store.load(accountID: a) == AccountContextState())
}

@Test func contextStateIgnoresCorruptFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    try Data("nope".utf8).write(to: url)
    #expect(ContextStateStore(fileURL: url).load(accountID: UUID()) == AccountContextState())
}
