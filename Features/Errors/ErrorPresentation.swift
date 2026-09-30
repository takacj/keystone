import AzureARM
import AzureCLI
import AzureCore
import Foundation

/// Something the user can do from an error banner.
enum ErrorAction: Equatable, Hashable {
    case retry
    /// One-click `az login --tenant <tenant>` (nil tenant = account's home tenant).
    case reLogin(tenant: String?)
    case copyRoleName(String)
    case openPortal
}

/// Pure mapping from `AzureAPIError` / `AzureCLIError` to user-facing copy (plan §4.3, §10).
struct ErrorPresentation: Equatable {
    var title: String
    var message: String
    /// Raw server/CLI text, shown secondary.
    var detail: String?
    var symbol = "exclamationmark.triangle"
    var actions: [ErrorAction] = []
    /// Badge to set on the vault in the sidebar, if this error says something about the vault.
    var vaultHealth: VaultHealth?

    static let readerRole = "Key Vault Secrets User"
    static let officerRole = "Key Vault Secrets Officer"

    static func make(_ error: Error, vault: Vault? = nil, tenant: String? = nil) -> ErrorPresentation {
        if let api = error as? AzureAPIError { return make(api, vault: vault, tenant: tenant) }
        if let cli = error as? AzureCLIError { return make(cli, tenant: tenant) }
        return ErrorPresentation(
            title: "Something went wrong", message: error.localizedDescription, actions: [.retry])
    }

    static func make(_ error: AzureAPIError, vault: Vault?, tenant: String?) -> ErrorPresentation {
        switch error {
        case .unauthorized(let body):
            return ErrorPresentation(
                title: "Sign-in expired",
                message: "Azure rejected the access token. Sign in again to continue.",
                detail: body?.message, symbol: "person.crop.circle.badge.exclamationmark",
                actions: [.reLogin(tenant: tenant), .retry])
        case .forbidden(let body):
            return forbidden(body, vault: vault)
        case .notFound(let body):
            return ErrorPresentation(
                title: "Not found", message: "The vault or secret doesn't exist (it may have been deleted).",
                detail: body?.message, symbol: "questionmark.folder", actions: [.retry])
        case .conflict(let body):
            return ErrorPresentation(
                title: "Name conflict",
                message: "A deleted secret with this name still exists. Recover or purge it first.",
                detail: body?.message, symbol: "arrow.triangle.2.circlepath", actions: [])
        case .throttled(let retryAfter, let body):
            let wait = retryAfter.map { " Try again in \(Int($0.rounded(.up)))s." } ?? " Try again shortly."
            return ErrorPresentation(
                title: "Too many requests", message: "Key Vault is throttling requests." + wait,
                detail: body?.message, symbol: "gauge.with.dots.needle.67percent", actions: [.retry])
        case .http(let status, let body):
            return ErrorPresentation(
                title: "Request failed (\(status))", message: body?.message ?? "Azure returned HTTP \(status).",
                detail: body?.code, actions: [.retry])
        case .network(let code):
            return network(code, vault: vault)
        case .decoding(let text):
            return ErrorPresentation(
                title: "Unexpected response", message: "Couldn't read Azure's response.", detail: text,
                actions: [.retry])
        case .invalidURL(let text):
            return ErrorPresentation(title: "Invalid URL", message: text)
        }
    }

    static func make(_ error: AzureCLIError, tenant: String?) -> ErrorPresentation {
        switch error {
        case .interactionRequired(let code, let message):
            return ErrorPresentation(
                title: "Additional sign-in required",
                message: "This tenant needs MFA or Conditional Access verification. "
                    + "Sign in again to \(tenant.map { "tenant \($0)" } ?? "the tenant").",
                detail: [code, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "),
                symbol: "lock.rotation", actions: [.reLogin(tenant: tenant), .retry])
        case .loginRequired(let message):
            return ErrorPresentation(
                title: "Sign-in required", message: "Your Azure CLI session expired. Sign in again.",
                detail: message.isEmpty ? nil : message, symbol: "person.crop.circle.badge.exclamationmark",
                actions: [.reLogin(tenant: tenant), .retry])
        case .notFound:
            return ErrorPresentation(
                title: "Azure CLI not found", message: error.localizedDescription, symbol: "terminal")
        default:
            return ErrorPresentation(
                title: "Azure CLI error", message: error.localizedDescription, actions: [.retry])
        }
    }

    private static func forbidden(_ body: AzureErrorBody?, vault: Vault?) -> ErrorPresentation {
        var result = ErrorPresentation(
            title: "No permission", message: "", detail: body?.message, symbol: "lock",
            actions: [.retry], vaultHealth: .accessDenied)
        switch vault?.enableRbacAuthorization {
        case true:
            result.message =
                "This vault uses Azure RBAC. Ask an owner to assign you “\(readerRole)” (read) or "
                + "“\(officerRole)” (read/write) on the vault."
            result.actions = [.copyRoleName(readerRole), .copyRoleName(officerRole), .openPortal, .retry]
        case false:
            result.message =
                "This vault uses access policies. Add a policy for your identity with secret permissions "
                + "Get and List (plus Set/Delete to edit)."
            result.actions = [.openPortal, .retry]
        default:
            result.message =
                "You need the “\(readerRole)” or “\(officerRole)” role (RBAC vaults), or an access policy "
                + "with Get/List/Set (policy vaults)."
            result.actions = [.copyRoleName(readerRole), .copyRoleName(officerRole), .retry]
        }
        return result
    }

    private static func network(_ code: URLError.Code, vault: Vault?) -> ErrorPresentation {
        if code == .notConnectedToInternet || code == .networkConnectionLost {
            return ErrorPresentation(
                title: "You're offline", message: "No internet connection.", symbol: "wifi.slash",
                actions: [.retry])
        }
        return ErrorPresentation(
            title: "Vault unreachable",
            message: "Couldn't connect\(vault.map { " to \($0.name)" } ?? ""). The vault may have a firewall "
                + "or private endpoint enabled — connect via VPN / an allowed network, or add your IP in the portal.",
            detail: "URLError \(code.rawValue)", symbol: "network.slash",
            actions: [.openPortal, .retry], vaultHealth: .unreachable)
    }
}
