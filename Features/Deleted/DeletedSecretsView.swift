import AzureARM
import SwiftUI

/// Content column for the “Deleted secrets” sidebar item: table + recover/purge.
struct DeletedSecretsView: View {
    @Environment(ContextModel.self) private var context
    @Environment(DeletedSecretsModel.self) private var deleted
    @State private var confirmPurge: [String]?
    @State private var confirmRecover: [String]?

    private struct LoadKey: Equatable {
        var vaultID: String?
        var generation: Int
    }

    var body: some View {
        @Bindable var deleted = deleted
        Group {
            if let vault = context.selectedVault {
                VStack(spacing: 0) {
                    header(vault)
                    Divider()
                    content(vault)
                    Divider()
                    footer
                }
                .task(id: LoadKey(vaultID: vault.id, generation: context.contextGeneration)) {
                    await deleted.load(vault: vault)
                }
            } else {
                ContentUnavailableView("Select a vault", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Recover", systemImage: "arrow.uturn.backward") { recover(selectedNames) }
                    .disabled(selectedNames.isEmpty || deleted.isWorking)
                    .help("Recover selected secrets")
                Button("Purge…", systemImage: "trash.slash") { confirmPurge = selectedNames }
                    .disabled(selectedNames.isEmpty || deleted.isWorking || deleted.purgeProtected)
                    .help(
                        deleted.purgeProtected
                            ? DeletedSecretsModel.purgeProtectionExplanation : "Permanently delete selected secrets")
            }
        }
        .prodConfirmation(
            isPresented: Binding(
                get: { confirmPurge != nil && context.isProduction }, set: { if !$0 { confirmPurge = nil } }),
            title: purgeTitle, message: "Production vault. This can't be undone: all versions will be gone forever.",
            actionTitle: "Purge Permanently",
            requiredText: (confirmPurge?.count ?? 0) == 1 ? confirmPurge?.first : context.selectedVault?.name
        ) {
            let names = confirmPurge ?? []
            confirmPurge = nil
            Task { await deleted.purge(names) }
        }
        .prodConfirmation(
            isPresented: Binding(get: { confirmRecover != nil }, set: { if !$0 { confirmRecover = nil } }),
            title:
                "Recover \(confirmRecover?.count ?? 0) secret\((confirmRecover?.count ?? 0) == 1 ? "" : "s") in production?",
            message: "The secrets become active again in a production vault.", actionTitle: "Recover"
        ) {
            let names = confirmRecover ?? []
            confirmRecover = nil
            Task { await deleted.recover(names) }
        }
        .confirmationDialog(
            purgeTitle,
            isPresented: Binding(
                get: { confirmPurge != nil && !context.isProduction }, set: { if !$0 { confirmPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Purge Permanently", role: .destructive) {
                let names = confirmPurge ?? []
                confirmPurge = nil
                Task { await deleted.purge(names) }
            }
            Button("Cancel", role: .cancel) { confirmPurge = nil }
        } message: {
            Text(
                "This can't be undone. The secret\((confirmPurge?.count ?? 0) == 1 ? "" : "s") and all versions will be gone forever."
            )
        }
    }

    private var selectedNames: [String] {
        deleted.rows.filter { deleted.selection.contains($0.id) }.map(\.name)
    }

    private var purgeTitle: String {
        let n = confirmPurge?.count ?? 0
        return n == 1 ? "Purge “\(confirmPurge?.first ?? "")”?" : "Purge \(n) secrets?"
    }

    private func recover(_ names: [String]) {
        if context.isProduction { confirmRecover = names } else { Task { await deleted.recover(names) } }
    }

    private func header(_ vault: Vault) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Deleted secrets — \(vault.name)", systemImage: "trash").font(.headline)
            if deleted.purgeProtected {
                Label(DeletedSecretsModel.purgeProtectionExplanation, systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    @ViewBuilder
    private func content(_ vault: Vault) -> some View {
        @Bindable var deleted = deleted
        if let error = deleted.error, deleted.rows.isEmpty {
            ErrorView(error: error, vault: vault, onRetry: { Task { await deleted.refresh() } })
        } else if deleted.phase == .loading && deleted.rows.isEmpty {
            SkeletonRows()
        } else if deleted.phase == .loaded && deleted.rows.isEmpty {
            ContentUnavailableView(
                "No deleted secrets", systemImage: "trash", description: Text("Nothing to recover in \(vault.name)."))
        } else {
            Table(deleted.rows, selection: $deleted.selection) {
                TableColumn("Name") { row in Text(row.name).lineLimit(1).truncationMode(.middle) }
                    .width(min: 120, ideal: 200)
                TableColumn("Deleted") { row in dateText(row.deletedDate) }.width(min: 80, ideal: 110)
                TableColumn("Purge date") { row in dateText(row.scheduledPurgeDate) }.width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let names = deleted.rows.filter { ids.contains($0.id) }.map(\.name)
                Button("Recover", systemImage: "arrow.uturn.backward") { recover(names) }
                Button("Purge…", systemImage: "trash.slash") { confirmPurge = names }
                    .disabled(deleted.purgeProtected)
            }
        }
    }

    private func dateText(_ date: Date?) -> Text {
        date.map { Text($0, format: .dateTime.year().month(.abbreviated).day()) }
            ?? Text("—").foregroundStyle(.tertiary)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if deleted.phase == .loading || deleted.isWorking { ProgressView().controlSize(.small) }
            Text("\(deleted.rows.count) deleted")
                .foregroundStyle(.secondary)
            if let f = deleted.failures.first {
                Text("\(deleted.failures.count) failed — \(f.name): \(f.message)")
                    .foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// Reusable prompt for a 409: secret `name` is in Deleted secrets → recover or purge.
/// In production vaults, Recover/Purge go through `ProdConfirmationView` first.
struct DeletedConflictPrompt: ViewModifier {
    enum Action { case recover, purge }
    struct Pending: Equatable {
        let name: String
        let action: Action
    }

    @Environment(DeletedSecretsModel.self) private var deleted
    @Environment(ContextModel.self) private var context
    let vault: Vault?
    @Binding var name: String?
    var onResolved: (String) -> Void = { _ in }
    @State private var pending: Pending?

    func body(content: Content) -> some View {
        content.alert(
            "Name is in Deleted secrets", isPresented: Binding(get: { name != nil }, set: { if !$0 { name = nil } }),
            presenting: name
        ) { n in
            Button("Recover") { request(Pending(name: n, action: .recover)) }
            if vault?.enablePurgeProtection != true {
                Button("Purge", role: .destructive) { request(Pending(name: n, action: .purge)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { n in
            Text(DeletedConflict.message(name: n, vault: vault))
        }
        .prodConfirmation(
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            title: pending?.action == .purge
                ? "Purge “\(pending?.name ?? "")” permanently?" : "Recover “\(pending?.name ?? "")” in production?",
            message: pending?.action == .purge
                ? "Production vault. This can't be undone: all versions will be gone forever."
                : "The secret becomes active again in a production vault.",
            actionTitle: pending?.action == .purge ? "Purge Permanently" : "Recover",
            requiredText: pending?.action == .purge ? pending?.name : nil
        ) {
            guard let p = pending else { return }
            pending = nil
            execute(p)
        }
    }

    private func request(_ p: Pending) {
        if context.isProduction { pending = p } else { execute(p) }
    }

    private func execute(_ p: Pending) {
        switch p.action {
        case .recover: run(p.name) { await deleted.recover([p.name]) }
        case .purge: run(p.name) { await deleted.purge([p.name]) }
        }
    }

    private func run(_ n: String, _ op: @escaping () async -> [String]) {
        if let vault { deleted.attach(vault) }
        Task { if await op().contains(n) { onResolved(n) } }
    }
}

extension View {
    /// Shows recover/purge options when `name` is set (after a 409 on create/delete).
    func deletedConflictPrompt(vault: Vault?, name: Binding<String?>, onResolved: @escaping (String) -> Void = { _ in })
        -> some View
    {
        modifier(DeletedConflictPrompt(vault: vault, name: name, onResolved: onResolved))
    }
}
