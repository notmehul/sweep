import Foundation
import Testing
@testable import SweepRules

@Test func catalogIsBundled() {
    #expect(RuleCatalog.directory != nil)
}
