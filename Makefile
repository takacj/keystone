.PHONY: project build test test-kit test-app test-ui test-integration dmg lint format clean

DEST = platform=macOS
SWIFT_DIRS = App Features Tests KeystoneKit/Sources KeystoneKit/Tests

project:
	xcodegen generate

build: project
	xcodebuild -project Keystone.xcodeproj -scheme Keystone -destination '$(DEST)' build

test-kit:
	cd KeystoneKit && swift test

test-app: project
	xcodebuild -project Keystone.xcodeproj -scheme Keystone -destination '$(DEST)' test

test: test-kit test-app

# XCUITest smoke test against the -UITestMode mock environment. Needs a logged-in GUI session
# (and Accessibility permission for Xcode/terminal), so it is not part of `make test`.
test-ui: project
	xcodebuild -project Keystone.xcodeproj -scheme KeystoneUI -destination '$(DEST)' test

# Opt-in tests against real Azure test vaults. Required env: KEYSTONE_IT_PROFILE_DIR, KEYSTONE_IT_TENANT,
# KEYSTONE_IT_VAULT_RBAC, KEYSTONE_IT_VAULT_POLICY (without them the tests are skipped).
test-integration: project
	TEST_RUNNER_KEYSTONE_IT_PROFILE_DIR='$(KEYSTONE_IT_PROFILE_DIR)' \
	TEST_RUNNER_KEYSTONE_IT_TENANT='$(KEYSTONE_IT_TENANT)' \
	TEST_RUNNER_KEYSTONE_IT_VAULT_RBAC='$(KEYSTONE_IT_VAULT_RBAC)' \
	TEST_RUNNER_KEYSTONE_IT_VAULT_POLICY='$(KEYSTONE_IT_VAULT_POLICY)' \
	xcodebuild -project Keystone.xcodeproj -scheme Keystone -destination '$(DEST)' test -only-testing:KeystoneTests/IntegrationTests

# Release build packaged as a drag-to-Applications DMG (ad-hoc signed, not notarized).
# On another Mac, Gatekeeper blocks the first launch: System Settings → Privacy & Security → Open Anyway.
VERSION = $(shell sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
DMG = build/Keystone-$(VERSION).dmg

dmg: project
	xcodebuild -project Keystone.xcodeproj -scheme Keystone -configuration Release \
		-destination '$(DEST)' -derivedDataPath build/DerivedData build
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R build/DerivedData/Build/Products/Release/Keystone.app build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "Keystone $(VERSION)" -srcfolder build/dmg -fs HFS+ -format UDZO -ov $(DMG)
	rm -rf build/dmg
	@echo "Created $(DMG)"

lint:
	swiftlint lint --strict
	swift-format lint --strict --recursive $(SWIFT_DIRS)

format:
	swift-format format --in-place --recursive $(SWIFT_DIRS)

clean:
	rm -rf Keystone.xcodeproj build KeystoneKit/.build
