# Keystone

macOS Azure Key Vault secrets manager.

## Build & test
- `make build` — generate project (xcodegen) and build.
- `make test` — KeystoneKit package tests + app unit tests (incl. mock-data perf targets).
- `make test-ui` — XCUITest smoke test (`-UITestMode`: mock account, token provider and HTTP; no `az`/network).
  Separate from `make test` because it needs a GUI session and Accessibility permission.
  Launch the app manually with `-UITestMode` (and optionally `-UITestSecretCount N`) to see the mock environment.

## Install (DMG)
- `make dmg` → `build/Keystone-<version>.dmg` (Release, universal, ad-hoc signed, not notarized). Version: `MARKETING_VERSION` in `project.yml`.
- Open the DMG, drag **Keystone** to **Applications**.
- Other Macs: Gatekeeper blocks first launch → System Settings → Privacy & Security → **Open Anyway**
  (or `xattr -dr com.apple.quarantine /Applications/Keystone.app`).
- Requires macOS 26 and Azure CLI (`brew install azure-cli`).

## Integration tests (opt-in)
Skipped unless configured. Needs a logged-in `az` profile and two test vaults (one RBAC, one access policy):

```sh
KEYSTONE_IT_PROFILE_DIR=~/.keystone/profiles/<id> \
KEYSTONE_IT_TENANT=<tenant-id> \
KEYSTONE_IT_VAULT_RBAC=https://<rbac-vault>.vault.azure.net \
KEYSTONE_IT_VAULT_POLICY=https://<policy-vault>.vault.azure.net \
make test-integration
```
