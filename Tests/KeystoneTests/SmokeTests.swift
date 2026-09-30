import Foundation
import Testing

@testable import Keystone

@Test func bundleIdentifier() {
    #expect(Bundle.main.bundleIdentifier != nil)
}
