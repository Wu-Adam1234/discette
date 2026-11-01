import Foundation
import XCTest
@testable import DiscetteCore

final class LRCParserTests: XCTestCase {
    func testParsesTimedLinesInOrder() {
        let lines = LRCParser.parse("[00:17.12] I feel your breath\n[00:05.00]First\n[01:02.50]  Third  ")
        XCTAssertEqual(lines.map(\.time), [5.0, 17.12, 62.5])
        XCTAssertEqual(lines.map(\.text), ["First", "I feel your breath", "Third"])
    }

    func testSkipsMetadataTags() {
        let lines = LRCParser.parse("[ar: Someone]\n[ti:Song]\n[00:01.00]Hello")
        XCTAssertEqual(lines, [LyricLine(time: 1, text: "Hello")])
    }

    func testRepeatedTimestampsOnOneLine() {
        let lines = LRCParser.parse("[00:10.00][00:30.00]Chorus")
        XCTAssertEqual(lines, [LyricLine(time: 10, text: "Chorus"), LyricLine(time: 30, text: "Chorus")])
    }

    func testKeepsEmptyLinesAsBreaks() {
        XCTAssertEqual(LRCParser.parse("[03:25.72] "), [LyricLine(time: 205.72, text: "")])
    }

    func testIgnoresGarbage() {
        XCTAssertTrue(LRCParser.parse("no tags here\n[xx:yy]bad").isEmpty)
    }
}

final class LyricsSyncTests: XCTestCase {
    let lines = [LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b"), LyricLine(time: 20, text: "c")]

    func testBeforeFirstLineIsNil() { XCTAssertNil(LyricsSync.currentIndex(in: lines, at: 4.99)) }
    func testExactBoundary() { XCTAssertEqual(LyricsSync.currentIndex(in: lines, at: 10), 1) }
    func testBetweenLines() { XCTAssertEqual(LyricsSync.currentIndex(in: lines, at: 15), 1) }
    func testAfterLastLine() { XCTAssertEqual(LyricsSync.currentIndex(in: lines, at: 999), 2) }
    func testEmpty() { XCTAssertNil(LyricsSync.currentIndex(in: [], at: 3)) }
}

final class LRCLibTests: XCTestCase {
    func record(_ id: Int, duration: Double?, synced: String? = nil, plain: String? = nil, instrumental: Bool? = false) -> LRCLibRecord {
        LRCLibRecord(id: id, trackName: "t", artistName: "a", duration: duration, instrumental: instrumental,
                     plainLyrics: plain, syncedLyrics: synced)
    }

    func testDecodesDocsExample() throws {
        let json = #"{"id":3396226,"name":"I Want to Live","trackName":"I Want to Live","artistName":"Borislav Slavov","albumName":"BG3","duration":233,"instrumental":false,"plainLyrics":"I feel","syncedLyrics":"[00:17.12] I feel your breath upon my neck"}"#
        let r = try JSONDecoder().decode(LRCLibRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.lyrics, .synced([LyricLine(time: 17.12, text: "I feel your breath upon my neck")]))
    }

    func testInstrumentalWins() {
        XCTAssertEqual(record(1, duration: 100, synced: "[00:01.00]x", instrumental: true).lyrics, .instrumental)
    }

    func testPlainWhenNoSynced() {
        XCTAssertEqual(record(1, duration: 100, plain: "words").lyrics, .plain("words"))
    }

    func testNothingUsable() {
        XCTAssertNil(record(1, duration: 100, plain: "   ").lyrics)
    }

    func testBestMatchPrefersSyncedWithinDuration() {
        let picks = [record(1, duration: 200, plain: "far"),
                     record(2, duration: 181, plain: "plain close"),
                     record(3, duration: 182, synced: "[00:01.00]synced close")]
        XCTAssertEqual(LRCLib.bestMatch(picks, duration: 180)?.id, 3)
    }

    func testBestMatchRejectsWrongLength() {
        XCTAssertNil(LRCLib.bestMatch([record(1, duration: 300, synced: "[00:01.00]x")], duration: 180))
    }
}

final class FormattingTests: XCTestCase {
    func testTitleFormat() {
        XCTAssertEqual(TitleFormat.render("{title} · {artist}", title: "Supernatural", artist: "NewJeans", album: "S"),
                       "Supernatural · NewJeans")
    }

    func testTitleFormatSinglePass() {
        XCTAssertEqual(TitleFormat.render("{title}!", title: "{artist}", artist: "X", album: ""), "{artist}!")
    }

    func testUnknownTokensKept() {
        XCTAssertEqual(TitleFormat.render("{year} {title}", title: "T", artist: "", album: ""), "{year} T")
    }

    func testSpotifyLink() {
        XCTAssertEqual(ShareLink.spotifyWebURL(fromURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.absoluteString,
                       "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertNil(ShareLink.spotifyWebURL(fromURI: "https://example.com"))
    }
}

final class NowPlayingTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000)

    func track(playing: Bool, position: Double = 10, duration: Double = 100) -> NowPlaying {
        NowPlaying(source: .appleMusic, trackID: "1", title: "t", artist: "a", album: "b",
                   duration: duration, position: position, positionDate: start, isPlaying: playing)
    }

    func testInterpolatesWhilePlaying() {
        XCTAssertEqual(track(playing: true).position(at: start.addingTimeInterval(2.5)), 12.5, accuracy: 0.001)
    }

    func testFrozenWhilePaused() {
        XCTAssertEqual(track(playing: false).position(at: start.addingTimeInterval(30)), 10)
    }

    func testClampsToDuration() {
        XCTAssertEqual(track(playing: true, position: 99).position(at: start.addingTimeInterval(10)), 100)
        XCTAssertEqual(track(playing: true, position: 99).progress(at: start.addingTimeInterval(10)), 1)
    }

    func testZeroDurationProgress() {
        XCTAssertEqual(track(playing: true, duration: 0).progress(at: start), 0)
    }
}

final class ArtworkPaletteTests: XCTestCase {
    func image(_ colors: [(RGB, Int)]) -> [RGB] { colors.flatMap { Array(repeating: $0.0, count: $0.1) } }

    func assertReadable(_ p: ArtworkPalette, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.background), 7, file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.muted.contrast(with: p.background), 4.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.accent.contrast(with: p.background), 4.5, file: file, line: line)
        XCTAssertLessThan(p.background.luminance, 0.04, "background stays dark", file: file, line: line)
    }

    func testRedCoverGivesRedAccentAndDarkRedBackground() {
        let p = ArtworkPalette.extract(from: image([(RGB(0.85, 0.1, 0.12), 700), (RGB(0.05, 0.05, 0.05), 300)]))
        XCTAssertTrue(p.accent.hsv.h < 0.05 || p.accent.hsv.h > 0.95, "accent is red")
        XCTAssertTrue(p.background.hsv.h < 0.05 || p.background.hsv.h > 0.95, "background is a deep red")
        assertReadable(p)
    }

    func testBlackCoverWithSmallBlueTitleUsesBlue() {
        let p = ArtworkPalette.extract(from: image([(RGB(0.03, 0.03, 0.04), 900), (RGB(0.1, 0.25, 0.95), 100)]))
        XCTAssertEqual(p.accent.hsv.h, 0.63, accuracy: 0.06)
        assertReadable(p)
    }

    func testDarkBlueAccentIsLiftedToBeReadable() {
        let p = ArtworkPalette.extract(from: image([(RGB(0.05, 0.05, 0.55), 1000)]))
        assertReadable(p)
    }

    func testGreyscaleCoverStaysNeutral() {
        let p = ArtworkPalette.extract(from: image([(RGB(0.9, 0.9, 0.9), 500), (RGB(0.2, 0.2, 0.2), 500)]))
        XCTAssertLessThan(p.background.hsv.s, 0.1)
        assertReadable(p)
    }

    func testEmptyFallsBack() {
        XCTAssertEqual(ArtworkPalette.extract(from: []), .fallback)
        assertReadable(.fallback)
    }

    func testLightVariantIsReadable() {
        for cover in [image([(RGB(0.85, 0.1, 0.12), 1000)]), image([(RGB(0.95, 0.85, 0.2), 1000)]),
                      image([(RGB(0.05, 0.05, 0.55), 1000)]), image([(RGB(0.5, 0.5, 0.5), 1000)])] {
            let p = ArtworkPalette.extract(from: cover).light
            XCTAssertGreaterThan(p.background.luminance, 0.6, "a light surface")
            XCTAssertGreaterThanOrEqual(p.text.contrast(with: p.background), 7)
            XCTAssertGreaterThanOrEqual(p.muted.contrast(with: p.background), 4.5)
            XCTAssertGreaterThanOrEqual(p.accent.contrast(with: p.background), 4.5)
        }
    }

    func testHSVRoundTrip() {
        let c = RGB(0.2, 0.6, 0.9)
        let h = c.hsv
        let back = RGB(h: h.h, s: h.s, v: h.v)
        XCTAssertEqual(back.r, c.r, accuracy: 0.001)
        XCTAssertEqual(back.g, c.g, accuracy: 0.001)
        XCTAssertEqual(back.b, c.b, accuracy: 0.001)
    }
}

final class PlayerNotificationTests: XCTestCase {
    func testMusicFieldsSeenInSpike() {
        // Shape observed on macOS 27 (replica/spike-m1.md)
        let info: [AnyHashable: Any] = ["Name": "Super in Love", "Artist": "ILLIT", "Album": "BREAK EVEN - EP",
                                        "Player State": "Playing", "PersistentID": NSNumber(value: 608478921109338693),
                                        "Total Time": NSNumber(value: 179241)]
        let n = PlayerNotificationInfo.music(info)
        XCTAssertTrue(n.isPlaying)
        XCTAssertEqual(n.title, "Super in Love")
        XCTAssertEqual(n.trackID, "608478921109338693")
        XCTAssertEqual(n.duration ?? 0, 179.241, accuracy: 0.001)
    }

    func testMusicStoppedHasNoTrack() {
        let n = PlayerNotificationInfo.music(["Player State": "Stopped"])
        XCTAssertFalse(n.isPlaying)
        XCTAssertNil(n.title)
    }

    func testSpotify() {
        let n = PlayerNotificationInfo.spotify(["Player State": "Paused", "Track ID": "spotify:track:abc",
                                                "Name": "Song", "Duration": NSNumber(value: 200000)])
        XCTAssertFalse(n.isPlaying)
        XCTAssertEqual(n.trackID, "spotify:track:abc")
        XCTAssertEqual(n.duration, 200)
    }
}
