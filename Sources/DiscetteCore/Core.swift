import Foundation

// MARK: - Now playing

public enum PlayerSource: String, Codable, Sendable, CaseIterable {
    case appleMusic, spotify

    public var displayName: String { self == .appleMusic ? "Apple Music" : "Spotify" }
}

/// One snapshot of what a player is doing. `position` was true at `positionDate`.
public struct NowPlaying: Equatable, Sendable {
    public var source: PlayerSource
    public var trackID: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double   // seconds
    public var position: Double   // seconds, measured at positionDate
    public var positionDate: Date
    public var isPlaying: Bool
    public var shareURL: URL?
    /// nil = this player doesn't report it (so the control is shown as unavailable).
    public var shuffle: Bool?
    public var repeatMode: RepeatMode?
    public var favorite: Bool?

    public init(source: PlayerSource, trackID: String, title: String, artist: String, album: String,
                duration: Double, position: Double, positionDate: Date, isPlaying: Bool, shareURL: URL? = nil,
                shuffle: Bool? = nil, repeatMode: RepeatMode? = nil, favorite: Bool? = nil) {
        self.source = source; self.trackID = trackID; self.title = title; self.artist = artist
        self.album = album; self.duration = duration; self.position = position
        self.positionDate = positionDate; self.isPlaying = isPlaying; self.shareURL = shareURL
        self.shuffle = shuffle; self.repeatMode = repeatMode; self.favorite = favorite
    }

    /// Position extrapolated to `date`, so animation and lyrics stay smooth between polls.
    public func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let p = position + max(0, date.timeIntervalSince(positionDate))
        return duration > 0 ? min(p, duration) : p
    }

    /// 0...1 through the track.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, position(at: date) / duration))
    }

    /// Keeps the previous snapshot's clock while a new reading agrees with it, so polling
    /// latency never makes the position (and the lyrics) jitter. Seeks, pauses and new songs
    /// differ by more than `tolerance` and come through as read.
    public func keepingTiming(of old: NowPlaying?, tolerance: Double = 0.75) -> NowPlaying {
        guard let old, old.trackID == trackID, old.isPlaying, isPlaying,
              abs(old.position(at: positionDate) - position) < tolerance else { return self }
        var out = self
        out.position = old.position
        out.positionDate = old.positionDate
        return out
    }
}

// MARK: - Queue

/// What plays next, as far as the player shares it. Apple Music exposes only the playlist it
/// is playing from, not Up Next or the shuffled order.
public struct PlayQueue: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var index: Int        // position in the playlist, for "play this one"
        public var title: String
        public var artist: String
        public var id: Int { index }
        public init(index: Int, title: String, artist: String) { self.index = index; self.title = title; self.artist = artist }
    }
    public var playlist: String
    public var shuffled: Bool
    public var items: [Item]
    public init(playlist: String, shuffled: Bool, items: [Item]) {
        self.playlist = playlist; self.shuffled = shuffled; self.items = items
    }
}

// MARK: - Backdrop

public enum Backdrop {
    /// Black text reads better than white above relative luminance ~0.18 (where the two
    /// contrast ratios meet). A band around it stops flicker as things move behind the player.
    public static func prefersDarkText(luminance: Double, current: Bool?) -> Bool {
        switch current {
        case true?: return luminance > 0.13
        case false?: return luminance > 0.23
        case nil: return luminance > 0.18
        }
    }
}

// MARK: - Lyrics

public struct LyricLine: Equatable, Sendable, Codable {
    public let time: Double
    public let text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

public enum Lyrics: Equatable, Sendable, Codable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
}

public enum LRCParser {
    /// Parses LRC text: `[mm:ss.xx] words`. Supports several time tags on one line and skips
    /// metadata tags such as `[ar: Artist]`.
    public static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let t = parseTime(tag) else { break }
                times.append(t)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { out.append(LyricLine(time: t, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }

    static func parseTime(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2,
              let m = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let s = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              m >= 0, s >= 0 else { return nil }
        return m * 60 + s
    }
}

public enum LyricsSync {
    /// Index of the line being sung at `time`: the last line whose time is <= `time`.
    /// nil before the first line.
    public static func currentIndex(in lines: [LyricLine], at time: Double) -> Int? {
        var lo = 0, hi = lines.count - 1
        var answer: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { answer = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return answer
    }

    /// 0...1 through line `index`, for highlighting it as it is sung. A line lasts until the
    /// next one starts (a little less, as singers finish early), and at most `maxDuration`.
    public static func lineProgress(in lines: [LyricLine], index: Int, at time: Double, maxDuration: Double = 6) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        return max(0, min(1, (time - lines[index].time) / lineLength(in: lines, index: index, maxDuration: maxDuration)))
    }

    /// How long line `index` takes to sing, as `lineProgress` counts it.
    public static func lineLength(in lines: [LyricLine], index: Int, maxDuration: Double = 6) -> Double {
        let start = lines[index].time
        let gap = index + 1 < lines.count ? (lines[index + 1].time - start) * 0.9 : maxDuration
        return max(0.3, min(maxDuration, gap))
    }

    /// The song times (line times, as in the LRC) from `start` to `end` at which `revealed`
    /// shows one more word or character: the only moments the lyrics need redrawing.
    public static func revealTimes(in lines: [LyricLine], from start: Double, to end: Double) -> [Double] {
        var out: [Double] = []
        for (i, line) in lines.enumerated() where line.time <= end {
            let length = lineLength(in: lines, index: i)
            guard line.time + length >= start else { continue }
            let steps = max(1, revealSteps(line.text))
            for k in 0..<steps {
                let t = line.time + length * Double(k) / Double(steps)
                if t >= start, t <= end { out.append(t) }
            }
        }
        return out
    }

    /// How many pieces `revealed` shows a line in: words, or characters for lines without spaces.
    public static func revealSteps(_ text: String) -> Int {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).count
        return words >= 3 ? words : text.count
    }

    /// The part of a line sung so far, so lyrics appear as the song says them. Word by word,
    /// or character by character for lines without spaces (Japanese, Chinese, Korean...).
    /// The first word shows as soon as the line starts.
    public static func revealed(_ text: String, progress: Double) -> String {
        let p = max(0, min(1, progress))
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        if words.count >= 3 {
            let k = max(1, min(words.count, Int((Double(words.count) * p).rounded(.up))))
            return words.prefix(k).joined(separator: " ")
        }
        let chars = Array(text)
        guard !chars.isEmpty else { return text }
        let k = max(1, min(chars.count, Int((Double(chars.count) * p).rounded(.up))))
        return String(chars.prefix(k))
    }
}

/// One record from LRCLIB (https://lrclib.net/docs).
public struct LRCLibRecord: Decodable, Sendable, Equatable {
    public let id: Int
    public let trackName: String?
    public let artistName: String?
    public let duration: Double?
    public let instrumental: Bool?
    public let plainLyrics: String?
    public let syncedLyrics: String?

    public init(id: Int, trackName: String?, artistName: String?, duration: Double?,
                instrumental: Bool?, plainLyrics: String?, syncedLyrics: String?) {
        self.id = id; self.trackName = trackName; self.artistName = artistName; self.duration = duration
        self.instrumental = instrumental; self.plainLyrics = plainLyrics; self.syncedLyrics = syncedLyrics
    }

    /// Synced beats plain; instrumental wins if flagged. nil if the record has nothing usable.
    public var lyrics: Lyrics? {
        if instrumental == true { return .instrumental }
        if let s = syncedLyrics, !s.isEmpty {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let p = plainLyrics, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .plain(p) }
        return nil
    }
}

public enum LRCLib {
    /// Picks the best search result: duration within 3 s (when known), synced lyrics first.
    public static func bestMatch(_ records: [LRCLibRecord], duration: Double) -> LRCLibRecord? {
        let fits = records.filter { r in
            guard duration > 0, let d = r.duration else { return true }
            return abs(d - duration) <= 3
        }
        return fits.first(where: { !($0.syncedLyrics ?? "").isEmpty }) ?? fits.first(where: { $0.lyrics != nil })
    }
}

// MARK: - Formatting and links

public enum TitleFormat {
    /// Replaces {title}, {artist} and {album} in one pass, so a title that itself contains
    /// "{artist}" is not expanded twice.
    public static func render(_ format: String, title: String, artist: String, album: String) -> String {
        let tokens = ["{title}": title, "{artist}": artist, "{album}": album]
        var out = ""
        var i = format.startIndex
        while i < format.endIndex {
            if format[i] == "{", let hit = tokens.first(where: { format[i...].hasPrefix($0.key) }) {
                out += hit.value
                i = format.index(i, offsetBy: hit.key.count)
            } else {
                out.append(format[i])
                i = format.index(after: i)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

public enum ShareLink {
    /// spotify:track:ID -> https://open.spotify.com/track/ID
    public static func spotifyWebURL(fromURI uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", !parts[2].isEmpty else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

// MARK: - Album colours

public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public init(h: Double, s: Double, v: Double) {
        let h6 = (h - floor(h)) * 6
        let i = floor(h6), f = h6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
    }

    public var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The player's colours, taken from the album cover. Background and surface are deep
/// versions of the cover's main hue; accent is its most vivid colour, lifted until it
/// reads on the background (WCAG 4.5:1). Text and muted text are always >= 4.5:1.
public struct ArtworkPalette: Equatable, Sendable {
    public var background: RGB
    public var surface: RGB
    public var accent: RGB
    public var text: RGB
    public var muted: RGB

    public static let fallback = ArtworkPalette(
        background: RGB(0.105, 0.108, 0.118), surface: RGB(0.17, 0.175, 0.19),
        accent: RGB(0.62, 0.80, 1.0), text: RGB(0.96, 0.965, 0.97), muted: RGB(0.68, 0.69, 0.72))

    public static func extract(from pixels: [RGB]) -> ArtworkPalette {
        guard !pixels.isEmpty else { return .fallback }
        // 12 hue bins + 1 bin for greys, blacks and whites.
        var count = [Int](repeating: 0, count: 13)
        var sum = [RGB](repeating: RGB(0, 0, 0), count: 13)
        for p in pixels {
            let c = p.hsv
            let bin = (c.s < 0.18 || c.v < 0.12) ? 12 : min(11, Int(c.h * 12))
            count[bin] += 1
            sum[bin].r += p.r; sum[bin].g += p.g; sum[bin].b += p.b
        }
        func average(_ i: Int) -> RGB {
            let n = Double(max(1, count[i]))
            return RGB(sum[i].r / n, sum[i].g / n, sum[i].b / n)
        }
        let total = Double(pixels.count)
        let dominantBin = count.indices.max { count[$0] < count[$1] } ?? 12
        let vivid = (0..<12).filter { Double(count[$0]) / total >= 0.03 }
        let accentBin = vivid.max { a, b in
            let ca = average(a).hsv, cb = average(b).hsv
            return sqrt(Double(count[a])) * ca.s * ca.v < sqrt(Double(count[b])) * cb.s * cb.v
        }

        let neutralCover = dominantBin == 12 && accentBin == nil
        let base = (dominantBin == 12 ? accentBin.map(average) : nil) ?? average(dominantBin)
        let hue = base.hsv.h
        let sat = neutralCover ? 0.04 : min(0.6, max(0.25, base.hsv.s))
        let background = RGB(h: hue, s: sat, v: 0.13)
        let surface = RGB(h: hue, s: sat * 0.9, v: 0.21)

        var accent: RGB
        if let a = accentBin {
            let c = average(a).hsv
            accent = RGB(h: c.h, s: min(0.85, max(0.45, c.s)), v: min(0.97, max(0.80, c.v)))
        } else {
            accent = RGB(h: hue, s: 0.08, v: 0.9)
        }
        accent = ensureContrast(accent, on: background, minimum: 4.5)
        let text = ensureContrast(RGB(h: hue, s: 0.05, v: 0.97), on: background, minimum: 7)
        let muted = ensureContrast(RGB(h: hue, s: 0.10, v: 0.70), on: background, minimum: 4.5)
        return ArtworkPalette(background: background, surface: surface, accent: accent, text: text, muted: muted)
    }

    /// The same cover colours for a light surface ("Paper" look).
    public var light: ArtworkPalette {
        let hue = background.hsv.h
        let sat = min(0.14, background.hsv.s * 0.35)
        let bg = RGB(h: hue, s: sat, v: 0.97)
        return ArtworkPalette(
            background: bg,
            surface: RGB(h: hue, s: sat, v: 0.90),
            accent: Self.ensureContrast(accent, on: bg, minimum: 4.5),
            text: Self.ensureContrast(RGB(h: hue, s: 0.25, v: 0.14), on: bg, minimum: 7),
            muted: Self.ensureContrast(RGB(h: hue, s: 0.15, v: 0.42), on: bg, minimum: 4.5))
    }

    /// Moves `color` away from `bg` until it reaches `minimum` contrast: brighter (then less
    /// saturated) on dark backgrounds, darker on light ones.
    public static func ensureContrast(_ color: RGB, on bg: RGB, minimum: Double) -> RGB {
        var c = color.hsv
        var out = color
        let darkBackground = bg.luminance < 0.18
        for _ in 0..<60 where out.contrast(with: bg) < minimum {
            if darkBackground {
                if c.v < 1 { c.v = min(1, c.v + 0.05) } else { c.s = max(0, c.s - 0.05) }
            } else {
                c.v = max(0, c.v - 0.05)
            }
            out = RGB(h: c.h, s: c.s, v: c.v)
        }
        return out
    }
}

// MARK: - Player notifications

/// What the players' distributed notifications carry. Neither includes position or artwork
/// (see replica/spike-m1.md), so those come from scripting.
public struct PlayerNotificationInfo: Equatable, Sendable {
    public var state: String          // "Playing", "Paused", "Stopped"
    public var trackID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?      // seconds

    public var isPlaying: Bool { state.caseInsensitiveCompare("Playing") == .orderedSame }

    /// Music: `Total Time` is milliseconds; id is `PersistentID`.
    public static func music(_ info: [AnyHashable: Any]) -> PlayerNotificationInfo {
        PlayerNotificationInfo(state: info["Player State"] as? String ?? "Stopped",
                               trackID: info["PersistentID"].map { "\($0)" },
                               title: info["Name"] as? String, artist: info["Artist"] as? String,
                               album: info["Album"] as? String,
                               duration: (info["Total Time"] as? NSNumber).map { $0.doubleValue / 1000 })
    }

    /// Spotify: `Duration` is milliseconds; id is `Track ID` (a spotify: URI).
    public static func spotify(_ info: [AnyHashable: Any]) -> PlayerNotificationInfo {
        PlayerNotificationInfo(state: info["Player State"] as? String ?? "Stopped",
                               trackID: info["Track ID"] as? String,
                               title: info["Name"] as? String, artist: info["Artist"] as? String,
                               album: info["Album"] as? String,
                               duration: (info["Duration"] as? NSNumber).map { $0.doubleValue / 1000 })
    }
}
