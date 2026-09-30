.PHONY: project build test test-kit test-app test-ui test-integration lint format clean

DEST = platform=macOS
SWIFT_DIRS = App Features Tests SecreterKit/Sources SecreterKit/Tests

project:
	xcodegen generate

build: project
	xcodebuild -project Secreter.xcodeproj -scheme Secreter -destination '$(DEST)' build

test-kit:
	cd SecreterKit && swift test

test-app: project
	xcodebuild -project Secreter.xcodeproj -scheme Secreter -destination '$(DEST)' test

test: test-kit test-app

# XCUITest smoke test against the -UITestMode mock environment. Needs a logged-in GUI session
# (and Accessibility permission for Xcode/terminal), so it is not part of `make test`.
test-ui: project
	xcodebuild -project Secreter.xcodeproj -scheme SecreterUI -destination '$(DEST)' test

# Opt-in tests against real Azure test vaults. Required env: SECRETER_IT_PROFILE_DIR, SECRETER_IT_TENANT,
# SECRETER_IT_VAULT_RBAC, SECRETER_IT_VAULT_POLICY (without them the tests are skipped).
test-integration: project
	TEST_RUNNER_SECRETER_IT_PROFILE_DIR='$(SECRETER_IT_PROFILE_DIR)' \
	TEST_RUNNER_SECRETER_IT_TENANT='$(SECRETER_IT_TENANT)' \
	TEST_RUNNER_SECRETER_IT_VAULT_RBAC='$(SECRETER_IT_VAULT_RBAC)' \
	TEST_RUNNER_SECRETER_IT_VAULT_POLICY='$(SECRETER_IT_VAULT_POLICY)' \
	xcodebuild -project Secreter.xcodeproj -scheme Secreter -destination '$(DEST)' test -only-testing:SecreterTests/IntegrationTests

lint:
	swiftlint lint --strict
	swift-format lint --strict --recursive $(SWIFT_DIRS)

format:
	swift-format format --in-place --recursive $(SWIFT_DIRS)

clean:
	rm -rf Secreter.xcodeproj build SecreterKit/.build
