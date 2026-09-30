import Foundation
import Testing

@testable import Keystone

struct PolishTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func expiryStatusClassifiesDates() {
        #expect(ExpiryStatus.of(nil, now: now) == .none)
        #expect(ExpiryStatus.of(now.addingTimeInterval(-60), now: now) == .expired)
        #expect(ExpiryStatus.of(now.addingTimeInterval(5 * 86400), now: now) == .soon(days: 5))
        #expect(ExpiryStatus.of(now.addingTimeInterval(3600), now: now) == .soon(days: 1))
        #expect(ExpiryStatus.of(now.addingTimeInterval(31 * 86400), now: now) == .ok)
    }

    @Test func quickSwitchFiltersByTitle() {
        let items = [
            QuickSwitchItem(id: "1", title: "Prod-001", isCurrent: true),
            QuickSwitchItem(id: "2", title: "Dev-002", isCurrent: false),
        ]
        #expect(QuickSwitchItem.filter(items, query: "  ").count == 2)
        #expect(QuickSwitchItem.filter(items, query: "prod").map(\.id) == ["1"])
        #expect(QuickSwitchItem.filter(items, query: "zzz").isEmpty)
    }

    @MainActor @Test func viewRequestsIncrement() {
        let r = ViewRequests()
        r.requestDelete()
        r.requestDelete()
        r.requestFocusFilter()
        #expect(r.deleteSelected == 2)
        #expect(r.focusFilter == 1)
        #expect(r.showVersions == 0)
    }
}
