import XCTest
@testable import Awan

final class SmokeTests: XCTestCase {
    func testArtifactKindInference() {
        XCTAssertEqual(ArtifactKind.infer("/x/welcome.html"), .webPage)
        XCTAssertEqual(ArtifactKind.infer("/x/brief.pdf"), .pdf)
        XCTAssertEqual(ArtifactKind.infer("https://example.com"), .link)
    }
}
