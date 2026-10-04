# Security Policy

Keystone handles Azure credentials and Key Vault secret values, so security reports are taken seriously.

## Supported versions
Only the latest release receives security fixes.

## Reporting a vulnerability
**Do not open a public issue.** Report privately via
[GitHub private vulnerability reporting](https://github.com/takacj/keystone/security/advisories/new).

Please include:
- Affected version and macOS version
- Steps to reproduce, or a proof of concept
- Impact (e.g. secret value written to disk, logged, or exposed to another process)

Never include real secrets, tokens or tenant details in a report.

You can expect an acknowledgement within 7 days. Fixes are released as a patch version and credited
in the advisory unless you prefer otherwise.

## Scope
- In scope: the Keystone app and KeystoneKit package in this repository.
- Out of scope: Azure CLI, Azure services, and macOS itself; report those to their vendors.
