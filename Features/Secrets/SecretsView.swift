import AppKit
import AzureARM
import KeyVaultSecrets
import SwiftUI

/// Content column: filter field, chips, sortable secrets table, status footer.
struct SecretsView: View {
    @Environment(ContextModel.self) private var context
    @Environment(SecretsModel.self) private var secrets
    @Environment(DeletedSecretsModel.self) private var deleted
    @Environment(SecretEditorCoordinator.self) private var editor
    @Environment(SecretDetailModel.self) private var detail
    @Environment(ViewRequests.self) private var requests
    @FocusState private var filterFocused: Bool
    @State private var pendingDelete: [String]?
    @State private var deleteFailures: [SecretOpFailure] = []
    @State private var conflictName: String?

    private struct LoadKey: Equatable {
        var vaultID: String?
        var generation: Int
    }

    var body: some View {
        @Bindable var secrets = secrets
        Group {
            if let vault = context.selectedVault {
                VStack(spacing: 0) {
                    filterBar
                    SecretChips()
                    Divider()
                    content(vault)
                    Divider()
                    footer
                }
                .task(id: LoadKey(vaultID: vault.id, generation: context.contextGeneration)) {
                    await secrets.load(vault: vault)
                }
            } else if let error = context.tenantsError ?? context.subscriptionsError {
                ErrorView(error: error, onRetry: { context.reload() })
            } else if case .failed(let message) = context.tenantsPhase {
                ContentUnavailableView(
                    "Couldn't load tenants", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if context.tenantsPhase == .loading || context.subscriptionsPhase == .loading
                || context.vaultsPhase == .loading
            {
                SkeletonRows()
            } else {
                ContentUnavailableView("Select a vault", systemImage: "sidebar.left")
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil && !context.isProduction }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let names = pendingDelete ?? []
                pendingDelete = nil
                performDelete(names)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Secrets are soft-deleted and can be recovered from Deleted secrets.")
        }
        .prodConfirmation(
            isPresented: Binding(
                get: { pendingDelete != nil && context.isProduction }, set: { if !$0 { pendingDelete = nil } }),
            title: deleteTitle,
            message: "You are deleting in a production vault. Secrets are soft-deleted and can be recovered.",
            actionTitle: "Delete",
            requiredText: (pendingDelete?.count ?? 0) == 1 ? pendingDelete?.first : context.selectedVault?.name
        ) {
            let names = pendingDelete ?? []
            pendingDelete = nil
            performDelete(names)
        }
        .alert(
            "Some secrets couldn't be deleted",
            isPresented: Binding(get: { !deleteFailures.isEmpty }, set: { if !$0 { deleteFailures = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(deleteFailures.prefix(5).map { "\($0.name): \($0.message)" }.joined(separator: "\n"))
        }
        .onChange(of: requests.focusFilter) { filterFocused = true }
        .onChange(of: requests.deleteSelected) {
            if !secrets.selection.isEmpty { pendingDelete = secrets.selectedNames() }
        }
        .deletedConflictPrompt(vault: context.selectedVault, name: $conflictName) { _ in
            Task { await secrets.refresh() }
        }
        .toolbar {
            ToolbarItem {
                Button("New Secret", systemImage: "plus") { editor.beginCreate(vault: context.selectedVault) }
                    .disabled(context.selectedVault == nil)
                    .help("New secret (⌘N)")
            }
            ToolbarItem {
                Button("Copy Names", systemImage: "doc.on.doc") { copyNames() }
                    .disabled(secrets.selection.isEmpty)
                    .help("Copy selected secret names (⇧⌘C)")
            }
            ToolbarItem {
                Button("Delete", systemImage: "trash") { pendingDelete = secrets.selectedNames() }
                    .disabled(secrets.selection.isEmpty)
                    .help("Delete selected secrets (⌘⌫)")
            }
        }
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return n == 1 ? "Delete “\(pendingDelete?.first ?? "")”?" : "Delete \(n) secrets?"
    }

    private func performDelete(_ names: [String]) {
        Task {
            let failed = await secrets.delete(names: names)
            if let c = failed.first(where: { DeletedConflict.isConflict($0.error) }) {
                conflictName = c.name
            } else {
                deleteFailures = failed
            }
            if failed.count < names.count { deleted.noteStale() }
        }
    }

    private var filterBar: some View {
        @Bindable var secrets = secrets
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter secrets…", text: $secrets.filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .accessibilityIdentifier("secrets.filter")
            if !secrets.filterText.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { secrets.filterText = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ vault: Vault) -> some View {
        @Bindable var secrets = secrets
        if let error = secrets.error, secrets.rows.isEmpty {
            ErrorView(error: error, vault: vault, onRetry: { secrets.reload() })
        } else if secrets.phase == .loading && secrets.rows.isEmpty {
            SkeletonRows()
        } else if secrets.phase == .loaded && secrets.rows.isEmpty {
            ContentUnavailableView {
                Label("No secrets", systemImage: "key")
            } description: {
                Text("\(vault.name) has no secrets.")
            } actions: {
                Button("New Secret") { editor.beginCreate(vault: vault) }.buttonStyle(.borderedProminent)
            }
        } else {
            Table(secrets.visible, selection: $secrets.selection, sortOrder: $secrets.sortOrder) {
                TableColumn("Name", sortUsing: KeyPathComparator(\.name, comparator: .localizedStandard)) { row in
                    Text(Self.highlighted(row.name, secrets.highlights[row.id]))
                        .lineLimit(1).truncationMode(.middle)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Content type", sortUsing: KeyPathComparator(\.contentType)) { row in
                    Text(row.contentType).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 60, ideal: 100)
                TableColumn("Updated", sortUsing: KeyPathComparator(\.updatedSort)) { row in
                    RelativeDateText(date: row.updated)
                }
                .width(min: 60, ideal: 90)
                TableColumn("Expires", sortUsing: KeyPathComparator(\.expiresSort)) { row in
                    ExpiryPill(date: row.expires)
                }
                .width(min: 60, ideal: 90)
                TableColumn("Enabled", sortUsing: KeyPathComparator(\.enabledSort)) { row in
                    Image(systemName: row.enabled ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(row.enabled ? Color.green : Color.secondary)
                        .accessibilityLabel(row.enabled ? "Enabled" : "Disabled")
                }
                .width(50)
                TableColumn("Tags") { row in
                    Text(row.tagsText).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 60, ideal: 120)
            }
            .accessibilityIdentifier("secrets.table")
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Copy Name\(ids.count == 1 ? "" : "s")") {
                    Self.copy(names: secrets.visible.filter { ids.contains($0.id) }.map(\.name))
                }
                Button("Delete…", systemImage: "trash", role: .destructive) {
                    pendingDelete = secrets.visible.filter { ids.contains($0.id) }.map(\.name)
                }
            }
            .onCopyCommand {
                // ⌘C on a single row copies the (concealed) value; multiple rows copy names.
                if secrets.selection.count == 1 {
                    detail.copy()
                    return []
                }
                let names = secrets.selectedNames()
                return names.isEmpty ? [] : [NSItemProvider(object: names.joined(separator: "\n") as NSString)]
            }
            .overlay {
                if secrets.visible.isEmpty && !secrets.rows.isEmpty {
                    ContentUnavailableView.search
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if secrets.phase == .loading { ProgressView().controlSize(.small) }
            Text(summary).foregroundStyle(.secondary)
            if let message = secrets.errorMessage, !secrets.rows.isEmpty {
                Text(message).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var summary: String {
        let total = secrets.rows.count
        var s = "\(total) secret\(total == 1 ? "" : "s")"
        if secrets.visible.count != total { s = "\(secrets.visible.count) of \(s)" }
        if secrets.disabledCount > 0 { s += " · \(secrets.disabledCount) disabled" }
        if !secrets.selection.isEmpty { s += " · \(secrets.selection.count) selected" }
        return s
    }

    private func copyNames() {
        Self.copy(names: secrets.selectedNames())
    }

    static func copy(names: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    static func highlighted(_ name: String, _ ranges: [Range<Int>]?) -> AttributedString {
        var attr = AttributedString(name)
        guard let ranges else { return attr }
        let u = name.utf16
        for r in ranges {
            guard r.upperBound <= u.count,
                let lo = u.index(u.startIndex, offsetBy: r.lowerBound, limitedBy: u.endIndex),
                let hi = u.index(u.startIndex, offsetBy: r.upperBound, limitedBy: u.endIndex),
                let range = Range(lo..<hi, in: attr)
            else { continue }
            attr[range].foregroundColor = .accentColor
            attr[range].font = .body.bold()
        }
        return attr
    }
}

/// Filter chips: Enabled/Disabled, Expiring ≤30d, Expired, Tag….
private struct SecretChips: View {
    @Environment(SecretsModel.self) private var secrets

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SecretChip.allCases, id: \.self) { chip in
                let on = secrets.chips.contains(chip)
                Toggle(chip.title, isOn: Binding(get: { on }, set: { _ in secrets.toggle(chip) }))
                    .toggleStyle(.button).controlSize(.small)
                    .tint(on ? .accentColor : nil)
            }
            Menu {
                Button("Any tag") { secrets.tagFilter = nil }
                Divider()
                ForEach(secrets.availableTags, id: \.self) { tag in
                    Button {
                        secrets.tagFilter = tag
                    } label: {
                        if secrets.tagFilter == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                    }
                }
            } label: {
                Text(secrets.tagFilter.map { "Tag: \($0)" } ?? "Tag…")
            }
            .controlSize(.small).fixedSize()
            .disabled(secrets.availableTags.isEmpty)
            Spacer(minLength: 0)
            if !secrets.chips.isEmpty || secrets.tagFilter != nil {
                Button("Reset") { secrets.clearFilters() }.controlSize(.small).buttonStyle(.link)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}
