import KeyVaultSecrets
import SwiftUI

/// Sheet for creating (⌘N) or editing (⌘E) a secret; ⌘↩ saves.
struct SecretEditorSheet: View {
    @Environment(SecretEditorCoordinator.self) private var editor
    @Environment(SecretsModel.self) private var secrets
    @Environment(ContextModel.self) private var context
    @State private var confirmingSave = false
    @Bindable var model: SecretEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.mode == .create ? "New secret" : "Edit secret").font(.headline)
                Text(model.vault.name).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                if model.mode == .create {
                    TextField("Name", text: $model.name)
                    if let e = model.nameError { hint(e) }
                } else {
                    LabeledContent("Name", value: model.name)
                }
                Section("Value") {
                    TextEditor(text: $model.value)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    if model.mode == .edit {
                        hint("Changing the value creates a new version.")
                    }
                }
                TextField("Content type", text: $model.contentType, prompt: Text("e.g. text/plain"))
                Toggle("Enabled", isOn: $model.enabled)
                Toggle("Activation date", isOn: $model.hasNotBefore)
                if model.hasNotBefore { DatePicker("Not before", selection: $model.notBefore) }
                Toggle("Expiry date", isOn: $model.hasExpiry)
                if model.hasExpiry { DatePicker("Expires", selection: $model.expires) }
                if let e = model.dateError { hint(e) }
                tagsSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error = model.error {
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { editor.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(model.mode == .create ? "Create" : "Save") {
                    if context.isProduction { confirmingSave = true } else { Task { await editor.save() } }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }
            .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520)
        .prodConfirmation(
            isPresented: $confirmingSave,
            title: model.mode == .create ? "Create secret in production?" : "Save changes in production?",
            message: "“\(model.name)” lives in a production vault.",
            actionTitle: model.mode == .create ? "Create" : "Save"
        ) { Task { await editor.save() } }
        .deletedConflictPrompt(vault: model.vault, name: $model.conflictName) { _ in
            Task { await editor.save() }
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            ForEach($model.tags) { $tag in
                HStack {
                    TextField("Key", text: $tag.key)
                    TextField("Value", text: $tag.value)
                    Button("Remove", systemImage: "minus.circle") {
                        model.tags.removeAll { $0.id == tag.id }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            Button("Add tag", systemImage: "plus") { model.tags.append(.init()) }
                .buttonStyle(.borderless)
            if let e = model.tagError { hint(e) }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Bottom toast after a save, with Undo when the change is revertible.
struct SecretEditorToast: View {
    @Environment(SecretEditorCoordinator.self) private var editor

    var body: some View {
        Group {
            if let toast = editor.toast {
                HStack(spacing: 12) {
                    Label(toast.message, systemImage: "checkmark.circle.fill")
                    if toast.undo != nil {
                        Button("Undo") { Task { await editor.undo() } }
                            .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect()
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.default, value: editor.toast?.id)
    }
}
