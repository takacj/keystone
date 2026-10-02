import AzureARM
import Search
import SwiftUI

/// ⇧⌘F sheet: find secrets by value. The value input is masked and never stored; results show names only.
struct ValueSearchSheet: View {
    @Environment(ValueSearchModel.self) private var search
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var search = search
        VStack(alignment: .leading, spacing: 12) {
            Text("Search by Value").font(.headline)
            Text("Reads the current value of every secret in scope and compares it locally. Values are never stored.")
                .font(.callout).foregroundStyle(.secondary)
            valueField
            HStack {
                Picker("Scope", selection: $search.scope) {
                    ForEach(ValueSearchModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                Spacer()
                Picker("Match", selection: $search.mode) {
                    Text("Exact").tag(ValueSearcher.MatchMode.exact)
                    Text("Contains").tag(ValueSearcher.MatchMode.contains)
                }
                .frame(width: 160)
            }
            .disabled(search.isScanning)
            HStack {
                Toggle("Case sensitive", isOn: $search.caseSensitive)
                Toggle("Include disabled secrets", isOn: $search.includeDisabled)
            }
            .disabled(search.isScanning)
            Divider()
            status
            results
            HStack {
                Spacer()
                Button("Close") { search.close() }.keyboardShortcut(.cancelAction)
                if search.isScanning {
                    Button("Stop") { search.cancelScan() }.accessibilityIdentifier("valueSearch.stop")
                } else {
                    Button("Search") { Task { await search.start() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!search.canStart)
                        .accessibilityIdentifier("valueSearch.start")
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { focused = true }
        .overlay(alignment: .bottom) {
            if let toast = search.toast { ToastLabel(text: toast) }
        }
        .animation(.default, value: search.toast)
        .prodConfirmation(
            isPresented: Binding(
                get: { search.pendingProduction != nil }, set: { if !$0 { search.cancelProduction() } }),
            title: "Read production secret values?",
            message: "The scan reads the value of every secret in "
                + (search.pendingProduction ?? []).map(\.name).joined(separator: ", ") + ".",
            actionTitle: "Scan"
        ) { search.confirmProduction() }
    }

    private var valueField: some View {
        @Bindable var search = search
        return HStack(spacing: 6) {
            Group {
                if search.isRevealed {
                    TextField("Value", text: $search.value)
                } else {
                    SecureField("Value", text: $search.value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .focused($focused)
            .accessibilityIdentifier("valueSearch.value")
            .onSubmit { Task { await search.start() } }
            Button(search.isRevealed ? "Hide" : "Reveal", systemImage: search.isRevealed ? "eye.slash" : "eye") {
                search.isRevealed.toggle()
            }
            .labelStyle(.iconOnly)
            .help(search.isRevealed ? "Hide value" : "Reveal value")
        }
    }

    @ViewBuilder private var status: some View {
        switch search.phase {
        case .idle:
            EmptyView()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .scanning, .finished, .cancelled:
            HStack(spacing: 8) {
                if search.isScanning { ProgressView().controlSize(.small) }
                Text(statusText).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("valueSearch.status")
            }
        }
    }

    private var statusText: String {
        let p = search.progress ?? .init()
        var parts = ["\(p.vaultsScanned)/\(p.vaultsTotal) vaults", "\(p.secretsScanned)/\(p.secretsTotal) secrets"]
        if p.secretsFailed > 0 { parts.append("\(p.secretsFailed) unreadable") }
        let head =
            switch search.phase {
            case .finished: "Done · \(search.matches.count) match\(search.matches.count == 1 ? "" : "es")"
            case .cancelled: "Stopped"
            default: "Scanning"
            }
        return ([head] + parts).joined(separator: " · ")
    }

    private var results: some View {
        List {
            if !search.matches.isEmpty {
                Section("Matches") { ForEach(search.matches) { row($0) } }
            }
            if !search.skipped.isEmpty {
                Section("Skipped vaults") {
                    ForEach(search.skipped) { s in
                        HStack {
                            Image(systemName: s.reason == .firewall ? "network.badge.shield.half.filled" : "lock")
                                .foregroundStyle(.secondary)
                            Text(s.vault.name)
                            Spacer()
                            Text(s.reason.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if search.matches.isEmpty && search.skipped.isEmpty && search.phase == .finished {
                Text("No secrets with this value").foregroundStyle(.secondary)
            }
        }
        .frame(height: 280)
        .accessibilityIdentifier("valueSearch.results")
    }

    private func row(_ m: ValueSearcher.Match) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key").foregroundStyle(.secondary)
            Text(m.secretName).lineLimit(1)
            Text(m.vault.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !m.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
            ExpiryPill(date: m.expires).font(.caption)
            Button("Copy Name", systemImage: "doc.on.doc") { search.copyName(m) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy name")
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("valueSearch.row.\(m.vault.name)/\(m.secretName)")
        .onTapGesture { Task { await search.openMatch(m) } }
        .contextMenu {
            Button("Open") { Task { await search.openMatch(m) } }
            Button("Copy Name") { search.copyName(m) }
        }
    }
}
