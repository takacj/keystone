import SwiftUI

/// Toolbar tenant and subscription pickers.
struct ContextPickers: View {
    @Environment(ContextModel.self) private var context

    var body: some View {
        SearchableMenu(
            title: "Tenant", systemImage: "building.2", items: context.tenants,
            selectedID: context.selectedTenantID, isLoading: context.tenantsPhase == .loading,
            label: { $0.displayName ?? $0.defaultDomain ?? $0.tenantId },
            onSelect: { context.selectTenant($0) })
        SearchableMenu(
            title: "Subscription", systemImage: "key.horizontal", items: context.subscriptions,
            selectedID: context.selectedSubscriptionID, isLoading: context.subscriptionsPhase == .loading,
            label: { $0.displayName },
            onSelect: { context.selectSubscription($0) })
    }
}
