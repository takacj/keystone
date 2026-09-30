import XCTest

@testable import Keystone

final class ProdGuardTests: XCTestCase {
    func testDefaultsMatchCaseInsensitive() {
        let g = ProdGuard()
        XCTAssertTrue(g.isProduction(subscriptionName: "Contoso-PROD", vaultName: "kv-x"))
        XCTAssertTrue(g.isProduction(subscriptionName: "dev", vaultName: "kv-prd-01"))
        XCTAssertTrue(g.isProduction(subscriptionName: nil, vaultName: "Live-secrets"))
        XCTAssertFalse(g.isProduction(subscriptionName: "dev", vaultName: "kv-test"))
        XCTAssertFalse(g.isProduction(subscriptionName: nil, vaultName: nil))
    }

    func testWholeTokenMatching() {
        let g = ProdGuard()
        XCTAssertTrue(g.matches("kv-prod-weu"))
        XCTAssertTrue(g.matches("myapp_prd"))
        XCTAssertTrue(g.matches("Contoso Live"))
        XCTAssertFalse(g.matches("delivery"))
        XCTAssertTrue(g.matches("kv-production"))
        XCTAssertTrue(g.matches("liveapp"))
        XCTAssertFalse(g.matches("reproduce"))
    }

    func testMultiTokenPattern() {
        let g = ProdGuard(patterns: ["eu-live"])
        XCTAssertTrue(g.matches("kv-eu-live-01"))
        XCTAssertFalse(g.matches("live-eu"))
    }

    func testCustomPatternsTrimmedAndEmptyIgnored() {
        let g = ProdGuard(patterns: [" Stage ", "", "  "])
        XCTAssertEqual(g.patterns, ["stage"])
        XCTAssertTrue(g.matches("my-STAGE-vault"))
        XCTAssertTrue(g.matches("stagecoach"))
        XCTAssertFalse(g.matches("upstage"))
        XCTAssertFalse(g.matches("prod"))
        XCTAssertFalse(ProdGuard(patterns: []).matches("prod"))
    }

    func testUserDefaultsPatterns() {
        let d = UserDefaults(suiteName: "ProdGuardTests-\(UUID())")!
        XCTAssertEqual(ProdGuard.current(defaults: d).patterns, ProdGuard.defaultPatterns)
        d.set(["eu-live"], forKey: ProdGuard.defaultsKey)
        XCTAssertEqual(ProdGuard.current(defaults: d).patterns, ["eu-live"])
    }

    func testTypedConfirmRule() {
        XCTAssertTrue(ProdConfirmRule.isSatisfied(typed: "", required: nil))
        XCTAssertFalse(ProdConfirmRule.isSatisfied(typed: "db-pass", required: "DB-pass"))
        XCTAssertTrue(ProdConfirmRule.isSatisfied(typed: "db-pass ", required: "db-pass"))
    }
}
