import Foundation

/// Semantic-ish version of the Azure CLI.
public struct AzureVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public static let minimumSupported = AzureVersion(major: 2, minor: 60, patch: 0)

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public var isSupported: Bool { self >= Self.minimumSupported }

    public static func < (l: Self, r: Self) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }

    /// Parses `2.60.0` or the output of `az --version` (`azure-cli   2.60.0 *`) / `az version -o json`.
    public init?(parsing text: String) {
        let pattern = #"(?:azure-cli"?\s*[:\s]\s*"?)?(\d+)\.(\d+)(?:\.(\d+))?"#
        let scope: String
        if let r = text.range(of: #"azure-cli"?\s*[:\s]\s*"?\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            scope = String(text[r])
        } else {
            scope = text
        }
        guard let re = try? NSRegularExpression(pattern: pattern),
            let m = re.firstMatch(in: scope, range: NSRange(scope.startIndex..., in: scope)),
            let maj = Self.int(m, 1, scope), let min = Self.int(m, 2, scope)
        else { return nil }
        self.init(major: maj, minor: min, patch: Self.int(m, 3, scope) ?? 0)
    }

    private static func int(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> Int? {
        guard let r = Range(m.range(at: i), in: s) else { return nil }
        return Int(s[r])
    }
}
