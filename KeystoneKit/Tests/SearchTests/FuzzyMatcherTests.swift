import Foundation
import Testing

@testable import Search

@Suite struct FuzzyMatcherTests {
    @Test func subsequenceAndRanges() throws {
        let m = try #require(FuzzyMatcher(query: "dbc").match("db-connection"))
        #expect(m.ranges == [0..<2, 3..<4])
        #expect(FuzzyMatcher(query: "xyz").match("db-connection") == nil)
        #expect(FuzzyMatcher(query: "cd").match("dc") == nil)
    }

    @Test func caseInsensitiveAndWhitespace() throws {
        let m = try #require(FuzzyMatcher(query: "API key").match("Api-Key"))
        #expect(m.ranges == [0..<3, 4..<7])
    }

    @Test func emptyQueryMatchesAll() {
        #expect(FuzzyMatcher(query: "  ").match("abc") == FuzzyMatch(score: 0, ranges: []))
    }

    @Test func rankingPrefersConsecutiveAndBoundaries() {
        let items = ["xxapixkey", "api-key", "a-x-p-x-i-x-key"]
        let r = FuzzyMatcher(query: "apikey").filter(items) { $0 }
        #expect(r.first?.item == "api-key")
        #expect(r.count == 3)
    }

    @Test func prefersBoundaryOverMidWord() throws {
        let a = try #require(FuzzyMatcher(query: "key").match("my-key"))
        let b = try #require(FuzzyMatcher(query: "key").match("monkeys"))
        #expect(a.score > b.score)
    }

    @Test func filterKeepsOrderForEmptyQuery() {
        let r = FuzzyMatcher(query: "").filter(["b", "a"]) { $0 }
        #expect(r.map(\.item) == ["b", "a"])
    }

    @Test func perf1kItemsUnder16ms() {
        let words = ["api", "db", "jwt", "prod", "kafka", "redis", "storage", "connection", "string", "key"]
        let names = (0..<1000).map { i in
            "\(words[i % 10])-\(words[(i / 10) % 10])-\(words[(i / 100) % 10])-\(i)"
        }
        let matcher = FuzzyMatcher(query: "dbconn")
        var best = Double.infinity
        var count = 0
        for _ in 0..<5 {
            let t = ContinuousClock.now
            count = matcher.filter(names) { $0 }.count
            let d = ContinuousClock.now - t
            best = min(best, Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        #expect(count > 0)
        #expect(best < 16, "filter took \(best) ms")
    }
}
