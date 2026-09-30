import Foundation
import Testing

@testable import Secreter

private struct FakeAuth: Authenticating {
    let result: Bool
    func authenticate(reason: String) async -> Bool { result }
}

@MainActor
struct LockModelTests {
    private func make(
        enabled: Bool = true, succeeds: Bool = true, clock: Clock = Clock(), cleared: Counter = Counter()
    ) -> LockModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return LockModel(
            enabled: enabled, authenticator: FakeAuth(result: succeeds), defaults: defaults,
            now: { clock.date }, clearCache: { cleared.count += 1 })
    }

    final class Clock { var date = Date(timeIntervalSince1970: 0) }
    final class Counter { var count = 0 }

    @Test func startsLockedWhenEnabled() {
        #expect(make().isLocked)
        #expect(!make(enabled: false).isLocked)
    }

    @Test func unlockSucceeds() async {
        let model = make()
        await model.unlock()
        #expect(!model.isLocked)
    }

    @Test func unlockFailureStaysLocked() async {
        let model = make(succeeds: false)
        await model.unlock()
        #expect(model.isLocked)
    }

    @Test func lockClearsCacheAndBumpsGeneration() async {
        let cleared = Counter()
        let model = make(cleared: cleared)
        await model.unlock()
        model.lock()
        #expect(model.isLocked && cleared.count == 1 && model.lockGeneration == 1)
    }

    @Test func disabledNeverLocks() {
        let model = make(enabled: false)
        model.lock()
        #expect(!model.isLocked && model.lockGeneration == 0)
    }

    @Test func idleLocksAfterTimeout() async {
        let clock = Clock()
        let model = make(clock: clock)
        await model.unlock()
        clock.date = Date(timeIntervalSince1970: 9 * 60)
        model.checkIdle()
        #expect(!model.isLocked)
        clock.date = Date(timeIntervalSince1970: 10 * 60)
        model.checkIdle()
        #expect(model.isLocked)
    }

    @Test func activityResetsIdle() async {
        let clock = Clock()
        let model = make(clock: clock)
        await model.unlock()
        clock.date = Date(timeIntervalSince1970: 9 * 60)
        model.noteActivity()
        clock.date = Date(timeIntervalSince1970: 15 * 60)
        model.checkIdle()
        #expect(!model.isLocked)
    }
}
