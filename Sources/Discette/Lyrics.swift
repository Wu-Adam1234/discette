import CryptoKit
import Foundation
import DiscetteCore

/// https://lrclib.net/docs: no key needed. Identify the client, one request at a time,
/// honour Retry-After on 429.
struct LRCLibClient: LyricsProvider {
    private let session = URLSession(configuration: .ephemeral)
    private let userAgent = "Discette/0.1 (macOS)"

    func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics? {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [URLQueryItem(name: "track_name", value: title),
                          URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { get.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if duration >= 1, duration <= 3600 {
            get.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        let (data, response) = try await request(get.url!)
        switch response.statusCode {
        case 200:
            return try JSONDecoder().decode(LRCLibRecord.self, from: data).lyrics
        case 404:
            break // fall through to search: album names often differ between services
        case 429:
            throw LyricsError.rateLimited(retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
        default:
            throw LyricsError.http(response.statusCode)
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title),
                             URLQueryItem(name: "artist_name", value: artist)]
        let (found, searchResponse) = try await request(search.url!)
        if searchResponse.statusCode == 429 {
            throw LyricsError.rateLimited(retryAfter: Double(searchResponse.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
        }
        guard searchResponse.statusCode == 200 else { return nil }
        let records = try JSONDecoder().decode([LRCLibRecord].self, from: found)
        return LRCLib.bestMatch(records, duration: duration)?.lyrics
    }

    private func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        NSLog("Discette: lyrics %@ -> %d", url.path, http.statusCode)
        return (data, http)
    }
}

/// https://lyrics.ovh: free, no key, plain (unsynced) lyrics. Used when LRCLIB is down or has
/// nothing for a song.
struct LyricsOvhClient: LyricsProvider {
    private let session = URLSession(configuration: .ephemeral)

    func fetch(title: String, artist: String, album: String, duration: Double) async throws -> Lyrics? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let a = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let t = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(t)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Discette/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        NSLog("Discette: lyrics.ovh -> %d", http.statusCode)
        switch http.statusCode {
        case 200:
            struct Body: Decodable { let lyrics: String? }
            let text = try JSONDecoder().decode(Body.self, from: data).lyrics?
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : .plain(text!)
        case 404: return nil
        default: throw LyricsError.http(http.statusCode)
        }
    }
}

/// Local cache in ~/Library/Application Support/Discette/lyrics. Found lyrics are kept;
/// "not found" is remembered for 24 h so a missing song is not asked for on every play.
struct LyricsStore {
    struct Entry: Codable {
        var lyrics: Lyrics?
        var fetchedAt: Date
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Discette/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func file(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    func load(key: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        // Synced lyrics are kept. "Not found" and unsynced results are re-checked after a day,
        // so synced lyrics replace them once a source has them.
        var keep = false
        if case .synced? = entry.lyrics { keep = true }
        if case .instrumental? = entry.lyrics { keep = true }
        if !keep, Date().timeIntervalSince(entry.fetchedAt) > 24 * 3600 { return nil }
        return entry
    }

    func save(key: String, lyrics: Lyrics?) {
        let entry = Entry(lyrics: lyrics, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file(for: key), options: .atomic) }
    }
}

@MainActor
final class LyricsController: ObservableObject {
    enum State: Equatable {
        case off
        case waiting            // nothing playing
        case loading
        case loaded(Lyrics)
        case notFound
        case failed
    }

    @Published private(set) var state: State = .waiting
    /// Seconds added to the song position for this track (positive = lyrics earlier).
    @Published private(set) var offset: Double = 0
    /// The "Lyrics timing" setting, added to every song (positive = lyrics earlier).
    var globalOffset: Double = 0

    private let provider: LyricsProvider
    private let store = LyricsStore()
    private var currentKey: String?
    private var task: Task<Void, Never>?
    private let offsetsKey = "lyricsOffsets"
    /// Back-off after a failed request, so a down server is not asked again every second.
    private var failedKey: String?
    private var retryAt = Date.distantPast
    private var consecutiveFailures = 0

    init(provider: LyricsProvider = ChainedLyricsProvider([LocalLyricsProvider(), LRCLibClient(), LyricsOvhClient()])) {
        self.provider = provider
    }

    func update(for track: NowPlaying?, enabled: Bool) {
        guard enabled else { reset(to: .off); return }
        guard let track, !track.title.isEmpty else { reset(to: .waiting); return }

        let key = [track.artist, track.title, track.album].joined(separator: "\u{1F}").lowercased()
        guard key != currentKey else { return }
        if key == failedKey, Date() < retryAt {
            if state != .failed { state = .failed }
            return
        }
        currentKey = key
        offset = (UserDefaults.standard.dictionary(forKey: offsetsKey)?[key] as? Double) ?? 0
        task?.cancel()

        if let cached = store.load(key: key) {
            state = cached.lyrics.map(State.loaded) ?? .notFound
            return
        }
        state = .loading
        task = Task { [weak self, provider, store] in
            do {
                let lyrics = try await LyricsController.fetchWithOneRetry(provider, track)
                guard let self, !Task.isCancelled, self.currentKey == key else { return }
                store.save(key: key, lyrics: lyrics)
                self.consecutiveFailures = 0
                self.failedKey = nil
                self.state = lyrics.map(State.loaded) ?? .notFound
            } catch {
                guard let self, !Task.isCancelled, self.currentKey == key else { return }
                // 30 s, 60 s, 120 s ... capped at 10 min, then try again.
                self.consecutiveFailures += 1
                let wait = min(600, 30 * pow(2, Double(self.consecutiveFailures - 1)))
                self.failedKey = key
                self.retryAt = Date().addingTimeInterval(wait)
                self.state = .failed
                self.currentKey = nil
            }
        }
    }

    private static func fetchWithOneRetry(_ provider: LyricsProvider, _ t: NowPlaying) async throws -> Lyrics? {
        func fetch(_ title: String) async throws -> Lyrics? {
            do {
                return try await provider.fetch(title: title, artist: t.artist, album: t.album, duration: t.duration)
            } catch LyricsError.rateLimited(let wait) {
                let jitter = Double.random(in: 0...0.3)
                try await Task.sleep(for: .seconds(min(wait, 30) * (1 + jitter)))
                return try await provider.fetch(title: title, artist: t.artist, album: t.album, duration: t.duration)
            }
        }
        let found = try await fetch(t.title)
        if case .synced? = found { return found }
        // "Song (2011 Remaster)" is usually listed as "Song": look again for synced lyrics.
        let clean = LyricsQuery.cleanTitle(t.title)
        guard clean != t.title, let better = try? await fetch(clean) else { return found }
        if case .synced = better { return better }
        return found ?? better
    }

    private func reset(to newState: State) {
        task?.cancel()
        currentKey = nil
        offset = 0
        state = newState
    }

    func nudge(by delta: Double) {
        guard let key = currentKey else { return }
        offset = (offset + delta).rounded(toPlaces: 1)
        var all = UserDefaults.standard.dictionary(forKey: offsetsKey) ?? [:]
        all[key] = offset == 0 ? nil : offset
        UserDefaults.standard.set(all, forKey: offsetsKey)
    }

    var syncedLines: [LyricLine]? {
        if case .loaded(.synced(let lines)) = state { return lines }
        return nil
    }

    /// Index of the current line at a song position, with this track's offset applied.
    func currentIndex(at position: Double) -> Int? {
        guard let lines = syncedLines else { return nil }
        return LyricsSync.currentIndex(in: lines, at: position + offset + globalOffset)
    }

    /// Song positions in the next `window` seconds at which the shown lyric changes.
    func changePositions(from position: Double, window: Double = 30) -> [Double] {
        guard let lines = syncedLines else { return [] }
        let shift = offset + globalOffset
        return LyricsSync.revealTimes(in: lines, from: position + shift, to: position + shift + window).map { $0 - shift }
    }

    /// 0...1 through the current line, for highlighting it as it is sung.
    func lineProgress(at position: Double) -> Double {
        guard let lines = syncedLines, let i = currentIndex(at: position) else { return 0 }
        return LyricsSync.lineProgress(in: lines, index: i, at: position + offset + globalOffset)
    }

    func currentLine(at position: Double) -> String? {
        guard let lines = syncedLines, let i = currentIndex(at: position) else { return nil }
        let text = lines[i].text
        return text.isEmpty ? nil : text
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10, Double(places))
        return (self * f).rounded() / f
    }
}
