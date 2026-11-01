import AppKit
import Combine
import DiscetteCore
import ImageIO

/// An AppleScript compiled once and run many times. Scripting the players is the only
/// supported way to read position and artwork (see replica/spike-m1.md). Used only on
/// `scriptQueue`.
final class CachedScript {
    private let script: NSAppleScript?
    private(set) var lastErrorNumber: Int?

    init(_ source: String) { script = NSAppleScript(source: source) }

    func run() -> NSAppleEventDescriptor? {
        guard let script else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int
            if number != lastErrorNumber {
                NSLog("Discette: player script failed (%d): %@", number ?? 0,
                      (error[NSAppleScript.errorMessage] as? String) ?? "no message")
            }
            lastErrorNumber = number
            return nil
        }
        lastErrorNumber = nil
        return result
    }
}

/// Every AppleScript call (polling, artwork, queue, play, skip) runs on this one serial queue,
/// never on the main thread. Each call waits for Music or Spotify to answer; on the main thread
/// that wait froze drawing and clicks, so the record hitched about once a second and buttons felt
/// slow. One serial queue also keeps the calls in order: a skip lands before the next poll.
let scriptQueue = DispatchQueue(label: "app.discette.scripts", qos: .userInitiated)

/// -1743: the user has not allowed Discette to control this app (Automation privacy).
let automationNotPermitted = -1743

/// A player Discette can script. Every method runs on `scriptQueue`.
protocol PlaybackSource: AnyObject, Sendable {
    var kind: PlayerSource { get }
    var bundleID: String { get }
    var lastErrorNumber: Int? { get }
    func snapshot() -> NowPlaying?
    /// The cover's encoded bytes; decoding happens off the main thread.
    func loadArtwork(completion: @escaping (Data?) -> Void)
    func toggleShuffle()
    func setRepeat(_ mode: RepeatMode)
    func toggleFavorite()
    /// The next songs from the playlist being played, or nil if the player doesn't share it.
    func queue(limit: Int) -> PlayQueue?
    func playQueued(_ index: Int)
}

extension PlaybackSource {
    /// Never script an app that is not running: `tell application` would launch it.
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    func send(_ command: String) {
        guard isRunning else { return }
        _ = NSAppleScript(source: "tell application id \"\(bundleID)\" to \(command)")?.executeAndReturnError(nil)
    }
    func playPause() { send("playpause") }
    func pause() { send("pause") }
    func nextTrack() { send("next track") }
    func previousTrack() { send("previous track") }
    func queue(limit: Int) -> PlayQueue? { nil }
    func playQueued(_ index: Int) {}
    func seek(to seconds: Double) { send("set player position to \(max(0, seconds))") }
}

extension CGImage {
    /// The image shrunk to side x side RGB samples.
    func samplePixels(side: Int = 32) -> [RGB] {
        let cg = self
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map {
            RGB(Double(bytes[$0]) / 255, Double(bytes[$0 + 1]) / 255, Double(bytes[$0 + 2]) / 255)
        }
    }
}

private extension Date {
    /// Halfway between this moment and now: when a script that started here read the position.
    var midpoint: Date { addingTimeInterval(Date().timeIntervalSince(self) / 2) }
}

private extension NSAppleEventDescriptor {
    func string(_ i: Int) -> String { atIndex(i)?.stringValue ?? "" }
    func number(_ i: Int) -> Double { atIndex(i)?.doubleValue ?? 0 }
    /// nil for "missing value" or anything that isn't a boolean.
    func bool(_ i: Int) -> Bool? {
        guard i <= numberOfItems, let d = atIndex(i) else { return nil }
        switch d.descriptorType {
        case typeTrue: return true
        case typeFalse: return false
        case typeBoolean: return d.booleanValue
        default: return nil
        }
    }
}

final class MusicAppSource: PlaybackSource, @unchecked Sendable {
    let kind = PlayerSource.appleMusic
    let bundleID = "com.apple.Music"
    var lastErrorNumber: Int? { state.lastErrorNumber }

    private let state = CachedScript("""
    tell application id "com.apple.Music"
        set playerState to player state as string
        if playerState is "stopped" then return {playerState}
        set theTrack to current track
        set isFavorite to missing value
        try
            set isFavorite to favorited of theTrack
        end try
        return {playerState, persistent ID of theTrack, name of theTrack, artist of theTrack, album of theTrack, duration of theTrack, player position, shuffle enabled, song repeat as string, isFavorite}
    end tell
    """)
    private let art = CachedScript("""
    tell application id "com.apple.Music" to get raw data of artwork 1 of current track
    """)

    func snapshot() -> NowPlaying? {
        guard isRunning else { return nil }
        let asked = Date()
        guard let r = state.run(), r.numberOfItems >= 7 else { return nil }
        return NowPlaying(source: kind, trackID: r.string(2), title: r.string(3), artist: r.string(4),
                          album: r.string(5), duration: r.number(6), position: r.number(7),
                          positionDate: asked.midpoint, isPlaying: r.string(1) == "playing", shareURL: nil,
                          shuffle: r.bool(8), repeatMode: RepeatMode(musicValue: r.string(9)), favorite: r.bool(10))
    }

    func toggleShuffle() { send("set shuffle enabled to not shuffle enabled") }
    func setRepeat(_ mode: RepeatMode) { send("set song repeat to \(mode.rawValue)") }
    func toggleFavorite() { send("set favorited of current track to not (favorited of current track)") }

    private let upNext = CachedScript("""
    tell application id "com.apple.Music"
        set p to current playlist
        set i to index of current track
        set n to count of tracks of p
        set lastK to i + 6
        if lastK > n then set lastK to n
        if lastK <= i then return {name of p, shuffle enabled, i, {}, {}}
        return {name of p, shuffle enabled, i, name of tracks (i + 1) thru lastK of p, artist of tracks (i + 1) thru lastK of p}
    end tell
    """)

    func queue(limit: Int) -> PlayQueue? {
        guard isRunning, let r = upNext.run(), r.numberOfItems >= 5,
              let names = r.atIndex(4), let artists = r.atIndex(5) else { return nil }
        let first = Int(r.number(3)) + 1
        let count = min(limit, names.numberOfItems)
        let items = count > 0 ? (1...count).map { k in
            PlayQueue.Item(index: first + k - 1, title: names.string(k), artist: artists.string(k))
        } : []
        return PlayQueue(playlist: r.string(1), shuffled: r.bool(2) ?? false, items: items)
    }

    func playQueued(_ index: Int) { send("play track \(index) of current playlist") }

    func loadArtwork(completion: @escaping (Data?) -> Void) {
        guard isRunning, let r = art.run() else { completion(nil); return }
        completion(r.data)
    }
}

final class SpotifySource: PlaybackSource, @unchecked Sendable {
    let kind = PlayerSource.spotify
    let bundleID = "com.spotify.client"
    var lastErrorNumber: Int? { state.lastErrorNumber }
    private var artworkURL: URL?

    private let state = CachedScript("""
    tell application id "com.spotify.client"
        set playerState to player state as string
        if playerState is "stopped" then return {playerState}
        set theTrack to current track
        return {playerState, id of theTrack, name of theTrack, artist of theTrack, album of theTrack, (duration of theTrack) / 1000, player position, spotify url of theTrack, artwork url of theTrack, shuffling, repeating}
    end tell
    """)

    func snapshot() -> NowPlaying? {
        guard isRunning else { return nil }
        let asked = Date()
        guard let r = state.run(), r.numberOfItems >= 9 else { return nil }
        artworkURL = URL(string: r.string(9))
        return NowPlaying(source: kind, trackID: r.string(2), title: r.string(3), artist: r.string(4),
                          album: r.string(5), duration: r.number(6), position: r.number(7),
                          positionDate: asked.midpoint, isPlaying: r.string(1) == "playing",
                          shareURL: ShareLink.spotifyWebURL(fromURI: r.string(8)),
                          // Spotify repeat is on/off only; saving to your library isn't scriptable.
                          shuffle: r.bool(10), repeatMode: r.bool(11).map { $0 ? .all : .off }, favorite: nil)
    }

    func toggleShuffle() { send("set shuffling to not shuffling") }
    func setRepeat(_ mode: RepeatMode) { send("set repeating to \(mode == .off ? "false" : "true")") }
    func toggleFavorite() {}

    func loadArtwork(completion: @escaping (Data?) -> Void) {
        guard let url = artworkURL else { completion(nil); return }
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            completion(data)
        }
    }
}

/// Watches both players and publishes whichever one matters right now.
@MainActor
final class PlaybackHub: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    /// Colours of the current cover. Kept while the next cover loads, so the player
    /// never flashes grey between songs.
    @Published private(set) var palette: ArtworkPalette = .fallback
    @Published private(set) var needsPermission: PlayerSource?
    @Published private(set) var sleepEndsAt: Date?
    /// Up next, loaded only while the queue is on screen.
    @Published private(set) var queue: PlayQueue?
    var wantsQueue = false { didSet { if wantsQueue != oldValue { loadQueue() } } }
    private var queueKey: String?

    private let sources: [PlaybackSource] = [MusicAppSource(), SpotifySource()]
    private weak var active: PlaybackSource?
    private var artworkTrackID: String?
    private var pollTimer: Timer?
    private var sleepTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var idleTicks = 0
    private var refreshing = false
    private var refreshAgain = false
    /// Bumped by every command, so a poll that started before it can't undo what it showed.
    private var commands = 0

    init() {
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRefresh() } }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    /// Players post each change twice, ~0.1 s apart. Wait for the burst to settle.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Poll every second while playing (position drift), every 5 s otherwise
    /// (notifications cover the rest).
    private func tick() {
        if nowPlaying?.isPlaying == true { refresh(); return }
        idleTicks += 1
        if idleTicks >= 5 { idleTicks = 0; refresh() }
    }

    /// Reads both players on the script queue, then publishes on the main thread.
    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let sources = self.sources
        let startedAt = commands
        scriptQueue.async { [weak self] in
            var snaps: [(PlaybackSource, NowPlaying)] = []
            var denied: PlayerSource?
            for source in sources where source.isRunning {
                if let snap = source.snapshot() {
                    snaps.append((source, snap))
                } else if source.lastErrorNumber == automationNotPermitted {
                    denied = source.kind
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if startedAt == self.commands {
                    self.apply(snaps, denied: denied)
                } else {
                    self.refreshAgain = true // a command went out meanwhile: read again after it
                }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    private func apply(_ snaps: [(PlaybackSource, NowPlaying)], denied: PlayerSource?) {
        if needsPermission != denied { needsPermission = denied }

        let pick = snaps.first(where: { $0.1.isPlaying })
            ?? snaps.first(where: { $0.0 === active })
            ?? snaps.first
        active = pick?.0
        let next = pick?.1.keepingTiming(of: nowPlaying)
        if next != nowPlaying { nowPlaying = next }
        // Reload the queue when the song or the shuffle setting changes.
        let key = next.map { "\($0.source)|\($0.trackID)|\($0.shuffle ?? false)" }
        if wantsQueue, key != queueKey { loadQueue() }

        guard let source = pick?.0, let snap = next else {
            artworkTrackID = nil
            if artwork != nil { artwork = nil }
            if palette != .fallback { palette = .fallback }
            return
        }
        if snap.trackID != artworkTrackID {
            let id = snap.trackID
            artworkTrackID = id
            scriptQueue.async { [weak self] in
                source.loadArtwork { [weak self] data in
                    PlaybackHub.artworkQueue.async { [weak self] in
                        let (image, palette) = PlaybackHub.prepareArtwork(data)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.artworkTrackID == id else { return }
                            self.artwork = image
                            self.palette = palette
                        }
                    }
                }
            }
        }
    }

    // MARK: Artwork

    nonisolated private static let artworkQueue = DispatchQueue(label: "app.discette.artwork", qos: .userInitiated)

    /// Covers arrive full size (often 1-3000 px). Decode once, already shrunk to what the player
    /// can show, and take the colours from that, all off the main thread: decoding the full image
    /// on the main thread stalled every song change, and drawing it full size every frame made the
    /// record work hard.
    nonisolated static func prepareArtwork(_ data: Data?) -> (NSImage?, ArtworkPalette) {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600,
              ] as CFDictionary) else { return (nil, .fallback) }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, ArtworkPalette.extract(from: cg.samplePixels()))
    }

    // MARK: Controls

    /// Sends a command on the script queue and reads the player again once it has landed.
    private func command(_ work: @escaping (PlaybackSource) -> Void) {
        guard let source = active else { return }
        commands += 1
        scriptQueue.async { [weak self] in
            work(source)
            DispatchQueue.main.async { [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Shows a change at once, before the player confirms it.
    private func show(_ change: (inout NowPlaying) -> Void) {
        guard var track = nowPlaying else { return }
        let now = Date()
        track.position = track.position(at: now)
        track.positionDate = now
        change(&track)
        nowPlaying = track
    }

    func playPause() {
        show { $0.isPlaying.toggle() }
        command { $0.playPause() }
    }
    func next() { command { $0.nextTrack() } }
    func previous() { command { $0.previousTrack() } }
    func seek(to seconds: Double) {
        show { $0.position = seconds }
        command { $0.seek(to: seconds) }
    }
    func toggleShuffle() {
        show { track in track.shuffle = track.shuffle.map { !$0 } }
        command { $0.toggleShuffle() }
    }
    func cycleRepeat() {
        guard let source = active, let mode = nowPlaying?.repeatMode else { return }
        // Spotify only has on/off, so its cycle is off <-> all.
        let next = source.kind == .spotify ? (mode == .off ? RepeatMode.all : .off) : mode.next
        show { $0.repeatMode = next }
        command { $0.setRepeat(next) }
    }
    func toggleFavorite() {
        show { track in track.favorite = track.favorite.map { !$0 } }
        command { $0.toggleFavorite() }
    }
    func playQueued(_ index: Int) { command { $0.playQueued(index) } }

    private func loadQueue() {
        queueKey = nowPlaying.map { "\($0.source)|\($0.trackID)|\($0.shuffle ?? false)" }
        guard wantsQueue, let source = active else {
            if queue != nil { queue = nil }
            return
        }
        scriptQueue.async { [weak self] in
            let next = source.queue(limit: 5)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsQueue, next != self.queue else { return }
                self.queue = next
            }
        }
    }

    /// The running player's process id, for the visualizer's audio tap.
    var activeBundleID: String? { active?.bundleID }

    // MARK: Sleep timer

    func startSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        let ends = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepEndsAt = ends
        sleepTimer = Timer.scheduledTimer(withTimeInterval: ends.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.command { $0.pause() }
                self?.sleepEndsAt = nil
                self?.scheduleRefresh()
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepEndsAt = nil
    }
}
