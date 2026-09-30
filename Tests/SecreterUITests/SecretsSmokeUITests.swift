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
        if !app.windows.firstMatch.waitForExistence(timeout: 5) { app.typeKey("n", modifierFlags: .command) }

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
}
