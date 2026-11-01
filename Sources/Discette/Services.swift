import AppKit
import ApplicationServices
import DiscetteCore
import ServiceManagement

// MARK: - Listening stats

/// Counts listening time while music plays and keeps it in
/// ~/Library/Application Support/Discette/stats.json. Nothing leaves the Mac.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var stats = ListeningStats()
    private let hub: PlaybackHub
    private var lastTick: Date?
    private var timer: Timer?
    private var unsaved = 0

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Discette", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stats.json")
    }()

    init(hub: PlaybackHub) {
        self.hub = hub
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(ListeningStats.self, from: data) {
            stats = saved
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard let track = hub.nowPlaying, track.isPlaying, let last = lastTick else { return }
        stats.record(seconds: now.timeIntervalSince(last), artist: track.artist, at: now)
        unsaved += 1
        if unsaved >= 30 { save() }
    }

    func save() {
        guard unsaved > 0, let data = try? JSONEncoder().encode(stats) else { return }
        try? data.write(to: url, options: .atomic)
        unsaved = 0
    }

    func reset() {
        stats = ListeningStats()
        unsaved = 1
        save()
    }
}

// MARK: - Open at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Discette: open at login change failed: %@", "\(error)")
        }
    }
}

// MARK: - Accessibility (full-screen detection)

enum AccessibilityAccess {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "Discette would like to control this computer" prompt.
    static func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether the app's focused window is in macOS full screen. On notched MacBooks a
    /// full-screen window is the same size as a maximised one, so size can't tell them apart.
    static func focusedWindowIsFullScreen(pid: pid_t) -> Bool {
        guard isGranted else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // a hung app shouldn't hold the check for long
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }
}
