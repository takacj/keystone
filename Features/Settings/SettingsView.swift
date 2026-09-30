import AppKit
import SwiftUI

/// ⌘, Settings scene content.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SecuritySettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }
            ProductionSettingsView()
                .tabItem { Label("Production", systemImage: "exclamationmark.triangle") }
            SearchSettingsView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .frame(width: 480, height: 320)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.azPathOverrideKey) private var azPath = ""

    var body: some View {
        Form {
            Section("Azure CLI") {
                HStack {
                    TextField("az path override", text: $azPath, prompt: Text("Auto-detect"))
                    Button("Browse…", action: browse)
                }
                LabeledContent("Detected") { Text(detected).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button("Re-check") { Task { await model.bootstrap() } }
                    if !azPath.isEmpty { Button("Clear override") { azPath = "" } }
                }
                Text("Leave empty to search /opt/homebrew/bin, /usr/local/bin, then your login shell PATH.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: azPath) { Task { await model.bootstrap() } }
    }

    private var detected: String {
        switch model.azureStatus {
        case .checking: "Checking…"
        case .missing: "Not found"
        case .ready(let version): version.map { "az \($0)" } ?? "az (version unknown)"
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.message = "Choose the az executable"
        if panel.runModal() == .OK, let url = panel.url { azPath = url.path }
    }
}

struct SecuritySettingsView: View {
    @AppStorage(SecretDetailModel.remaskDefaultsKey) private var remask = SettingsDefaults.defaultRemaskSeconds
    @AppStorage(LockModel.idleMinutesKey) private var idle = SettingsDefaults.defaultLockIdleMinutes

    var body: some View {
        Form {
            Section("Secret values") {
                Stepper(value: $remask, in: 1...600) {
                    LabeledContent("Re-mask after", value: "\(remask) s")
                }
                Text("Revealed values also hide when the window loses focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Touch ID lock") {
                Stepper(value: $idle, in: 1...240) {
                    LabeledContent("Lock after idle", value: "\(idle) min")
                }
                Text("Also locks on launch, sleep, screen lock and ⌘L.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset to defaults") {
                remask = SettingsDefaults.defaultRemaskSeconds
                idle = SettingsDefaults.defaultLockIdleMinutes
            }
        }
        .formStyle(.grouped)
    }
}

struct ProductionSettingsView: View {
    @State private var patterns = SettingsDefaults.patterns()
    @State private var newPattern = ""

    var body: some View {
        Form {
            Section("Production patterns") {
                List {
                    ForEach(patterns, id: \.self) { p in
                        HStack {
                            Text(p).font(.body.monospaced())
                            Spacer()
                            Button {
                                remove(p)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(p)")
                        }
                    }
                }
                .frame(minHeight: 90)
                HStack {
                    TextField("Add pattern", text: $newPattern).onSubmit(add)
                    Button("Add", action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Reset to defaults") {
                    SettingsDefaults.resetPatterns()
                    patterns = ProdGuard.defaultPatterns
                }
                Text(
                    "Matched against words in subscription and vault names (split on - _ . space) that equal or start with a pattern: “prod” matches "
                        + "kv-prod-weu and kv-production, not reproduce."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        patterns = SettingsDefaults.normalizedPatterns(patterns + [newPattern])
        newPattern = ""
        SettingsDefaults.setPatterns(patterns)
    }

    private func remove(_ p: String) {
        patterns.removeAll { $0 == p }
        SettingsDefaults.setPatterns(patterns)
    }
}

struct SearchSettingsView: View {
    @AppStorage(CommandPaletteModel.defaultScopeKey) private var scope =
        CommandPaletteModel.Scope.currentSubscription.storageValue

    var body: some View {
        Form {
            Section("⌘K palette") {
                Picker("Default scope", selection: $scope) {
                    ForEach(CommandPaletteModel.Scope.allCases) { Text($0.rawValue).tag($0.storageValue) }
                }
                .pickerStyle(.radioGroup)
                Text("Applies immediately; the palette's own toggle still switches per search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
