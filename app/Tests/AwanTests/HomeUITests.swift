import XCTest
@testable import Awan

final class HomeUITests: XCTestCase {
    private func date(_ h: Int, day: Int = 29) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day; c.hour = h; c.minute = 5
        return Calendar.current.date(from: c)!
    }

    func testMorningWindowAndOncePerDay() {
        XCTAssertTrue(MorningSuggestions.shouldPresent(now: date(8), lastShown: date(9, day: 28), dismissStreak: 0, enabled: true, pending: 3, quiet: false))
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(6), lastShown: nil, dismissStreak: 0, enabled: true, pending: 3, quiet: false))
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(12), lastShown: nil, dismissStreak: 0, enabled: true, pending: 3, quiet: false))
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(10), lastShown: date(7), dismissStreak: 0, enabled: true, pending: 3, quiet: false))
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(8), lastShown: nil, dismissStreak: 0, enabled: false, pending: 3, quiet: false))
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(8), lastShown: nil, dismissStreak: 0, enabled: true, pending: 0, quiet: false))
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(8), lastShown: nil, dismissStreak: 0, enabled: true, pending: 2, quiet: true))
    }

    func testMorningBacksOffAfterThreeDismissals() {
        XCTAssertFalse(MorningSuggestions.shouldPresent(now: date(8), lastShown: date(8, day: 28), dismissStreak: 3, enabled: true, pending: 3, quiet: false))
        XCTAssertTrue(MorningSuggestions.shouldPresent(now: date(8), lastShown: date(8, day: 26), dismissStreak: 3, enabled: true, pending: 3, quiet: false))
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownBlock.parse("# Title\n\nHello **there**\n\n- one\n- two\n\n1. first\n2. second\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```")
        XCTAssertEqual(blocks, [
            .heading(1, "Title"),
            .paragraph("Hello **there**"),
            .list([.init(text: "one", indent: 0), .init(text: "two", indent: 0)], ordered: false),
            .list([.init(text: "first", indent: 0), .init(text: "second", indent: 0)], ordered: true),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .code("code"),
        ])
    }

    @MainActor
    func testAttachmentsRoundTrip() {
        let prompt = AgentThreadPage.attachmentsHeader + "\n- /tmp/a.pdf\n- /tmp/b c.png\n\nSummarise these"
        XCTAssertEqual(AgentThreadPage.attachments(in: prompt), ["/tmp/a.pdf", "/tmp/b c.png"])
        XCTAssertEqual(AgentThreadPage.attachments(in: "no files"), [])
    }
}
