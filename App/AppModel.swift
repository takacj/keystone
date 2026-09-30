import AzureAuth
import AzureCLI
import AzureCore
import Foundation
import Observation

/// State of the `az` installation, drives onboarding.
enum AzureStatus: Equatable {
    case checking
    case missing
    case ready(version: AzureVersion?)  // nil version = could not be read

    var isReady: Bool { if case .ready = self { true } else { false } }
    var isOutdated: Bool { if case .ready(let v?) = self { !v.isSupported } else { false } }
}

/// State of an in-progress `az login` (add account or re-login).
struct LoginProgress: Equatable {
    var deviceCode: DeviceCodePrompt?
    var lastLine: String?
}

/// App-level observable model. Owns the `ProfileStore`, the selected account and one
/// `AzureCLITokenProvider` per account. Later UI todos (tenants, subscriptions, vaults) extend it.
///
/// Use `tokenProvider(for:)` to obtain a provider for ARM / Key Vault clients, and `runner`
/// for other `az` calls. All mutation happens on the main actor.
@MainActor @Observable
final class AppModel {
    // MARK: Observable state
    private(set) var azureStatus: AzureStatus = .checking
    private(set) var accounts: [AccountProfile] = []
    private(set) var selectedAccountID: UUID?
    /// Non-nil while a login is running.
    private(set) var loginProgress: LoginProgress?
    var loginError: String?
    var isManageAccountsPresented = false
    var isAddAccountPresented = false

    var selectedAccount: AccountProfile? { accounts.first { $0.id == selectedAccountID } }
    var isLoggingIn: Bool { loginProgress != nil }
    /// Onboarding is shown until `az` is usable and at least one account exists.
    var needsOnboarding: Bool { !azureStatus.isReady || accounts.isEmpty }

    // MARK: Dependencies
    let locator: AzureLocator
    private let rootDirectory: URL
    private let defaults: UserDefaults
    private let runnerFactory: @Sendable (URL) -> any CLIRunning
    private(set) var runner: (any CLIRunning)?
    private(set) var profileStore: ProfileStore?
    private var providers: [UUID: AzureCLITokenProvider] = [:]
    /// HTTP transport for ARM / Key Vault clients (mocked in `-UITestMode`).
    private(set) var transport: any HTTPTransport = URLSession.shared
    private var mockTokenProvider: (any TokenProvider)?
    private var loginTask: Task<Void, Never>?

    static let selectedAccountKey = "selectedAccountID"
    static let azPathOverrideKey = "azPathOverride"

    init(
        locator: AzureLocator = AzureLocator(),
        rootDirectory: URL = ProfileStore.defaultRootDirectory,
        defaults: UserDefaults = .standard,
        runnerFactory: @escaping @Sendable (URL) -> any CLIRunning = { CLIRunner(executable: $0) }
    ) {
        self.locator = locator
        self.rootDirectory = rootDirectory
        self.defaults = defaults
        self.runnerFactory = runnerFactory
        selectedAccountID = defaults.string(forKey: Self.selectedAccountKey).flatMap(UUID.init)
    }

    /// Mock environment (`-UITestMode`, tests): fixed account, no `az`, mock tokens + transport.
    convenience init(defaults: UserDefaults, mock: (tokens: any TokenProvider, transport: any HTTPTransport)) {
        self.init(defaults: defaults)
        mockTokenProvider = mock.tokens
        transport = mock.transport
        accounts = UITestSupport.hasFlag("-UITestOnboarding") ? [] : [UITestSupport.account]
        selectedAccountID = accounts.isEmpty ? nil : UITestSupport.accountID
        azureStatus = UITestSupport.hasFlag("-UITestMissingAz") ? .missing : .ready(version: nil)
    }

    // MARK: az detection

    /// Locates `az` (honouring the Settings override), reads its version and loads accounts.
    func bootstrap() async {
        if mockTokenProvider != nil { return }
        azureStatus = .checking
        let override = defaults.string(forKey: Self.azPathOverrideKey)
        guard let url = try? await locator.locate(override: override) else {
            runner = nil
            profileStore = nil
            azureStatus = .missing
            return
        }
        let runner = runnerFactory(url)
        self.runner = runner
        profileStore = ProfileStore(rootDirectory: rootDirectory, runner: runner)
        providers = [:]
        let version = try? await AzureLocator.version(of: runner)
        azureStatus = .ready(version: version)
        await reloadAccounts()
    }

    func reloadAccounts() async {
        guard let profileStore else { return }
        accounts = (try? await profileStore.accounts()) ?? []
        if selectedAccount == nil { select(accounts.first?.id) }
    }

    // MARK: Selection / providers

    func select(_ id: UUID?) {
        selectedAccountID = id
        defaults.set(id?.uuidString, forKey: Self.selectedAccountKey)
    }

    /// Token provider for an account (cached per account, so token caches survive view updates).
    func tokenProvider(for account: AccountProfile) -> (any TokenProvider)? {
        if let mockTokenProvider { return mockTokenProvider }
        if let existing = providers[account.id] { return existing }
        guard let runner else { return nil }
        let provider = AzureCLITokenProvider(runner: runner, profileDir: account.profileDir)
        providers[account.id] = provider
        return provider
    }

    // MARK: Login flows

    /// Adds an account via `az login` (browser, or device code when `useDeviceCode`).
    func addAccount(displayName: String? = nil, useDeviceCode: Bool, tenant: String? = nil) {
        runLogin { store, report in
            let options = AccountLoginOptions(useDeviceCode: useDeviceCode, tenant: tenant)
            return try await store.addAccount(displayName: displayName, options: options, onOutput: report).id
        }
    }

    /// Re-authenticates an account for a tenant (defaults to its home tenant), e.g. after MFA errors.
    func reLogin(_ account: AccountProfile, tenant: String? = nil, useDeviceCode: Bool = false) {
        runLogin { store, report in
            try await store.reLogin(
                id: account.id, tenant: tenant ?? account.homeTenantId, useDeviceCode: useDeviceCode, onOutput: report
            ).id
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
    }

    func clearLoginError() { loginError = nil }

    private func runLogin(
        _ work: @escaping @Sendable (ProfileStore, @escaping @Sendable (String) -> Void) async throws -> UUID
    ) {
        guard let store = profileStore, loginTask == nil else { return }
        loginError = nil
        loginProgress = LoginProgress()
        let report: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.handleLoginLine(line) }
        }
        loginTask = Task { [weak self] in
            defer {
                self?.loginProgress = nil
                self?.loginTask = nil
            }
            do {
                let id = try await work(store, report)
                await self?.reloadAccounts()
                self?.select(id)
                self?.isAddAccountPresented = false
            } catch is CancellationError {
            } catch AzureCLIError.cancelled {
            } catch {
                self?.loginError = error.localizedDescription
            }
        }
    }

    private func handleLoginLine(_ line: String) {
        guard loginProgress != nil else { return }
        if let prompt = DeviceCodePrompt.parse(line) { loginProgress?.deviceCode = prompt }
        loginProgress?.lastLine = line
    }

    // MARK: Manage

    func rename(_ account: AccountProfile, to name: String) async {
        try? await profileStore?.rename(id: account.id, to: name)
        await reloadAccounts()
    }

    func remove(_ account: AccountProfile) async {
        do { try await profileStore?.removeAccount(id: account.id) } catch { loginError = error.localizedDescription }
        providers[account.id] = nil
        if selectedAccountID == account.id { select(nil) }
        await reloadAccounts()
    }
}
