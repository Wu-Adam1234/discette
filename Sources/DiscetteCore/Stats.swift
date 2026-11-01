import Foundation

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    /// Apple Music cycles off -> all -> one -> off.
    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    /// Music's AppleScript `song repeat` value.
    public init?(musicValue: String) {
        switch musicValue.lowercased() {
        case "off": self = .off
        case "all": self = .all
        case "one": self = .one
        default: return nil
        }
    }
}

/// Listening time, kept only on this Mac. Days are keyed by local calendar date.
public struct ListeningStats: Codable, Equatable, Sendable {
    public var days: [String: Double] = [:]      // "2026-10-31" -> seconds
    public var artists: [String: Double] = [:]   // artist -> seconds
    /// A day counts towards the streak after this much listening.
    public static let streakMinimum: Double = 60

    public init() {}

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Adds listening time. Gaps longer than `maxStep` (sleep, a stalled poll) are not counted.
    public mutating func record(seconds: Double, artist: String, at date: Date, calendar: Calendar = .current,
                                maxStep: Double = 5) {
        let s = min(max(0, seconds), maxStep)
        guard s > 0 else { return }
        days[Self.key(date, calendar), default: 0] += s
        let name = artist.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { artists[name, default: 0] += s }
    }

    public func today(_ date: Date = Date(), calendar: Calendar = .current) -> Double {
        days[Self.key(date, calendar)] ?? 0
    }

    /// The last 7 days including today.
    public func week(_ date: Date = Date(), calendar: Calendar = .current) -> Double {
        (0..<7).reduce(0) { total, back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: date) else { return total }
            return total + (days[Self.key(d, calendar)] ?? 0)
        }
    }

    /// Consecutive days with at least a minute of listening, ending today (or yesterday, if
    /// today hasn't reached a minute yet, so the streak isn't "lost" in the morning).
    public func streak(_ date: Date = Date(), calendar: Calendar = .current) -> Int {
        var day = date
        if (days[Self.key(day, calendar)] ?? 0) < Self.streakMinimum {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }
        var count = 0
        while (days[Self.key(day, calendar)] ?? 0) >= Self.streakMinimum {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    public func topArtists(_ limit: Int = 5) -> [(name: String, seconds: Double)] {
        artists.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { ($0.key, $0.value) }
    }

    /// "2h 05m", "14m", "45s"
    public static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
