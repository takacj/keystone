# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.1] - 2026-10-08
### Fixed
- Stray blue focus ring along the detail pane edge after clicking it.

## [1.1.0] - 2026-10-05
### Added
- Search by value across Key Vaults (⇧⌘F), in the current vault, subscription or tenant.
- Demo mock data (`-UITestDemo`) and README screenshots.
- Contributor docs, issue/PR templates, CI, CodeQL and Dependabot.
- Tag-triggered release workflow publishing the DMG, checksum and provenance attestation.

### Changed
- Vault list keeps its position on refresh; sidebar respects the active filter.

### Fixed
- Production vault confirmation.

## [1.0.0] - 2026-09-30
### Added
- First public release: native macOS app for browsing, searching and editing Azure Key Vault secrets
  across accounts, tenants and subscriptions.

[Unreleased]: https://github.com/takacj/keystone/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/takacj/keystone/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/takacj/keystone/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/takacj/keystone/releases/tag/v1.0.0
