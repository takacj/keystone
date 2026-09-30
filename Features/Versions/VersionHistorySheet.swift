import KeyVaultSecrets
import SwiftUI

/// Versions of a secret, newest first; select one to view it (masked) and restore it.
struct VersionHistorySheet: View {
    @Bindable var model: VersionHistoryModel
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ContextModel.self) private var context
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Versions of \(model.name)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: 620, height: 460)
        .task { await model.load() }
        .onDisappear { model.clear() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.mask()
        }
        .prodConfirmation(
            isPresented: Binding(get: { confirming && context.isProduction }, set: { confirming = $0 }),
            title: "Restore this version in production?",
            message: "The old value becomes the new current version of a production secret.",
            actionTitle: "Restore", onConfirm: onRestore
        )
        .confirmationDialog(
            "Restore this version?",
            isPresented: Binding(get: { confirming && !context.isProduction }, set: { confirming = $0 })
        ) {
            Button("Restore") { onRestore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old value is saved as a new current version. Older versions are kept.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Couldn't load versions", systemImage: "exclamationmark.triangle",
                description: Text(model.error?.localizedDescription ?? ""))
        case .loaded:
            HSplitView {
                list.frame(minWidth: 240)
                detail.frame(minWidth: 260)
            }
        }
    }

    private var list: some View {
        List(
            model.versions,
            selection: Binding(
                get: { model.selectedVersion },
                set: { v in if let v { Task { await model.select(v) } } })
        ) { item in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.version ?? "—").font(.system(.callout, design: .monospaced)).lineLimit(1)
                    if model.isCurrent(item) { Text("current").font(.caption2.bold()).foregroundStyle(.tint) }
                    Spacer()
                    if item.attributes?.enabled == false { Text("disabled").font(.caption).foregroundStyle(.red) }
                }
                Text(dateText(item.attributes?.created ?? item.attributes?.updated))
                    .font(.caption).foregroundStyle(.secondary)
                if let exp = item.attributes?.expires {
                    Text("Expires \(dateText(exp))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tag(item.version)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.selectedVersion == nil {
                ContentUnavailableView("Select a version", systemImage: "clock.arrow.circlepath")
            } else {
                HStack {
                    Text("Value").font(.headline)
                    Spacer()
                    Button(
                        model.isRevealed ? "Hide" : "Reveal", systemImage: model.isRevealed ? "eye.slash" : "eye"
                    ) { model.toggleReveal() }
                    .labelStyle(.iconOnly)
                    .disabled(model.selectedBundle?.value == nil)
                }
                Group {
                    if model.isLoadingValue {
                        ProgressView()
                    } else if model.isRevealed {
                        Text(model.displayValue).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text(String(repeating: "•", count: 12)).font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary).accessibilityLabel("Value hidden")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                if let type = model.selectedBundle?.contentType, !type.isEmpty {
                    Text(type).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Restore this version") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRestore)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dateText(_ d: Date?) -> String {
        d?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }
}
