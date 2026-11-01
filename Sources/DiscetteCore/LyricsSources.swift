import Foundation

/// Where lyrics come from. Discette chains several so one service being down never means
/// "no lyrics": your own files, then LRCLIB (synced), then lyrics.ovh (plain).
public protocol LyricsProvider: Sendable {
    func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics?
}

public enum LyricsError: Error, Equatable {
    case rateLimited(retryAfter: Double)
    case http(Int)
}

/// Lyrics you keep yourself: <folder>/"Artist - Title.lrc" (synced) or ".txt" (plain).
/// Works offline and always wins. Default folder: ~/Music/Lyrics.
public struct LocalLyricsProvider: LyricsProvider {
    public let folder: URL

    public init(folder: URL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Lyrics")) {
        self.folder = folder
    }

    public static func fileName(_ text: String) -> String {
        text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    public func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics? {
        for name in ["\(Self.fileName(artist)) - \(Self.fileName(title))", Self.fileName(title)] {
            if let text = try? String(contentsOf: folder.appendingPathComponent(name + ".lrc"), encoding: .utf8) {
                let lines = LRCParser.parse(text)
                if !lines.isEmpty { return .synced(lines) }
            }
            if let text = try? String(contentsOf: folder.appendingPathComponent(name + ".txt"), encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .plain(text)
            }
        }
        return nil
    }
}

/// Tries each source in order. Synced lyrics win at once; plain lyrics are kept in case nothing
/// better turns up. If nothing was found and any source failed (rather than saying "not found"),
/// the error is passed on, so the song is retried later instead of remembered as "no lyrics".
public struct ChainedLyricsProvider: LyricsProvider {
    public let providers: [LyricsProvider]

    public init(_ providers: [LyricsProvider]) { self.providers = providers }

    public func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics? {
        var kept: Lyrics?
        var lastError: Error?
        for provider in providers {
            do {
                switch try await provider.fetch(title: title, artist: artist, album: album, duration: duration) {
                case .synced(let lines)?: return .synced(lines)
                case let found?: kept = kept ?? found
                case nil: break
                }
            } catch {
                lastError = error
            }
        }
        if let kept { return kept }
        if let lastError { throw lastError }
        return nil
    }
}
