# Keystone

A native macOS app for browsing, searching and editing Azure Key Vault secrets across multiple
accounts, tenants, subscriptions and vaults.

## Features
- Several Azure accounts side by side, each in its own isolated Azure CLI profile.
- Tenant → subscription → vault navigation with favorites and recents.
- Fast secrets table with fuzzy filtering, sorting and filter chips (enabled, disabled, expiring, expired, tag).
- Masked values with reveal, auto re-mask and concealed copy to the clipboard.
- Create secrets, set new values, edit metadata, and undo.
- Version history with restore; soft delete, recover and purge.
- ⌘K command palette that searches secret names across every vault in a tenant.
- ⇧⌘F search by value: finds which secrets hold a given value in the current vault, subscription or tenant
  (values are read and compared in memory, never stored).
- Touch ID app lock, extra confirmation for production vaults, readable Azure error messages.

## How it works
- Authentication goes through the Azure CLI (`az`). No app registration or client secret is needed.
- Each account gets its own `AZURE_CONFIG_DIR` under `~/Library/Application Support/Keystone/profiles`,
  so your normal `~/.azure` login is never touched.
- Keystone keeps access tokens and secret values in memory only. On disk it stores account names,
  selections and settings, never secret values. The Azure CLI keeps its own login cache inside each
  profile folder, as it does in `~/.azure`.
- Keystone uses your own permissions: RBAC roles (Key Vault Secrets User / Officer) or access policies.

## Requirements
- macOS 26
- Azure CLI 2.60 or later: `brew install azure-cli`
- To build: Xcode 26, `brew install xcodegen swiftlint swift-format`

## Install
- `make dmg` builds `build/Keystone-<version>.dmg` (Release, universal, ad-hoc signed, not notarized).
- Open the DMG and drag **Keystone** to **Applications**.
- The app isn't notarized, so macOS blocks the first launch on other Macs: open System Settings →
  Privacy & Security → **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Keystone.app`.

## Build & test
- `make build`: generate the Xcode project (XcodeGen) and build.
- `make test`: KeystoneKit package tests plus app unit tests, including performance checks on mock data.
- `make test-ui`: XCUITest smoke tests against a mock environment (`-UITestMode`: mock account, tokens
  and HTTP; no `az` or network). Needs a GUI session and Accessibility permission, and takes over the
  mouse and keyboard while it runs.
- `make lint` / `make format`: SwiftLint and swift-format.
- Launch the app with `-UITestMode` (optionally `-UITestSecretCount N`) to try it without Azure.

### Integration tests (opt-in)
Skipped unless configured. They need a logged-in Keystone profile and two test vaults, one using RBAC and
one using access policies:

```sh
KEYSTONE_IT_PROFILE_DIR="$HOME/Library/Application Support/Keystone/profiles/<id>" \
KEYSTONE_IT_TENANT=<tenant-id> \
KEYSTONE_IT_VAULT_RBAC=https://<rbac-vault>.vault.azure.net \
KEYSTONE_IT_VAULT_POLICY=https://<policy-vault>.vault.azure.net \
make test-integration
```

## Project layout
- `App/`, `Features/`: the SwiftUI app (models and views).
- `KeystoneKit/`: Swift package with the Azure CLI runner, token provider, ARM and Key Vault clients,
  search and persistence.
- `Tests/`: app unit tests and UI tests.

## License
MIT. See [LICENSE](LICENSE).
