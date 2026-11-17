import CoreGraphics
import XCTest
@testable import DiscetteCore

final class NotchGeometryTests: XCTestCase {
    // A 14-inch MacBook Pro at its default scale: 1512 x 982 points, 32 pt menu bar, 190 pt notch.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private func mbp14(origin: CGPoint = .zero) -> NotchGeometry? {
        let frame = screen.offsetBy(dx: origin.x, dy: origin.y)
        return NotchGeometry(screenFrame: frame, topInset: 32,
                             leftArea: CGRect(x: frame.minX, y: frame.maxY - 32, width: 661, height: 32),
                             rightArea: CGRect(x: frame.minX + 851, y: frame.maxY - 32, width: 661, height: 32))
    }

    func testFindsTheNotchBetweenTheMenuBarAreas() throws {
        let g = try XCTUnwrap(mbp14())
        XCTAssertEqual(g.notch, CGRect(x: 661, y: 950, width: 190, height: 32))
    }

    func testNoNotchWithoutInsetOrAreas() {
        XCTAssertNil(NotchGeometry(screenFrame: screen, topInset: 0, leftArea: .zero, rightArea: .zero))
        XCTAssertNil(NotchGeometry(screenFrame: screen, topInset: 32, leftArea: nil, rightArea: nil))
        // Areas that touch or overlap leave no notch.
        XCTAssertNil(NotchGeometry(screenFrame: screen, topInset: 32,
                                   leftArea: CGRect(x: 0, y: 950, width: 800, height: 32),
                                   rightArea: CGRect(x: 700, y: 950, width: 812, height: 32)))
    }

    func testCollapsedIsTheNotchWhenIdleAndAddsEarsWhilePlaying() throws {
        let g = try XCTUnwrap(mbp14())
        XCTAssertEqual(g.collapsedSize(hasTrack: false), CGSize(width: 190, height: 32))
        XCTAssertEqual(g.collapsedSize(hasTrack: true), CGSize(width: 190 + 38 * 2, height: 32))
    }

    func testWindowHangsFromTheTopCentredOnTheNotch() throws {
        let g = try XCTUnwrap(mbp14())
        let frame = g.windowFrame(size: CGSize(width: 500, height: 300))
        XCTAssertEqual(frame.maxY, 982)
        XCTAssertEqual(frame.midX, g.notch.midX)
        XCTAssertEqual(frame.size, CGSize(width: 500, height: 300))
    }

    func testWorksOnAScreenThatIsNotAtTheOrigin() throws {
        // A MacBook to the left of, and lower than, the main display.
        let g = try XCTUnwrap(mbp14(origin: CGPoint(x: -1512, y: -200)))
        XCTAssertEqual(g.notch, CGRect(x: -851, y: 750, width: 190, height: 32))
        let hot = g.hangingRect(size: CGSize(width: 266, height: 32))
        XCTAssertEqual(hot.maxY, 782)
        XCTAssertEqual(hot.midX, g.notch.midX)
    }
}
