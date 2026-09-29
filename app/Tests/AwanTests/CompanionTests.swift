#if canImport(XCTest)
import XCTest
@testable import Awan

/// The companion's pure checks (tag parser, coordinate mapping, chunker, hotkey state machine, VAD, router, WAV).
/// They live in the app as `CompanionSelfTest` so they also run without XCTest: `Awan --selftest`.
@MainActor
final class CompanionTests: XCTestCase {
    func testCompanionSelfChecks() {
        XCTAssertTrue(CompanionSelfTest.runUnitChecks())
    }

    func testPointMapsBackToGlobalCoordinates() {
        let g = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelSize: CGSize(width: 1280, height: 831))
        let reply = CompanionTagParser.parse("click save. [POINT:640,415.5:save]")
        guard case let .point(p)? = reply.points.first.flatMap({ CompanionVisualMapper.resolve($0, in: [g]) }) else { return XCTFail("no point") }
        XCTAssertEqual(p.point.x, 756, accuracy: 0.01)
        XCTAssertEqual(p.point.y, 491, accuracy: 0.01)
    }
}
#endif
