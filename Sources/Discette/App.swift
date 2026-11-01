import AppKit
import Combine
import DiscetteCore
import SwiftUI

// MARK: - Settings

enum PlayerLayout: String, CaseIterable, Identifiable {
    case sleeve, turntable, record, minimal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sleeve: "Sleeve"
        case .turntable: "Turntable"
        case .record: "Record"
        case .minimal: "Minimal"
        }
    }
}

enum PlayerLook: String, CaseIterable, Identifiable {
    case album, glass, graphite, paper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .album: "Album colours"
        case .glass: "Liquid Glass"
        case .graphite: "Graphite"
        case .paper: "Paper"
        }
    }
}

enum PlayerSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var width: CGFloat {
        switch self {
        case .small: 290
        case .medium: 340
        case .large: 410
        }
    }
}

enum PausedBehavior: String, CaseIterable, Identifiable {
    case keep, emptyPlayer, hide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: "Keep showing the song"
        case .emptyPlayer: "Slide the record back in"
        case .hide: "Hide the player"
        }
    }
}

enum FullScreenBehavior: String, CaseIterable, Identifiable {
    case keep, shrink, hide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: "Stay as it is"
        case .shrink: "Shrink to the mini disc"
        case .hide: "Hide until I leave full screen"
        }
    }
}

enum PinCorner: String, CaseIterable, Identifiable {
    case free, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Free (drag anywhere)"
        case .topLeft: "Pinned top left"
        case .topRight: "Pinned top right"
        case .bottomLeft: "Pinned bottom left"
        case .bottomRight: "Pinned bottom right"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var showPlayer: Bool { didSet { d.set(showPlayer, forKey: "showPlayer") } }
    @Published var layout: PlayerLayout { didSet { d.set(layout.rawValue, forKey: "layout") } }
    @Published var look: PlayerLook { didSet { d.set(look.rawValue, forKey: "look") } }
    @Published var size: PlayerSize { didSet { d.set(size.rawValue, forKey: "size") } }
    @Published var glassClarity: Double { didSet { d.set(glassClarity, forKey: "glassClarity") } }
    @Published var glassTint: Double { didSet { d.set(glassTint, forKey: "glassTint") } }
    @Published var pausedBehavior: PausedBehavior { didSet { d.set(pausedBehavior.rawValue, forKey: "pausedBehavior") } }
    @Published var lyricsEnabled: Bool { didSet { d.set(lyricsEnabled, forKey: "lyricsEnabled") } }
    @Published var lyricsLines: Int { didSet { d.set(lyricsLines, forKey: "lyricsLines") } }
    @Published var lyricsFontSize: Double { didSet { d.set(lyricsFontSize, forKey: "lyricsFontSize") } }
    @Published var spinRecord: Bool { didSet { d.set(spinRecord, forKey: "spinRecord") } }
    @Published var autoShrink: Bool { didSet { d.set(autoShrink, forKey: "autoShrink") } }
    @Published var autoShrinkAfter: Double { didSet { d.set(autoShrinkAfter, forKey: "autoShrinkAfter") } }
    @Published var fullScreenBehavior: FullScreenBehavior { didSet { d.set(fullScreenBehavior.rawValue, forKey: "fullScreenBehavior") } }
    @Published var pinCorner: PinCorner { didSet { d.set(pinCorner.rawValue, forKey: "pinCorner") } }
    @Published var menuBarShowsTitle: Bool { didSet { d.set(menuBarShowsTitle, forKey: "menuBarShowsTitle") } }
    @Published var titleFormat: String { didSet { d.set(titleFormat, forKey: "titleFormat") } }

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func pick<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            T(rawValue: d.string(forKey: key) ?? "") ?? fallback
        }
        showPlayer = bool("showPlayer", true)
        layout = pick("layout", PlayerLayout.sleeve)
        look = pick("look", PlayerLook.album)
        size = pick("size", PlayerSize.medium)
        glassClarity = d.object(forKey: "glassClarity") as? Double ?? 0.6
        glassTint = d.object(forKey: "glassTint") as? Double ?? 0.25
        pausedBehavior = pick("pausedBehavior", PausedBehavior.keep)
        lyricsEnabled = bool("lyricsEnabled", true)
        lyricsLines = min(3, max(1, d.object(forKey: "lyricsLines") as? Int ?? 2))
        lyricsFontSize = d.object(forKey: "lyricsFontSize") as? Double ?? 15
        spinRecord = bool("spinRecord", true)
        autoShrink = bool("autoShrink", true)
        autoShrinkAfter = d.object(forKey: "autoShrinkAfter") as? Double ?? 60
        fullScreenBehavior = pick("fullScreenBehavior", FullScreenBehavior.shrink)
        pinCorner = pick("pinCorner", PinCorner.free)
        menuBarShowsTitle = bool("menuBarShowsTitle", false)
        titleFormat = d.string(forKey: "titleFormat") ?? "{title} by {artist}"
    }
}

// MARK: - Player state

enum Presentation: Equatable {
    case expanded, mini, hidden
}

@MainActor
final class PlayerState: ObservableObject {
    @Published var presentation: Presentation = .expanded
    /// The user's own choice: open card, or shrunk to the mini disc.
    var wantsMini = false
    var hovering = false
    var lastActivity = Date()
    var otherAppFullScreen = false
    /// Clicked the mini disc open while another app is full screen: respect that until
    /// full screen ends.
    var expandedDuringFullScreen = false

    func touch() { lastActivity = Date() }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var hub: PlaybackHub!
    private var lyrics: LyricsController!
    private var state: PlayerState!
    private var events: PanelEvents!
    private var panel: FloatingPanel!
    private var menuBar: MenuBarController!
    private var watcher: FullScreenWatcher!
    private let fullScreen = FullScreenPlayerController()
    private var idleTimer: Timer?
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        hub = PlaybackHub()
        lyrics = LyricsController()
        state = PlayerState()
        events = PanelEvents()

        events.menu = { [weak self] in self?.buildMenu() }
        events.canDrag = { [weak self] in self?.settings.pinCorner == .free }
        events.onHover = { [weak self] inside in
            self?.state.hovering = inside
            self?.state.touch()
        }
        events.onActivity = { [weak self] in self?.state.touch() }
        events.onClick = { [weak self] in self?.expandIfMini() }
        events.onShrink = { [weak self] in self?.shrink() }

        panel = FloatingPanel(name: "player", root: AnyView(
            PlayerRoot(state: state, hub: hub, lyrics: lyrics, settings: settings, events: events)))

        menuBar = MenuBarController(root: AnyView(MenuBarPlayerView(
            hub: hub, lyrics: lyrics, settings: settings,
            actions: MenuBarActions(
                playerVisible: { [weak self] in self?.settings.showPlayer ?? false },
                togglePlayer: { [weak self] in self?.settings.showPlayer.toggle() },
                openFullScreen: { [weak self] in self?.menuBar.closePopover(); self?.openFullScreen() },
                openSettings: { [weak self] in self?.menuBar.closePopover(); self?.openSettings() }))))
        menuBar.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        fullScreen.onClose = { [weak self] in self?.sync() }

        watcher = FullScreenWatcher()
        watcher.onChange = { [weak self] isFull in
            guard let self else { return }
            self.state.otherAppFullScreen = isFull
            self.state.expandedDuringFullScreen = false
            self.sync()
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }

        // Screen resolution or arrangement changed: re-place (and re-pin) the player.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastLayoutKey = ""
                self?.sync()
            }
        }

        let later: (Any) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.sync() } }
        hub.$nowPlaying.sink(receiveValue: later).store(in: &bag)
        settings.objectWillChange.sink(receiveValue: later).store(in: &bag)
        lyrics.$state.removeDuplicates().sink(receiveValue: later).store(in: &bag)

        sync()
    }

    // MARK: Presentation

    private func presentation() -> Presentation {
        if !settings.showPlayer || fullScreen.isOpen { return .hidden }
        let playing = hub.nowPlaying?.isPlaying ?? false
        if settings.pausedBehavior == .hide && !playing { return .hidden }
        if state.otherAppFullScreen && !state.expandedDuringFullScreen {
            switch settings.fullScreenBehavior {
            case .keep: break
            case .shrink: return .mini
            case .hide: return .hidden
            }
        }
        return state.wantsMini ? .mini : .expanded
    }

    private func sync() {
        lyrics.update(for: hub.nowPlaying, enabled: settings.lyricsEnabled)

        if settings.menuBarShowsTitle, let track = hub.nowPlaying {
            let text = TitleFormat.render(settings.titleFormat, title: track.title, artist: track.artist, album: track.album)
            menuBar.setTitle(text.count > 40 ? String(text.prefix(39)) + "…" : text)
        } else {
            menuBar.setTitle(nil)
        }

        let next = presentation()
        if state.presentation != next { state.presentation = next }
        if next == .hidden {
            if panel.isVisible { panel.orderOut(nil) }
            lastLayoutKey = ""
            return
        }
        // Only re-measure when something that changes the size changed, not on every
        // once-a-second position update.
        let key = layoutKey(next)
        guard key != lastLayoutKey || !panel.isVisible else { return }
        lastLayoutKey = key
        // Let SwiftUI apply the change, then size the window to it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.place(size: self.panel.idealSize(), pin: self.settings.pinCorner)
            if !self.panel.isVisible { self.panel.orderFrontRegardless() }
        }
    }

    private var lastLayoutKey = ""

    private func layoutKey(_ presentation: Presentation) -> String {
        let lyricsShape: String
        switch lyrics.state {
        case .loaded(.synced), .loaded(.plain): lyricsShape = "full"
        case .waiting, .off: lyricsShape = "none"
        default: lyricsShape = "status"
        }
        return [
            "\(presentation)", settings.layout.rawValue, settings.size.rawValue, settings.pinCorner.rawValue,
            "\(settings.lyricsEnabled)", "\(settings.lyricsLines)", "\(settings.lyricsFontSize)", lyricsShape,
            "\(hub.nowPlaying == nil)", "\(hub.needsPermission == nil)",
        ].joined(separator: "|")
    }

    private func checkIdle() {
        // Ask where the pointer is rather than trusting enter/exit events: a view created under
        // the pointer never gets "entered", so its "exited" never comes and shrink would stop.
        if panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) {
            state.touch()
            return
        }
        guard settings.autoShrink, !state.wantsMini, state.presentation == .expanded,
              Date().timeIntervalSince(state.lastActivity) > settings.autoShrinkAfter else { return }
        state.wantsMini = true
        sync()
    }

    private func expandIfMini() {
        guard state.presentation == .mini else { return }
        state.wantsMini = false
        if state.otherAppFullScreen { state.expandedDuringFullScreen = true }
        state.touch()
        sync()
    }

    private func shrink() {
        state.wantsMini = true
        sync()
    }

    // MARK: Menu (right-click on the player, right-click on the menu bar icon)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let track = hub.nowPlaying {
            menu.addLabel(track.title)
            menu.addLabel("\(track.artist), in \(track.source.displayName)")
            menu.addItem(.separator())
            menu.add(ActionItem(track.isPlaying ? "Pause" : "Play") { [weak self] in self?.hub.playPause() })
            menu.add(ActionItem("Next Track") { [weak self] in self?.hub.next() })
            menu.add(ActionItem("Previous Track") { [weak self] in self?.hub.previous() })
            menu.add(ActionItem("Copy Song Link", enabled: track.shareURL != nil) { [weak self] in
                guard let url = self?.hub.nowPlaying?.shareURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            })
        } else {
            menu.addLabel(hub.needsPermission == nil
                          ? "Play something in Apple Music or Spotify"
                          : "Allow Discette in Privacy & Security, Automation")
        }
        menu.addItem(.separator())

        menu.add(ActionItem("Show Player", checked: settings.showPlayer) { [weak self] in self?.settings.showPlayer.toggle() })
        if state.presentation == .mini {
            menu.add(ActionItem("Open Player") { [weak self] in self?.expandIfMini() })
        } else if state.presentation == .expanded {
            menu.add(ActionItem("Shrink to Mini Disc") { [weak self] in self?.shrink() })
        }
        menu.add(ActionItem("Full Screen Player") { [weak self] in self?.openFullScreen() })

        menu.addSubmenu("Layout") { sub in
            for option in PlayerLayout.allCases {
                sub.add(ActionItem(option.label, checked: settings.layout == option) { [weak self] in self?.settings.layout = option })
            }
        }
        menu.addSubmenu("Look") { sub in
            for option in PlayerLook.allCases {
                sub.add(ActionItem(option.label, checked: settings.look == option) { [weak self] in self?.settings.look = option })
            }
        }
        menu.addSubmenu("Position") { sub in
            for option in PinCorner.allCases {
                sub.add(ActionItem(option.label, checked: settings.pinCorner == option) { [weak self] in self?.settings.pinCorner = option })
            }
        }
        menu.addSubmenu("Lyrics") { sub in
            sub.add(ActionItem("Show Lyrics", checked: settings.lyricsEnabled) { [weak self] in self?.settings.lyricsEnabled.toggle() })
            if lyrics.syncedLines != nil {
                sub.addItem(.separator())
                sub.add(ActionItem("Show Lyrics Earlier (0.5 s)") { [weak self] in self?.lyrics.nudge(by: 0.5) })
                sub.add(ActionItem("Show Lyrics Later (0.5 s)") { [weak self] in self?.lyrics.nudge(by: -0.5) })
                sub.add(ActionItem("Reset Timing", enabled: lyrics.offset != 0) { [weak self] in
                    guard let self else { return }
                    self.lyrics.nudge(by: -self.lyrics.offset)
                })
            }
        }
        menu.addSubmenu(sleepTitle()) { sub in
            for minutes in [15, 30, 45, 60, 90] {
                sub.add(ActionItem("\(minutes) minutes") { [weak self] in self?.hub.startSleepTimer(minutes: minutes) })
            }
            if hub.sleepEndsAt != nil {
                sub.addItem(.separator())
                sub.add(ActionItem("Cancel Timer") { [weak self] in self?.hub.cancelSleepTimer() })
            }
        }
        menu.addItem(.separator())
        menu.add(ActionItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.add(ActionItem("Quit Discette", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func sleepTitle() -> String {
        guard let ends = hub.sleepEndsAt else { return "Sleep Timer" }
        return "Sleep Timer (\(max(1, Int(ends.timeIntervalSinceNow / 60 + 0.5))) min left)"
    }

    // MARK: Windows

    private func openFullScreen() {
        fullScreen.open(root: AnyView(FullScreenPlayerView(hub: hub, lyrics: lyrics, settings: settings) { [weak self] in
            self?.fullScreen.close()
        }))
        sync()
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            window.title = "Discette Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@main
struct DiscetteMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
