import SwiftUI

/// Toolbar picker: a plain `Menu` for ≤ 8 items, a popover with a search field above that.
struct SearchableMenu<Item: Identifiable>: View {
    static var searchThreshold: Int { 8 }

    let title: String
    let systemImage: String
    let items: [Item]
    let selectedID: Item.ID?
    let isLoading: Bool
    let label: (Item) -> String
    let onSelect: (Item.ID) -> Void

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        if items.count > Self.searchThreshold {
            Button {
                isPresented = true
            } label: {
                menuLabel
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { searchList }
        } else {
            Menu {
                ForEach(items) { item in
                    Button {
                        onSelect(item.id)
                    } label: {
                        row(item)
                    }
                }
            } label: {
                menuLabel
            }
            .menuIndicator(.visible)
            .disabled(items.isEmpty)
        }
    }

    private var menuLabel: some View {
        HStack(spacing: 4) {
            if isLoading { ProgressView().controlSize(.small) } else { Image(systemName: systemImage) }
            Text(current)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .help(title)
    }

    private var current: String {
        items.first { $0.id == selectedID }.map(label) ?? title
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        if item.id == selectedID {
            Label(label(item), systemImage: "checkmark")
        } else {
            Text(label(item))
        }
    }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { label($0).localizedCaseInsensitiveContains(q) }
    }

    private var searchList: some View {
        VStack(spacing: 0) {
            TextField("Search \(title.lowercased())…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(filtered) { item in
                Button {
                    onSelect(item.id)
                    isPresented = false
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 320, height: 360)
    }
}
