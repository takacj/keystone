import Foundation

/// Result of a fuzzy match: relevance score and matched ranges (UTF-16 offsets into the candidate).
public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    public let ranges: [Range<Int>]

    public init(score: Int, ranges: [Range<Int>]) {
        self.score = score
        self.ranges = ranges
    }
}

/// Case-insensitive subsequence matcher with scoring (consecutive runs and word-boundary hits rank higher).
///
/// Whitespace in the query is ignored. Ranges are UTF-16 offsets, convertible via `String.UTF16View`.
public struct FuzzyMatcher: Sendable {
    private static let matchScore = 16
    private static let consecutiveBonus = 8
    private static let boundaryBonus = 10
    private static let camelBonus = 6
    private static let gapPenalty = 1
    private static let none = Int.min / 2

    private let query: [UInt16]

    public init(query: String) {
        self.query = query.utf16.filter { !Self.isSpace($0) }.map(Self.fold)
    }

    public var isEmpty: Bool { query.isEmpty }

    /// Matches `candidate`; `nil` when the query is not a subsequence. An empty query matches everything.
    public func match(_ candidate: String) -> FuzzyMatch? {
        let n = query.count
        if n == 0 { return FuzzyMatch(score: 0, ranges: []) }
        let c = Array(candidate.utf16)
        let m = c.count
        if n > m { return nil }

        // Fast subsequence pre-check (most candidates fail here).
        var qi = 0
        for u in c where Self.fold(u) == query[qi] {
            qi += 1
            if qi == n { break }
        }
        if qi < n { return nil }

        let none = Self.none
        var dp = [Int](repeating: none, count: n * m)
        var parent = [Int](repeating: -1, count: n * m)

        for j in 0..<m where Self.fold(c[j]) == query[0] {
            dp[j] = Self.matchScore + Self.boundary(c, j) - min(j, 8)
        }
        if n > 1 {
            for i in 1..<n {
                var gVal = none
                var gK = -1
                let prev = (i - 1) * m
                let cur = i * m
                for j in i..<m {
                    if gVal > none { gVal -= Self.gapPenalty }
                    if j >= 2, dp[prev + j - 2] > none {
                        let t = dp[prev + j - 2] - Self.gapPenalty
                        if t > gVal {
                            gVal = t
                            gK = j - 2
                        }
                    }
                    guard Self.fold(c[j]) == query[i] else { continue }
                    var best = none
                    var from = -1
                    if dp[prev + j - 1] > none {
                        best = dp[prev + j - 1] + Self.consecutiveBonus
                        from = j - 1
                    }
                    if gVal > best {
                        best = gVal
                        from = gK
                    }
                    if best > none {
                        dp[cur + j] = best + Self.matchScore + Self.boundary(c, j)
                        parent[cur + j] = from
                    }
                }
            }
        }

        var bestJ = -1
        var bestScore = none
        let last = (n - 1) * m
        for j in 0..<m where dp[last + j] > bestScore {
            bestScore = dp[last + j]
            bestJ = j
        }
        guard bestJ >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: n)
        var j = bestJ
        for i in stride(from: n - 1, through: 0, by: -1) {
            positions[i] = j
            j = parent[i * m + j]
        }
        var ranges: [Range<Int>] = []
        for p in positions {
            if let l = ranges.last, l.upperBound == p {
                ranges[ranges.count - 1] = l.lowerBound..<(p + 1)
            } else {
                ranges.append(p..<(p + 1))
            }
        }
        return FuzzyMatch(score: bestScore, ranges: ranges)
    }

    /// Filters `items` by `key`; best score first (stable for equal scores). Empty query keeps input order.
    public func filter<T>(_ items: [T], key: (T) -> String) -> [(item: T, match: FuzzyMatch)] {
        var out: [(item: T, match: FuzzyMatch, index: Int)] = []
        for (index, item) in items.enumerated() {
            if let m = match(key(item)) { out.append((item, m, index)) }
        }
        if !isEmpty {
            out.sort { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
        }
        return out.map { ($0.item, $0.match) }
    }

    private static func fold(_ u: UInt16) -> UInt16 { (65...90).contains(u) ? u + 32 : u }

    private static func isSpace(_ u: UInt16) -> Bool { u == 32 || (9...13).contains(u) }

    private static func boundary(_ c: [UInt16], _ j: Int) -> Int {
        if j == 0 { return boundaryBonus }
        let p = c[j - 1]
        if p == 45 || p == 95 || p == 46 || p == 47 || p == 32 { return boundaryBonus }  // - _ . / space
        if (97...122).contains(p) && (65...90).contains(c[j]) { return camelBonus }
        return 0
    }
}
