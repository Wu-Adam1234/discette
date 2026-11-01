# Discette

[![CI](https://github.com/Wu-Adam1234/discette/actions/workflows/ci.yml/badge.svg)](https://github.com/Wu-Adam1234/discette/actions/workflows/ci.yml)

A record for your Mac desktop. Discette shows what's playing in Apple Music or Spotify as a small
floating player: the cover becomes a sleeve, the record slides out and turns while the song plays,
synced lyrics run underneath, and the whole player takes its colours from the album.

Free and open source (MIT).

## Install

1. Download `Discette-<version>.zip` from the [latest release](https://github.com/Wu-Adam1234/discette/releases/latest) and unzip it.
2. Drag **Discette.app** into your **Applications** folder.
3. Open it. Discette isn't notarized by Apple (notarizing needs a paid developer account), so macOS
   warns you the first time. Go to **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway**. Or run this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Discette.app
   ```
4. Play something in Apple Music or Spotify. When macOS asks whether Discette may control Music or
   Spotify, click **Allow**. The player appears in the corner of your screen and the Discette mark
   appears in the menu bar.

Discette turns on **Open at login** the first time it runs from Applications. You can change that in
Settings.

## Using it

- **Drag** the player anywhere. **Right-click** it, or the menu bar icon, for every option.
- The **arrows** button in the top corner shrinks it to a spinning disc in the same corner; click the
  disc to open it again.
- The **list** button shows what's up next; click a song to play it.
- **Settings** (right-click → Settings…) has the layout, look, size slider, controls, lyrics timing
  and listening stats.

## What it does

- **One player, your way.** Four layouts (Sleeve, Turntable, Record, Minimal) and four looks
  (Album colours, Liquid Glass, Graphite, Paper). Any size, from a slider.
- **Synced lyrics**, one line that fills in word by word as the song sings it (character by
  character for Japanese, Chinese and Korean). Timing can be shifted for every song, or per song.
- **Up next.** The next songs from the playlist Apple Music is playing; click one to play it.
- **Liquid Glass that stays readable.** Its text and buttons turn black on light backgrounds and
  white on dark ones.
- **Gets out of the way.** Shrink it to a small spinning disc that sits in the player's
  bottom-right corner; click it to open the player again. It can also shrink by itself after a
  while without use (off by default). When another app goes full screen it can stay, shrink or hide.
- **Stays where you put it.** Drag it anywhere, or pin it to any corner of the screen.
- **Full-screen player** for when the music is the point.
- **Menu bar.** Just the Discette mark (the song title is optional). Click for a mini player,
  right-click for every option.
- **No accounts.** Discette reads the Music and Spotify apps on your Mac. Nothing to log into.

## Accessibility

- Respects Reduce Motion (the record stops turning, slides happen instantly), Reduce Transparency
  (Liquid Glass becomes solid) and Increase Contrast.
- Every control has a VoiceOver label. The progress bar is adjustable in 10-second steps.
- Keyboard: in the menu bar player and full-screen player, Space plays or pauses and the arrow keys
  skip. Esc leaves full screen.
- Every colour pair the player draws is checked against WCAG contrast (body text 7:1, secondary
  text and controls 4.5:1), including the colours taken from album covers.

## Requirements

- macOS 15 or later, Apple silicon or Intel (Liquid Glass needs macOS 26; older systems get frosted glass)
- Apple Music and/or Spotify desktop app

## Build

Needs Xcode 26 or its command line tools (the macOS 26 SDK).

```bash
git clone https://github.com/Wu-Adam1234/discette.git
cd discette
swift test                  # unit tests
scripts/bundle.sh           # builds ~/Library/Caches/Discette-build/Discette.app
scripts/bundle.sh release install   # builds and replaces /Applications/Discette.app
scripts/bundle.sh release zip       # builds dist/Discette-<version>.zip for a release
```

To regenerate the app icon:

```bash
swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

## Permissions

On first launch macOS asks whether Discette may control **Music** and **Spotify** (System Settings,
Privacy & Security, Automation). Discette uses this only to read the current song and to play,
pause, skip and seek.

With the Liquid Glass look, Discette also asks for **Screen & System Audio Recording**, to tell
whether the background behind the player is light or dark. Every 2 seconds it looks at a 24 x 24
pixel thumbnail of the area under the player (its own windows left out), works out one brightness
number and throws the image away. Without the permission the glass keeps the system's colours.
The live visualizer uses the same permission to hear Music or Spotify only.

## Privacy

Discette has no analytics and no accounts. Nothing it sees on screen or hears is stored or sent. The only network requests are:

- **Lyrics** from [LRCLIB](https://lrclib.net), a free community lyrics database. Discette sends the
  song title, artist, album and length. Results are cached on your Mac in
  `~/Library/Application Support/Discette/`.
- **Spotify artwork**, downloaded from the image address the Spotify app provides.

Lyrics are copyrighted by their authors and publishers. Discette fetches them for display on your
own Mac and never stores them in this repository.

## Project layout

```
Sources/DiscetteCore   pure logic: lyrics parsing, sync and reveal, album colours, stats (tested)
Sources/Discette       the app: players, lyrics client, windows, views, menu bar, visualizer
Tests/                 unit tests
scripts/               app bundle and icon scripts
.github/workflows/     CI: tests and a downloadable build on every push
```

## Troubleshooting

- **Lyrics run early or late.** Apple Music's AutoMix and Crossfade shift the song against the
  position Music reports to other apps, by a different amount on every transition. Turn them off in
  Music → Settings → Playback, or move the **Timing** slider in Settings → Lyrics. Right-click →
  Lyrics nudges a single song.
- **Can't see the menu bar icon.** A full menu bar hides extra icons behind the notch. Quit a menu bar
  app or two, or check System Settings → Menu Bar.
- **Says to allow Discette.** Open System Settings → Privacy & Security → Automation and turn on
  Music and/or Spotify under Discette.

## Not affiliated

Discette is an independent project. It is not affiliated with or endorsed by Apple or Spotify.
Apple Music is a trademark of Apple Inc. Spotify is a trademark of Spotify AB.

## License

MIT. See [LICENSE](LICENSE).
