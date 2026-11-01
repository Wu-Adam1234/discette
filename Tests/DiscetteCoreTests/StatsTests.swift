import Foundation
import XCTest
@testable import DiscetteCore

final class ListeningStatsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testRecordsTodayAndArtist() {
        var s = ListeningStats()
        s.record(seconds: 3, artist: "ILLIT", at: date(2026, 10, 31), calendar: cal)
        s.record(seconds: 2, artist: "ILLIT", at: date(2026, 10, 31), calendar: cal)
        XCTAssertEqual(s.today(date(2026, 10, 31), calendar: cal), 5)
        XCTAssertEqual(s.topArtists().first?.name, "ILLIT")
    }

    func testLongGapsAreCapped() {
        var s = ListeningStats()
        s.record(seconds: 3600, artist: "A", at: date(2026, 10, 31), calendar: cal) // laptop slept
        XCTAssertEqual(s.today(date(2026, 10, 31), calendar: cal), 5)
    }

    func testNegativeAndEmptyArtistIgnored() {
        var s = ListeningStats()
        s.record(seconds: -4, artist: "A", at: date(2026, 10, 31), calendar: cal)
        s.record(seconds: 2, artist: "  ", at: date(2026, 10, 31), calendar: cal)
        XCTAssertEqual(s.today(date(2026, 10, 31), calendar: cal), 2)
        XCTAssertTrue(s.artists.isEmpty)
    }

    func testWeekIsLastSevenDays() {
        var s = ListeningStats()
        s.days = ["2026-10-31": 10, "2026-10-25": 20, "2026-10-24": 999]
        XCTAssertEqual(s.week(date(2026, 10, 31), calendar: cal), 30)
    }

    func testStreakCountsConsecutiveDays() {
        var s = ListeningStats()
        s.days = ["2026-10-31": 120, "2026-10-30": 61, "2026-10-29": 300, "2026-10-27": 900]
        XCTAssertEqual(s.streak(date(2026, 10, 31), calendar: cal), 3)
    }

    func testStreakSurvivesTheMorning() {
        var s = ListeningStats()
        s.days = ["2026-10-31": 10, "2026-10-30": 600, "2026-10-29": 600]
        XCTAssertEqual(s.streak(date(2026, 10, 31, 8), calendar: cal), 2)
    }

    func testStreakAcrossMonthAndDST() {
        var s = ListeningStats()
        // US daylight saving ends 2026-11-01.
        s.days = ["2026-11-02": 100, "2026-11-01": 100, "2026-10-31": 100]
        XCTAssertEqual(s.streak(date(2026, 11, 2), calendar: cal), 3)
    }

    func testDayKeyUsesLocalCalendar() {
        var s = ListeningStats()
        s.record(seconds: 4, artist: "A", at: date(2026, 10, 31, 23), calendar: cal)
        XCTAssertEqual(s.days.keys.first, "2026-10-31")
    }

    func testTopArtistsOrderAndLimit() {
        var s = ListeningStats()
        s.artists = ["B": 50, "A": 50, "C": 10, "D": 5, "E": 4, "F": 3]
        XCTAssertEqual(s.topArtists(5).map(\.name), ["A", "B", "C", "D", "E"])
    }

    func testFormat() {
        XCTAssertEqual(ListeningStats.format(45), "45s")
        XCTAssertEqual(ListeningStats.format(14 * 60 + 20), "14m")
        XCTAssertEqual(ListeningStats.format(2 * 3600 + 5 * 60), "2h 05m")
    }

    func testCodableRoundTrip() throws {
        var s = ListeningStats()
        s.record(seconds: 3, artist: "A", at: date(2026, 10, 31), calendar: cal)
        let back = try JSONDecoder().decode(ListeningStats.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class RepeatModeTests: XCTestCase {
    func testCycle() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testMusicValues() {
        XCTAssertEqual(RepeatMode(musicValue: "one"), .one)
        XCTAssertEqual(RepeatMode(musicValue: "OFF"), .off)
        XCTAssertNil(RepeatMode(musicValue: "sometimes"))
    }
}
