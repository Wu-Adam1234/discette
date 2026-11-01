import Foundation
import XCTest
@testable import DiscetteCore

private struct Fake: LyricsProvider {
    let result: Result<Lyrics?, LyricsError>
    func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics? {
        try result.get()
    }
}

final class ChainedLyricsProviderTests: XCTestCase {
    let synced = Lyrics.synced([LyricLine(time: 1, text: "a")])
    let plain = Lyrics.plain("words")

    func run(_ providers: [LyricsProvider]) async throws -> Lyrics? {
        try await ChainedLyricsProvider(providers).fetch(title: "t", artist: "a", album: "b", duration: 100)
    }

    func testSyncedWinsEvenAfterPlain() async throws {
        let r = try await run([Fake(result: .success(plain)), Fake(result: .success(synced))])
        XCTAssertEqual(r, synced)
    }

    func testDownServiceFallsThroughToNextSource() async throws {
        // LRCLIB returning 502 must not stop lyrics.ovh from answering.
        let r = try await run([Fake(result: .failure(.http(502))), Fake(result: .success(plain))])
        XCTAssertEqual(r, plain)
    }

    func testAllNotFoundIsNil() async throws {
        let r = try await run([Fake(result: .success(nil)), Fake(result: .success(nil))])
        XCTAssertNil(r)
    }

    func testFailureWithNothingFoundThrowsSoItIsRetried() async {
        do {
            _ = try await run([Fake(result: .failure(.http(502))), Fake(result: .success(nil))])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LyricsError, .http(502))
        }
    }

    func testFirstSyncedStopsEarly() async throws {
        let r = try await run([Fake(result: .success(synced)), Fake(result: .failure(.http(500)))])
        XCTAssertEqual(r, synced)
    }
}

final class LocalLyricsProviderTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("discette-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testReadsSyncedLRC() async throws {
        try write("Artist - Song.lrc", "[00:01.00]one\n[00:02.00]two")
        let r = try await LocalLyricsProvider(folder: folder).fetch(title: "Song", artist: "Artist", album: "", duration: 0)
        XCTAssertEqual(r, .synced([LyricLine(time: 1, text: "one"), LyricLine(time: 2, text: "two")]))
    }

    func testFallsBackToPlainText() async throws {
        try write("Artist - Song.txt", "just words")
        let r = try await LocalLyricsProvider(folder: folder).fetch(title: "Song", artist: "Artist", album: "", duration: 0)
        XCTAssertEqual(r, .plain("just words"))
    }

    func testTitleOnlyFileName() async throws {
        try write("Song.lrc", "[00:03.00]three")
        let r = try await LocalLyricsProvider(folder: folder).fetch(title: "Song", artist: "Someone", album: "", duration: 0)
        XCTAssertEqual(r, .synced([LyricLine(time: 3, text: "three")]))
    }

    func testSlashesInNamesAreSafe() async throws {
        try write("AC-DC - Back In Black.lrc", "[00:01.00]x")
        let r = try await LocalLyricsProvider(folder: folder).fetch(title: "Back In Black", artist: "AC/DC", album: "", duration: 0)
        XCTAssertNotNil(r)
    }

    func testMissingIsNil() async throws {
        let r = try await LocalLyricsProvider(folder: folder).fetch(title: "Nope", artist: "None", album: "", duration: 0)
        XCTAssertNil(r)
    }
}
