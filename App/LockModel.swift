import AppKit
import Foundation
import KeyVaultSecrets
import LocalAuthentication
import Observation

/// Abstraction over LocalAuthentication so tests never prompt.
protocol Authenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

struct LocalAuthenticator: Authenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Never succeeds; lets `-UITestLock` keep the lock screen on screen.
struct PendingAuthenticator: Authenticating {
    func authenticate(reason: String) async -> Bool {
        try? await Task.sleep(for: .seconds(3600))
        return false
    }
}

extension LockModel {
    /// Lock model for the app: real Touch ID, or (`-UITestLock`) enabled with an authenticator that never succeeds.
    static func makeDefault() -> LockModel {
        if UITestSupport.hasFlag("-UITestLock") {
            return LockModel(enabled: true, authenticator: PendingAuthenticator())
        }
        return LockModel()
    }
}

/// App lock: locks on launch, idle, sleep/screen lock and ⌘L; unlocks via Touch ID / password.
@MainActor @Observable
final class LockModel {
    static let idleMinutesKey = "lockIdleMinutes"
    static let defaultIdleMinutes = 10
    static let uiTestArgument = "-UITestMode"

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Bumped on every lock; views observe it to drop in-memory secret state.
    private(set) var lockGeneration = 0

    let isEnabled: Bool
    @ObservationIgnored private let authenticator: any Authenticating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let clearCache: () -> Void
    @ObservationIgnored private var lastActivity: Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var eventMonitor: Any?

    static var disabledByEnvironment: Bool {
        let info = ProcessInfo.processInfo
        return info.arguments.contains(uiTestArgument)
            || info.environment["XCTestConfigurationFilePath"] != nil
    }

    init(
        enabled: Bool = !LockModel.disabledByEnvironment,
        authenticator: any Authenticating = LocalAuthenticator(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        clearCache: @escaping () -> Void = { SecretValueCache.shared.clear() }
    ) {
        self.isEnabled = enabled
        self.authenticator = authenticator
        self.defaults = defaults
        self.now = now
        self.clearCache = clearCache
        self.lastActivity = now()
        self.isLocked = enabled
    }

    var idleMinutes: Int {
        let value = defaults.integer(forKey: Self.idleMinutesKey)
        return value > 0 ? value : Self.defaultIdleMinutes
    }

    // MARK: Lock / unlock

    func lock() {
        guard isEnabled else { return }
        clearCache()
        lockGeneration += 1
        isLocked = true
    }

    func unlock() async {
        guard isEnabled, isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        let success = await authenticator.authenticate(reason: "Unlock Secreter")
        isAuthenticating = false
        if success {
            isLocked = false
            lastActivity = now()
        }
    }

    // MARK: Idle

    func noteActivity() {
        if !isLocked { lastActivity = now() }
    }

    /// Locks if idle time exceeded. Called by the timer; exposed for tests.
    func checkIdle() {
        guard isEnabled, !isLocked else { return }
        if now().timeIntervalSince(lastActivity) >= Double(idleMinutes) * 60 { lock() }
    }

    // MARK: Monitoring

    func startMonitoring() {
        guard isEnabled, timer == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        observers.append(
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        observers.append(
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        observers.append(
            dist.addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } })
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.noteActivity() }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        let workspace = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        for observer in observers {
            workspace.removeObserver(observer)
            dist.removeObserver(observer)
        }
        observers = []
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}
