import Foundation
import Testing

@testable import Secreter

@Test func bundleIdentifier() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
