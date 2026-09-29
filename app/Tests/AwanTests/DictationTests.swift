import XCTest
@testable import Awan

final class DictationTests: XCTestCase {
    func testLocalTidy() {
        XCTAssertEqual(DictationCleanup.localTidy("um so i think the the meeting is at 3", dictionary: []), "So I think the meeting is at 3.")
        XCTAssertEqual(DictationCleanup.localTidy("ask ff dev studio about awan", dictionary: ["FF Dev Studio", "Awan"]), "Ask FF Dev Studio about Awan.")
        XCTAssertEqual(DictationCleanup.localTidy("wait — no — yes", dictionary: []), "Wait, no, yes.")
        XCTAssertEqual(DictationCleanup.localTidy("a well-known fact", dictionary: []), "A well-known fact.")
        XCTAssertEqual(DictationCleanup.localTidy("   ", dictionary: []), "")
    }

    func testStripDashesKeepsHyphens() {
        XCTAssertEqual(DictationCleanup.stripDashes("ship it — today"), "ship it, today")
        XCTAssertEqual(DictationCleanup.stripDashes("state-of-the-art"), "state-of-the-art")
    }

    func testTerminalNewlinesCollapse() {
        XCTAssertEqual(TextInserter.collapseNewlines("git status\n\nthen push"), "git status then push")
    }

    @MainActor func testDictionaryCorrection() {
        // we typed "Cowan", the user fixed it to "Kawan"
        XCTAssertEqual(DictionaryLearner.correction(before: "say hi to Cowan today", after: "say hi to Kawan today", typed: ["say", "hi", "to", "cowan", "today"]), "Kawan")
        // half-typed prefix is not learned
        XCTAssertNil(DictionaryLearner.correction(before: "say hi to Cowan", after: "say hi to Cowa", typed: ["cowan"]))
        // a rewrite of words we didn't type is ignored
        XCTAssertNil(DictionaryLearner.correction(before: "hello there", after: "hello there friend", typed: ["hello", "there"]))
        // case fix counts ("iphone" → "iPhone")
        XCTAssertEqual(DictionaryLearner.correction(before: "my iphone", after: "my iPhone", typed: ["my", "iphone"]), "iPhone")
    }
}
