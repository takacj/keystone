# Contributing to Keystone

Thanks for your interest! Bug reports, ideas and pull requests are welcome.

## Before you start
- Search [existing issues](https://github.com/takacj/keystone/issues) and pull requests first.
- For anything non-trivial (new features, behavior changes, refactors), open an issue to discuss it
  before writing code.
- Security problems: do **not** open a public issue. See [SECURITY.md](SECURITY.md).

## Setup
- macOS 26, Xcode 26, Azure CLI 2.60+
- `brew install xcodegen swiftlint swift-format`
- `make build` generates the Xcode project and builds the app.
- No Azure account needed for development: run with `-UITestMode -UITestDemo` (see the README).

## Workflow
1. Fork the repo and add `upstream`: `git remote add upstream https://github.com/takacj/keystone.git`
2. Create a branch per logical change off the latest `main`: `git switch -c fix/short-description`
3. Keep it current by rebasing: `git fetch upstream && git rebase upstream/main`
4. Make small, focused commits. The message says *why*, not just *what*.
5. Don't mix in unrelated reformatting, dependency bumps or refactors.
6. Before pushing, run:
   ```sh
   make format
   make lint
   make test
   ```
7. Open a pull request using the template. Draft PRs are welcome for early feedback.

## Pull requests
- One logical change per PR; keep it small.
- Describe what changed, why, and how you tested it. Link issues (`Fixes #123`).
- Add or update tests and docs (README, CHANGELOG under `Unreleased`).
- CI must be green before review.
- UI changes: include a screenshot, captured with `-UITestDemo` mock data.

## Never commit
- Secrets, tokens, tenant/subscription IDs, vault URLs from real environments, personal data.
- Local config (`xcuserdata`, `.env`, profiles). Check `git diff --staged` before committing.
- Optional: install [pre-commit](https://pre-commit.com) and run `pre-commit install` to scan staged
  changes with gitleaks.

## Releases
Maintainers use [semver](https://semver.org), tag releases as `vX.Y.Z`, and update
[CHANGELOG.md](CHANGELOG.md).

## Code of conduct
This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
