import AppKit
import AzureARM
import Foundation
import Observation
import Search

/// One row of the ⌘K palette.
enum PaletteItem: Identifiable, Hashable {
    case vault(Vault)
    case secret(Vault, String)

    var id: String {
        switch self {
        case .vault(let v): "v:" + v.id
        case .secret(let v, let n): "s:" + v.id + "/" + n
        }
    }
    var vault: Vault {
        switch self {
        case .vault(let v), .secret(let v, _): v
        }
    }
    var secretName: String? {
        if case .secret(_, let n) = self { n } else { nil }
    }
    /// What ⌘⇧C copies.
    var copyName: String { secretName ?? vault.name }
}

/// ⌘K palette state: tenant-wide vault discovery + background `NameIndex`, scope toggle, fuzzy results (plan §6.2).
@MainActor @Observable
final class CommandPaletteModel {
    enum Scope: String, CaseIterable, Identifiable {
        case currentSubscription = "Current subscription"
        case allInTenant = "All in tenant"
        var id: String { rawValue }

        var storageValue: String {
            switch self {
            case .currentSubscription: "currentSubscription"
            case .allInTenant: "allInTenant"
            }
        }

        init(storageValue: String?) {
            self = Scope.allCases.first { $0.storageValue == storageValue } ?? .currentSubscription
        }
    }

    /// UserDefaults key holding the default scope (`Scope.storageValue`), edited in Settings.
    static let defaultScopeKey = "paletteDefaultScope"

    static let vaultLimit = 8
    static let secretLimit = 40

    var isPresented = false
    var query = "" { didSet { if query != oldValue { scheduleRefresh() } } }
    var scope: Scope = .currentSubscription { didSet { if scope != oldValue { scheduleRefresh() } } }
    var selectedID: String?
    private(set) var vaultResults: [PaletteItem] = []
    private(set) var secretResults: [PaletteItem] = []
    private(set) var progress: NameIndex.Progress?
    private(set) var isDiscovering = false
    private(set) var indexError: String?
    private(set) var toast: String?

    // Dependencies (wired by MainView; replaced by fakes in tests).
    var discover: (String) async throws -> [Vault] = { _ in [] }
    /// Builds the secret-name lister for a tenant.
    var makeLister: (String) -> NameIndex.SecretNameLister? = { _ in nil }
    var currentSubscription: () -> String? = { nil }
    var fetchValue: (Vault, String) async throws -> String = { _, _ in throw CancellationError() }
    var writeSecret: (String) -> Void = SecretDetailModel.writeConcealed
    var writePlain: (String) -> Void = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    var navigate: (Vault, String?) async -> Void = { _, _ in }

    private(set) var indexTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lister: NameIndex.SecretNameLister?
    private var allVaults: [Vault] = []
    private var tenant: String?
    private let index: NameIndex

    init(index: NameIndex? = nil, defaults: UserDefaults = .standard) {
        scope = Scope(storageValue: defaults.string(forKey: Self.defaultScopeKey))
        if let index {
            self.index = index
        } else {
            let box = ListerBox()
            self.index = NameIndex(lister: { vault in try await box.list(vault) })
            listerBox = box
        }
    }

    /// Bridges the index's fixed lister to the per-tenant one stored on the model.
    private final class ListerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: NameIndex.SecretNameLister?
        func set(_ l: NameIndex.SecretNameLister?) { lock.withLock { current = l } }
        func list(_ vault: Vault) async throws -> [String] {
            let l = lock.withLock { current }
            return try await l?(vault) ?? []
        }
    }
    private var listerBox: ListerBox?

    // MARK: Indexing

    /// (Re)starts discovery + background indexing for `tenant` (nil cancels and clears).
    func startIndexing(tenant: String?, force: Bool = false) {
        indexTask?.cancel()
        self.tenant = tenant
        guard let tenant else {
            allVaults = []
            progress = nil
            indexTask = Task { [index] in await index.reset() }
            scheduleRefresh()
            return
        }
        listerBox?.set(makeLister(tenant))
        indexError = nil
        isDiscovering = true
        let discover = self.discover
        indexTask = Task { [weak self, index] in
            do {
                let vaults = try await discover(tenant)
                try Task.checkCancellation()
                guard let self else { return }
                self.allVaults = vaults
                self.isDiscovering = false
                self.scheduleRefresh()
                await index.build(tenant: tenant, vaults: vaults, force: force) { [weak self] p in
                    Task { @MainActor in
                        self?.progress = p
                        self?.scheduleRefresh()
                    }
                }
                self.progress = await index.progress
                self.scheduleRefresh()
            } catch is CancellationError {
            } catch {
                self?.isDiscovering = false
                self?.indexError = error.localizedDescription
            }
        }
    }

    /// Clears everything (lock, account switch).
    func reset() {
        isPresented = false
        query = ""
        startIndexing(tenant: nil)
    }

    // MARK: Presentation

    func toggle() { isPresented ? close() : open() }

    func open() {
        query = ""
        isPresented = true
        scheduleRefresh()
    }

    func close() { isPresented = false }

    // MARK: Results

    var items: [PaletteItem] { vaultResults + secretResults }

    var scopeVaults: [Vault] {
        switch scope {
        case .allInTenant: return allVaults
        case .currentSubscription:
            guard let sub = currentSubscription()?.lowercased() else { return allVaults }
            return allVaults.filter { $0.subscriptionId.lowercased() == sub }
        }
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    func refresh() async {
        let vaults = scopeVaults
        let matcher = FuzzyMatcher(query: query.trimmingCharacters(in: .whitespaces))
        let vaultHits = matcher.filter(vaults, key: \.name).prefix(Self.vaultLimit).map { PaletteItem.vault($0.item) }
        var secretHits: [(item: PaletteItem, score: Int)] = []
        if !matcher.isEmpty {
            for vault in vaults where await !index.isInaccessible(vault) {
                if Task.isCancelled { return }
                for hit in matcher.filter(await index.secretNames(in: vault), key: \.self) {
                    secretHits.append((.secret(vault, hit.item), hit.match.score))
                }
            }
        }
        guard !Task.isCancelled else { return }
        vaultResults = vaultHits
        secretResults = secretHits.sorted { $0.score > $1.score }.prefix(Self.secretLimit).map(\.item)
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }

    func moveSelection(_ delta: Int) {
        let all = items
        guard !all.isEmpty else { return }
        let current = all.firstIndex { $0.id == selectedID } ?? 0
        selectedID = all[min(max(current + delta, 0), all.count - 1)].id
    }

    var selectedItem: PaletteItem? { items.first { $0.id == selectedID } }

    // MARK: Actions

    /// ↩ — close and navigate to the vault (and select the secret).
    func openSelected() async {
        guard let item = selectedItem else { return }
        close()
        await navigate(item.vault, item.secretName)
    }

    /// ⌘C — copies the secret value (concealed); for a vault row copies its name.
    func copyValue() async {
        guard let item = selectedItem else { return }
        guard let name = item.secretName else { return copyName() }
        do {
            let value = try await fetchValue(item.vault, name)
            writeSecret(value)
            close()
            showToast("Copied value of \(name)")
        } catch {
            showToast("Couldn't copy value: \(error.localizedDescription)")
        }
    }

    /// ⌘⇧C — copies the secret (or vault) name.
    func copyName() {
        guard let item = selectedItem else { return }
        writePlain(item.copyName)
        close()
        showToast("Copied \(item.copyName)")
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
