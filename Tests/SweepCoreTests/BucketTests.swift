import Testing
@testable import SweepCore

@Test func onlyRebuildsIsPreselected() {
    #expect(Bucket.allCases.filter(\.isPreselected) == [.rebuilds])
}

@Test func dontTouchIsHidden() {
    #expect(Bucket.allCases.filter { !$0.isShown } == [.dontTouch])
}
