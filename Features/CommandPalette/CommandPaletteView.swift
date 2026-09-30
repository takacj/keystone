import AzureARM
import SwiftUI

/// Spotlight-style glass overlay for ⌘K (plan §6.2).
struct CommandPaletteView: View {
    @Environment(CommandPaletteModel.self) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var palette = palette
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search vaults and secrets", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .accessibilityIdentifier("palette.query")
                    .onSubmit { Task { await palette.openSelected() } }
            }
            .padding(12)
            HStack {
                Picker("Scope", selection: $palette.scope) {
                    ForEach(CommandPaletteModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                indexStatus
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            results
            Divider()
            HStack(spacing: 14) {
                hint("↩", "open")
                hint("⌘C", "copy value")
                hint("⌘⇧C", "copy name")
                Spacer()
                hint("esc", "close")
            }
            .padding(8)
        }
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(radius: 24)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            palette.moveSelection(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            palette.moveSelection(-1)
            return .handled
        }
        .onKeyPress(.escape) {
            palette.close()
            return .handled
        }
        .background {
            Group {
                Button("") { Task { await palette.copyValue() } }.keyboardShortcut("c", modifiers: .command)
                Button("") { palette.copyName() }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .hidden()
        }
    }

    @ViewBuilder private var indexStatus: some View {
        if palette.isDiscovering {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Discovering vaults…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let error = palette.indexError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
        } else if let p = palette.progress, !p.isFinished {
            HStack(spacing: 6) {
                ProgressView(value: Double(p.completed), total: Double(max(p.total, 1))).frame(width: 60)
                Text("Indexing \(p.completed)/\(p.total)")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let p = palette.progress, p.total > 0 {
            Text("\(p.secretCount) secrets in \(p.total) vaults" + (p.inaccessible > 0 ? " · 🔒 \(p.inaccessible)" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            List {
                if !palette.vaultResults.isEmpty {
                    Section("Vaults") { ForEach(palette.vaultResults) { row($0) } }
                }
                if !palette.secretResults.isEmpty {
                    Section("Secrets") { ForEach(palette.secretResults) { row($0) } }
                }
                if palette.items.isEmpty {
                    Text(palette.query.isEmpty ? "Type to search" : "No results")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 320)
            .accessibilityIdentifier("palette.results")
            .onChange(of: palette.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func row(_ item: PaletteItem) -> some View {
        let selected = item.id == palette.selectedID
        return HStack(spacing: 8) {
            Image(systemName: item.secretName == nil ? "lock.shield" : "key").foregroundStyle(.secondary)
            Text(item.secretName ?? item.vault.name).lineLimit(1)
            if item.secretName != nil {
                Text(item.vault.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(item.vault.location).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette.row.\(item.secretName ?? item.vault.name)")
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .id(item.id)
        .onTapGesture {
            palette.selectedID = item.id
            Task { await palette.openSelected() }
        }
        .listRowSeparator(.hidden)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced()).padding(.horizontal, 4)
                .background(.quaternary, in: .rect(cornerRadius: 4))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
