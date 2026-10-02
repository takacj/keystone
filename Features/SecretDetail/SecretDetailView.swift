import AppKit
import KeyVaultSecrets
import SwiftUI

/// Detail column: driven by `SecretsModel.selection` (single selection).
struct SecretDetailView: View {
    @Environment(SecretsModel.self) private var secrets
    @Environment(SecretDetailModel.self) private var detail
    @Environment(SecretEditorCoordinator.self) private var editor
    @Environment(LockModel.self) private var lock
    @Environment(ViewRequests.self) private var requests
    @State private var versions: VersionHistoryModel?

    private var selectedName: String? {
        secrets.selection.count == 1 ? secrets.selection.first : nil
    }

    private struct LoadKey: Hashable {
        let vault: String?
        let name: String?
    }

    var body: some View {
        Group {
            if secrets.selection.count > 1 {
                ContentUnavailableView("\(secrets.selection.count) secrets selected", systemImage: "key.2.on.ring")
            } else if let name = selectedName {
                content(name: name)
            } else {
                ContentUnavailableView("No secret selected", systemImage: "key")
            }
        }
        .task(id: LoadKey(vault: secrets.vault?.id, name: selectedName)) {
            await detail.show(vault: secrets.vault, name: selectedName)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            detail.mask()
        }
        .overlay(alignment: .bottom) {
            if detail.showCopiedToast {
                ToastLabel(text: "Copied")
            }
        }
        .animation(.default, value: detail.showCopiedToast)
        .onChange(of: lock.lockGeneration) {
            versions?.clear()
            versions = nil
        }
        .onChange(of: requests.showVersions) { if detail.phase == .loaded { showVersions() } }
        .sheet(item: $versions) { model in
            VersionHistorySheet(model: model) { restore(model) }
        }
        .toolbar {
            ToolbarItem {
                Button("Versions", systemImage: "clock.arrow.circlepath") { showVersions() }
                    .disabled(detail.phase != .loaded || selectedName == nil)
                    .help("Version history (⌘Y)")
            }
            ToolbarItem {
                Button("Edit", systemImage: "pencil") {
                    editor.beginEdit(vault: secrets.vault, bundle: detail.bundle)
                }
                .disabled(detail.phase != .loaded || detail.value == nil || selectedName == nil)
                .help("Edit secret (⌘E)")
            }
        }
    }

    private func showVersions() {
        guard let vault = secrets.vault, let name = selectedName,
            let client = secrets.clientFactory(vault)
        else { return }
        detail.mask()
        versions = VersionHistoryModel(vault: vault, name: name, ops: VersionHistoryOps(client: client))
    }

    private func restore(_ model: VersionHistoryModel) {
        Task {
            guard let result = await model.restore() else { return }
            versions = nil
            await editor.completed(result, vault: model.vault)
        }
    }

    @ViewBuilder
    private func content(name: String) -> some View {
        switch detail.phase {
        case .idle, .loading:
            SkeletonRows(count: 5)
        case .failed:
            if let error = detail.error {
                ErrorView(error: error, vault: secrets.vault, onRetry: { Task { await detail.retry() } })
            }
        case .loaded:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(name: name)
                    Divider()
                    SecretValueSection()
                    Divider()
                    metadata
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(name: String) -> some View {
        let attrs = detail.bundle?.attributes
        return VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 10) {
                let enabled = attrs?.enabled ?? true
                Label(enabled ? "Enabled" : "Disabled", systemImage: "circle.fill")
                    .foregroundStyle(enabled ? .green : .secondary)
                if let type = detail.bundle?.contentType, !type.isEmpty {
                    Text(type).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var metadata: some View {
        let attrs = detail.bundle?.attributes
        let tags = (detail.bundle?.tags ?? [:]).sorted { $0.key < $1.key }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            if !tags.isEmpty {
                GridRow {
                    label("Tags")
                    FlowTags(tags: tags)
                }
            }
            dateRow("Created", attrs?.created)
            dateRow("Updated", attrs?.updated)
            if let notBefore = attrs?.notBefore {
                dateRow("Not before", notBefore)
            }
            dateRow("Expires", attrs?.expires)
            if let version = detail.bundle?.version {
                GridRow {
                    label("Version")
                    Text(version).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private func dateRow(_ title: String, _ date: Date?) -> some View {
        GridRow {
            label(title)
            if let date {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                    if title == "Expires" {
                        ExpiryPill(date: date)
                    } else {
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .wide))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(absoluteDateString(date))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}

private struct FlowTags: View {
    let tags: [(key: String, value: String)]

    var body: some View {
        HStack {
            ForEach(tags, id: \.key) { tag in
                Text("\(tag.key)=\(tag.value)")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

/// Masked / revealed value with reveal, copy and Format JSON controls.
private struct SecretValueSection: View {
    @Environment(SecretDetailModel.self) private var detail

    var body: some View {
        @Bindable var detail = detail
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Value").font(.headline)
                Spacer()
                if detail.isRevealed && detail.isJSON {
                    Toggle("Format JSON", isOn: $detail.formatJSON)
                        .toggleStyle(.switch).controlSize(.small)
                }
                Button(detail.isRevealed ? "Hide" : "Reveal", systemImage: detail.isRevealed ? "eye.slash" : "eye") {
                    detail.toggleReveal()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.space, modifiers: [])
                .help(detail.isRevealed ? "Hide value (Space)" : "Reveal value (Space)")
                .accessibilityIdentifier("secret.reveal")
                Button("Copy", systemImage: "doc.on.doc") { detail.copy() }
                    .labelStyle(.iconOnly)
                    .help("Copy value (concealed from clipboard managers)")
            }
            valueBox
        }
    }

    @ViewBuilder
    private var valueBox: some View {
        Group {
            if detail.isRevealed {
                Text(detail.displayValue)
                    .accessibilityIdentifier("secret.value")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(String(repeating: "•", count: 12))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Value hidden")
                    .accessibilityIdentifier("secret.value.hidden")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
