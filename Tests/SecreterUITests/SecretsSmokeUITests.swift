import XCTest

/// Launches Secreter with `-UITestMode` (mock account, token provider and HTTP transport) and walks the
/// main flow: pick vault → secrets table → filter → select → reveal → ⌘K palette.
final class SecretsSmokeUITests: XCTestCase {
    private let timeout: TimeInterval = 15

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testBrowseFilterRevealAndPalette() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: [.command, .shift]) }

        // Pick a vault.
        let vault = app.staticTexts["kv-dev"].firstMatch
        XCTAssertTrue(vault.waitForExistence(timeout: timeout), "vault not listed")
        vault.click()

        // Secrets table shows rows.
        let table = app
        let dbRow = table.staticTexts["db-password"]
        XCTAssertTrue(dbRow.waitForExistence(timeout: timeout), "rows not loaded")
        XCTAssertTrue(table.staticTexts["api-key"].exists)

        // Filter.
        let filter = app.textFields["secrets.filter"]
        filter.click()
        filter.typeText("jwt")
        XCTAssertTrue(table.staticTexts["jwt-signing-key"].waitForExistence(timeout: timeout))
        XCTAssertTrue(dbRow.waitForNonExistence(timeout: timeout), "filter did not hide rows")

        // Select → value masked → reveal.
        table.staticTexts["jwt-signing-key"].click()
        let hidden = app.descendants(matching: .any)["secret.value.hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: timeout), "value should be masked initially")
        app.buttons["secret.reveal"].click()
        let value = app.staticTexts["secret.value"]
        XCTAssertTrue(value.waitForExistence(timeout: timeout))
        XCTAssertEqual(value.value as? String, "s3cr3t-jwt-signing-key")

        // ⌘K palette finds a secret of the vault.
        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: timeout), "palette did not open")
        query.click()
        query.typeText("apikey")
        XCTAssertEqual(query.value as? String, "apikey")
        let row = app.descendants(matching: .any)["palette.row.api-key"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "palette did not find api-key")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts["api-key"].firstMatch.waitForExistence(timeout: timeout), "palette did not open api-key")
    }

    /// Version history: clicking an older version loads its own value (regression: row id was sent as version).
    @MainActor
    func testOlderVersionValueLoads() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: [.command, .shift]) }

        let vault = app.staticTexts["kv-dev"].firstMatch
        XCTAssertTrue(vault.waitForExistence(timeout: timeout), "vault not listed")
        vault.click()
        let row = app.staticTexts["db-password"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "rows not loaded")
        row.click()
        XCTAssertTrue(app.buttons["secret.reveal"].waitForExistence(timeout: timeout), "detail not loaded")

        app.typeKey("y", modifierFlags: .command)
        let older = app.staticTexts["v0"].firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: timeout), "versions not listed")
        older.click()
        let reveal = app.buttons["version.reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: timeout))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: reveal)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(app.staticTexts["version.error"].exists, "older version failed to load")
        reveal.click()
        let value = app.staticTexts["version.value"]
        XCTAssertTrue(value.waitForExistence(timeout: timeout))
        XCTAssertEqual(value.value as? String, "s3cr3t-db-password-v0")
    }

    /// Editor sheet opens for edit (⌘E) and create (⌘N) without crashing (regression: sheet was outside the
    /// scope of MainView's environment objects).
    @MainActor
    func testEditorSheetOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: [.command, .shift]) }

        let vault = app.staticTexts["kv-dev"].firstMatch
        XCTAssertTrue(vault.waitForExistence(timeout: timeout), "vault not listed")
        vault.click()
        let row = app.staticTexts["db-password"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "rows not loaded")
        row.click()
        XCTAssertTrue(app.buttons["secret.reveal"].waitForExistence(timeout: timeout), "detail not loaded")

        app.typeKey("e", modifierFlags: .command)
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: timeout), "edit sheet did not open")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: timeout), "edit sheet did not close")

        app.typeKey("n", modifierFlags: .command)
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: timeout), "create sheet did not open")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(create.waitForNonExistence(timeout: timeout), "create sheet did not close")
        XCTAssertEqual(app.state, .runningForeground, "app crashed")
    }

    /// Escape closes the ⌘K palette and the clear-filters empty state resets the table.
    @MainActor
    func testPaletteEscapeAndEmptyFilterState() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: [.command, .shift]) }
        app.staticTexts["kv-dev"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["db-password"].waitForExistence(timeout: timeout))

        app.typeKey("k", modifierFlags: .command)
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: timeout))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(query.waitForNonExistence(timeout: timeout), "Escape did not close the palette")

        let filter = app.textFields["secrets.filter"]
        filter.click()
        filter.typeText("zzzz-no-match")
        let clear = app.buttons["Clear Filters"]
        XCTAssertTrue(clear.waitForExistence(timeout: timeout), "empty filter state missing")
        clear.click()
        XCTAssertTrue(app.staticTexts["db-password"].waitForExistence(timeout: timeout))
    }

    @MainActor
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"] + extra
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: [.command, .shift]) }
        return app
    }

    /// Production vault: delete needs the typed secret name before the button enables.
    @MainActor
    func testProdDeleteRequiresTypedName() {
        let app = launch(["-UITestProd"])
        app.descendants(matching: .any)["kv-prod-weu"].firstMatch.click()
        let row = app.staticTexts["db-password"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.click()
        app.typeKey(.delete, modifierFlags: .command)
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "typed confirmation missing")
        let confirm = app.sheets.buttons["Delete"].firstMatch
        XCTAssertFalse(confirm.isEnabled)
        field.typeText("db-password")
        XCTAssertTrue(confirm.isEnabled)
    }

    /// `-UITestLock` keeps the lock screen up (authenticator never succeeds).
    @MainActor
    func testLockScreenShown() {
        let app = launch(["-UITestLock"])
        XCTAssertTrue(app.staticTexts["Secreter is locked"].waitForExistence(timeout: timeout))
    }

    @MainActor
    func testOnboardingShownWithoutAccounts() {
        let app = launch(["-UITestOnboarding"])
        XCTAssertTrue(app.staticTexts["Welcome to Secreter"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["Sign in with Azure"].exists)
    }
}
