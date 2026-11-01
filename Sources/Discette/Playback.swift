import AppKit
import Combine
import DiscetteCore

/// An AppleScript compiled once and run many times. Scripting the players is the only
/// supported way to read position and artwork (see replica/spike-m1.md).
@MainActor
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

    static func runOnce(_ source: String) {
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }
}

/// -1743: the user has not allowed Discette to control this app (Automation privacy).
let automationNotPermitted = -1743

@MainActor
protocol PlaybackSource: AnyObject {
    var kind: PlayerSource { get }
    var bundleID: String { get }
    var lastErrorNumber: Int? { get }
    func snapshot() -> NowPlaying?
    func loadArtwork(completion: @escaping (NSImage?) -> Void)
}

extension PlaybackSource {
    /// Never script an app that is not running: `tell application` would launch it.
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    func send(_ command: String) {
        guard isRunning else { return }
        CachedScript.runOnce("tell application id \"\(bundleID)\" to \(command)")
    }
    func playPause() { send("playpause") }
    func pause() { send("pause") }
    func nextTrack() { send("next track") }
    func previousTrack() { send("previous track") }
    func seek(to seconds: Double) { send("set player position to \(max(0, seconds))") }
}

extension NSImage {
    /// The cover shrunk to 32x32 RGB samples for colour extraction.
    func samplePixels(side: Int = 32) -> [RGB] {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
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

private extension NSAppleEventDescriptor {
    func string(_ i: Int) -> String { atIndex(i)?.stringValue ?? "" }
    func number(_ i: Int) -> Double { atIndex(i)?.doubleValue ?? 0 }
}

@MainActor
final class MusicAppSource: PlaybackSource {
    let kind = PlayerSource.appleMusic
    let bundleID = "com.apple.Music"
    var lastErrorNumber: Int? { state.lastErrorNumber }

    private let state = CachedScript("""
    tell application id "com.apple.Music"
        set playerState to player state as string
        if playerState is "stopped" then return {playerState}
        set theTrack to current track
        return {playerState, persistent ID of theTrack, name of theTrack, artist of theTrack, album of theTrack, duration of theTrack, player position}
    end tell
    """)
    private let art = CachedScript("""
    tell application id "com.apple.Music" to get raw data of artwork 1 of current track
    """)

    func snapshot() -> NowPlaying? {
        guard isRunning, let r = state.run(), r.numberOfItems >= 7 else { return nil }
        return NowPlaying(source: kind, trackID: r.string(2), title: r.string(3), artist: r.string(4),
                          album: r.string(5), duration: r.number(6), position: r.number(7),
                          positionDate: Date(), isPlaying: r.string(1) == "playing", shareURL: nil)
    }

    func loadArtwork(completion: @escaping (NSImage?) -> Void) {
        guard isRunning, let r = art.run() else { completion(nil); return }
        completion(NSImage(data: r.data))
    }
}

@MainActor
final class SpotifySource: PlaybackSource {
    let kind = PlayerSource.spotify
    let bundleID = "com.spotify.client"
    var lastErrorNumber: Int? { state.lastErrorNumber }
    private var artworkURL: URL?

    private let state = CachedScript("""
    tell application id "com.spotify.client"
        set playerState to player state as string
        if playerState is "stopped" then return {playerState}
        set theTrack to current track
        return {playerState, id of theTrack, name of theTrack, artist of theTrack, album of theTrack, (duration of theTrack) / 1000, player position, spotify url of theTrack, artwork url of theTrack}
    end tell
    """)

    func snapshot() -> NowPlaying? {
        guard isRunning, let r = state.run(), r.numberOfItems >= 9 else { return nil }
        artworkURL = URL(string: r.string(9))
        return NowPlaying(source: kind, trackID: r.string(2), title: r.string(3), artist: r.string(4),
                          album: r.string(5), duration: r.number(6), position: r.number(7),
                          positionDate: Date(), isPlaying: r.string(1) == "playing",
                          shareURL: ShareLink.spotifyWebURL(fromURI: r.string(8)))
    }

    func loadArtwork(completion: @escaping (NSImage?) -> Void) {
        guard let url = artworkURL else { completion(nil); return }
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            completion(data.flatMap { NSImage(data: $0) })
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

    private let sources: [PlaybackSource] = [MusicAppSource(), SpotifySource()]
    private weak var active: PlaybackSource?
    private var artworkTrackID: String?
    private var pollTimer: Timer?
    private var sleepTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var idleTicks = 0

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

    func refresh() {
        var snaps: [(PlaybackSource, NowPlaying)] = []
        var denied: PlayerSource?
        for source in sources where source.isRunning {
            if let snap = source.snapshot() {
                snaps.append((source, snap))
            } else if source.lastErrorNumber == automationNotPermitted {
                denied = source.kind
            }
        }
        needsPermission = denied

        let pick = snaps.first(where: { $0.1.isPlaying })
            ?? snaps.first(where: { $0.0 === active })
            ?? snaps.first
        active = pick?.0
        let next = pick?.1
        if next != nowPlaying { nowPlaying = next }

        guard let source = pick?.0, let snap = next else {
            artworkTrackID = nil
            artwork = nil
            palette = .fallback
            return
        }
        if snap.trackID != artworkTrackID {
            let id = snap.trackID
            artworkTrackID = id
            source.loadArtwork { [weak self] image in
                guard let self, self.artworkTrackID == id else { return }
                self.artwork = image
                self.palette = image.map { ArtworkPalette.extract(from: $0.samplePixels()) } ?? .fallback
            }
        }
    }

    // MARK: Controls

    func playPause() { active?.playPause(); scheduleRefresh() }
    func next() { active?.nextTrack(); scheduleRefresh() }
    func previous() { active?.previousTrack(); scheduleRefresh() }
    func seek(to seconds: Double) { active?.seek(to: seconds); scheduleRefresh() }

    // MARK: Sleep timer

    func startSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        let ends = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepEndsAt = ends
        sleepTimer = Timer.scheduledTimer(withTimeInterval: ends.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.active?.pause()
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
