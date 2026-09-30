import AzureAuth
import SwiftUI

/// Searchable list for ⇧⌘A / ⇧⌘T / ⇧⌘S (switch account / tenant / subscription).
struct QuickSwitchItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isCurrent: Bool

    static func filter(_ items: [QuickSwitchItem], query: String) -> [QuickSwitchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
}

struct QuickSwitchSheet: View {
    let kind: QuickSwitchKind
    let items: [QuickSwitchItem]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [QuickSwitchItem] { QuickSwitchItem.filter(items, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Switch \(kind.rawValue.lowercased())…", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(12)
                .focused($focused)
                .onSubmit { if let first = filtered.first { pick(first) } }
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass").frame(maxHeight: .infinity)
            } else {
                List(filtered) { item in
                    Button {
                        pick(item)
                    } label: {
                        HStack {
                            Text(item.title)
                            Spacer()
                            if item.isCurrent { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 320)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func pick(_ item: QuickSwitchItem) {
        onSelect(item.id)
        dismiss()
    }
}
