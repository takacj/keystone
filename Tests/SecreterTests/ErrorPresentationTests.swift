import AzureARM
import AzureCLI
import AzureCore
import Foundation
import Testing

@testable import Secreter

struct ErrorPresentationTests {
    private func vault(rbac: Bool) -> Vault {
        Vault(
            id: "/subscriptions/s/resourceGroups/r/providers/Microsoft.KeyVault/vaults/kv", name: "kv",
            location: "westeurope", resourceGroup: "r", subscriptionId: "s",
            vaultUri: URL(string: "https://kv.vault.azure.net")!, enableRbacAuthorization: rbac)
    }

    @Test func forbiddenRBACOffersRoleCopy() {
        let p = ErrorPresentation.make(AzureAPIError.forbidden(nil), vault: vault(rbac: true))
        #expect(p.message.contains("RBAC"))
        #expect(p.actions.contains(.copyRoleName("Key Vault Secrets User")))
        #expect(p.actions.contains(.copyRoleName("Key Vault Secrets Officer")))
        #expect(p.vaultHealth == .accessDenied)
    }

    @Test func forbiddenPolicyMentionsAccessPolicy() {
        let p = ErrorPresentation.make(AzureAPIError.forbidden(nil), vault: vault(rbac: false))
        #expect(p.message.contains("access polic"))
        #expect(!p.actions.contains(.copyRoleName("Key Vault Secrets User")))
    }

    @Test func forbiddenUnknownVaultMentionsBoth() {
        let p = ErrorPresentation.make(AzureAPIError.forbidden(nil))
        #expect(p.message.contains("Key Vault Secrets User") && p.message.contains("access policy"))
    }

    @Test func unauthorizedOffersReLoginWithTenant() {
        let p = ErrorPresentation.make(AzureAPIError.unauthorized(nil), tenant: "t1")
        #expect(p.actions.first == .reLogin(tenant: "t1"))
    }

    @Test func aadstsInteractionOffersReLogin() {
        let e = AzureCLIError.interactionRequired(code: "AADSTS50076", message: "MFA")
        let p = ErrorPresentation.make(e, tenant: "t1")
        #expect(p.actions.first == .reLogin(tenant: "t1"))
        #expect(p.detail?.contains("AADSTS50076") == true)
        let login = ErrorPresentation.make(AzureCLIError.loginRequired(message: ""), tenant: nil)
        #expect(login.actions.first == .reLogin(tenant: nil))
    }

    @Test func networkMarksUnreachable() {
        let p = ErrorPresentation.make(AzureAPIError.network(.cannotConnectToHost), vault: vault(rbac: true))
        #expect(p.message.contains("firewall"))
        #expect(p.vaultHealth == .unreachable)
        #expect(ErrorPresentation.make(AzureAPIError.network(.notConnectedToInternet)).vaultHealth == nil)
    }

    @Test func throttledAndConflict() {
        let t = ErrorPresentation.make(AzureAPIError.throttled(retryAfter: 2.2, nil))
        #expect(t.message.contains("3s") && t.actions == [.retry])
        let conflict = ErrorPresentation.make(AzureAPIError.conflict(nil))
        #expect(conflict.message.contains("deleted secret"))
    }

    @Test func unknownErrorFallsBack() {
        struct Boom: Error {}
        #expect(ErrorPresentation.make(Boom()).actions == [.retry])
    }
}
