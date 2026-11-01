import Foundation
import XCTest
@testable import DiscetteCore

final class PlaybackTimingTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000)

    func snap(_ position: Double, at seconds: Double, playing: Bool = true, id: String = "1") -> NowPlaying {
        NowPlaying(source: .appleMusic, trackID: id, title: "t", artist: "a", album: "b", duration: 200,
                   position: position, positionDate: start.addingTimeInterval(seconds), isPlaying: playing)
    }

    func testPollJitterKeepsTheOldClock() {
        let old = snap(10, at: 0)
        // One second later the script reports 11.2 (0.2 s of latency noise): keep the old clock.
        let kept = snap(11.2, at: 1).keepingTiming(of: old)
        XCTAssertEqual(kept, old)
    }

    func testSeekComesThrough() {
        let new = snap(80, at: 1)
        XCTAssertEqual(new.keepingTiming(of: snap(10, at: 0)), new)
    }

    func testPauseAndNewSongComeThrough() {
        let paused = snap(11, at: 1, playing: false)
        XCTAssertEqual(paused.keepingTiming(of: snap(10, at: 0)), paused)
        let other = snap(11, at: 1, id: "2")
        XCTAssertEqual(other.keepingTiming(of: snap(10, at: 0)), other)
        XCTAssertEqual(other.keepingTiming(of: nil), other)
    }

    func testLineProgress() {
        let lines = [LyricLine(time: 10, text: "a"), LyricLine(time: 20, text: "b")]
        XCTAssertEqual(LyricsSync.lineProgress(in: lines, index: 0, at: 10), 0)
        XCTAssertEqual(LyricsSync.lineProgress(in: lines, index: 0, at: 13), 0.5, accuracy: 0.001)   // capped at 6 s
        XCTAssertEqual(LyricsSync.lineProgress(in: lines, index: 0, at: 19), 1)
        XCTAssertEqual(LyricsSync.lineProgress(in: lines, index: 1, at: 23), 0.5, accuracy: 0.001)   // last line: 6 s
        XCTAssertEqual(LyricsSync.lineProgress(in: lines, index: 5, at: 23), 0)
        let quick = [LyricLine(time: 1, text: "a"), LyricLine(time: 3, text: "b")]
        XCTAssertEqual(LyricsSync.lineProgress(in: quick, index: 0, at: 1.9), 0.5, accuracy: 0.001) // 2 s gap * 0.9
    }

    func testCleanTitle() {
        XCTAssertEqual(LyricsQuery.cleanTitle("Shizumeru-Machi: Sinking Town (2011 Remaster)"), "Shizumeru-Machi: Sinking Town")
        XCTAssertEqual(LyricsQuery.cleanTitle("Kill This Love (Japan Version)"), "Kill This Love")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song - Remastered 2009"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (feat. X) [Live]"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Mayonaka No Door~stay with Me"), "Mayonaka No Door~stay with Me")
        XCTAssertEqual(LyricsQuery.cleanTitle("Love (Interlude)"), "Love (Interlude)")
        XCTAssertEqual(LyricsQuery.cleanTitle("(Remix)"), "(Remix)")
    }

    func testRevealedWordByWord() {
        let line = "one two three four"
        XCTAssertEqual(LyricsSync.revealed(line, progress: 0), "one")
        XCTAssertEqual(LyricsSync.revealed(line, progress: 0.5), "one two")
        XCTAssertEqual(LyricsSync.revealed(line, progress: 0.51), "one two three")
        XCTAssertEqual(LyricsSync.revealed(line, progress: 1), line)
    }

    func testRevealedByCharacterWithoutSpaces() {
        XCTAssertEqual(LyricsSync.revealed("真夜中のドア", progress: 0), "真")
        XCTAssertEqual(LyricsSync.revealed("真夜中のドア", progress: 0.5), "真夜中")
        XCTAssertEqual(LyricsSync.revealed("真夜中のドア", progress: 2), "真夜中のドア")
        XCTAssertEqual(LyricsSync.revealed("", progress: 0.5), "")
    }

    func testRevealTimesMatchRevealSteps() {
        let lines = [LyricLine(time: 10, text: "one two three four"), LyricLine(time: 20, text: "ab")]
        // Line 1: 6 s (the cap; the gap is 10 s), four words -> 10, 11.5, 13, 14.5. Line 2: 6 s, two chars.
        XCTAssertEqual(LyricsSync.revealTimes(in: lines, from: 0, to: 100), [10, 11.5, 13, 14.5, 20, 23])
        XCTAssertEqual(LyricsSync.revealTimes(in: lines, from: 13, to: 21), [13, 14.5, 20])
        // Each time really adds a word.
        for t in [11.5, 13, 14.5] {
            let before = LyricsSync.revealed(lines[0].text, progress: LyricsSync.lineProgress(in: lines, index: 0, at: t - 0.01))
            let after = LyricsSync.revealed(lines[0].text, progress: LyricsSync.lineProgress(in: lines, index: 0, at: t + 0.01))
            XCTAssertNotEqual(before, after)
        }
    }

    func testBackdropHysteresis() {
        XCTAssertTrue(Backdrop.prefersDarkText(luminance: 0.8, current: nil))
        XCTAssertFalse(Backdrop.prefersDarkText(luminance: 0.05, current: nil))
        // Near the middle, stay with what's showing.
        XCTAssertTrue(Backdrop.prefersDarkText(luminance: 0.16, current: true))
        XCTAssertFalse(Backdrop.prefersDarkText(luminance: 0.20, current: false))
    }
}
