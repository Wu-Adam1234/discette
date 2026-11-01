# Discette

A record for your Mac desktop. Discette shows what's playing in Apple Music or Spotify as a small
floating player: the cover becomes a sleeve, the record slides out and turns while the song plays,
synced lyrics run underneath, and the whole player takes its colours from the album.

Free and open source (MIT).

## What it does

- **One player, your way.** Four layouts (Sleeve, Turntable, Record, Minimal) and four looks
  (Album colours, Liquid Glass, Graphite, Paper). Three sizes.
- **Synced lyrics** at the bottom of the player, 1 to 3 lines, with timing you can nudge.
- **Gets out of the way.** After a minute without use it shrinks to a small spinning disc; click it
  to open the player again. When another app goes full screen it can stay, shrink or hide.
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

- macOS 15 or later, Apple silicon or Intel
- Apple Music and/or Spotify desktop app

## Build

```bash
git clone <this repo>
cd Discette
swift test                  # unit tests
scripts/bundle.sh           # builds build/Discette.app
open build/Discette.app
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

## Privacy

Discette has no analytics and no accounts. The only network requests are:

- **Lyrics** from [LRCLIB](https://lrclib.net), a free community lyrics database. Discette sends the
  song title, artist, album and length. Results are cached on your Mac in
  `~/Library/Application Support/Discette/`.
- **Spotify artwork**, downloaded from the image address the Spotify app provides.

Lyrics are copyrighted by their authors and publishers. Discette fetches them for display on your
own Mac and never stores them in this repository.

## Project layout

```
Sources/DiscetteCore   pure logic: lyrics parsing and sync, album colours, formatting (tested)
Sources/Discette       the app: players, lyrics client, windows, views, menu bar
Tests/                 unit tests
scripts/               app bundle and icon scripts
```

## Not affiliated

Discette is an independent project. It is not affiliated with or endorsed by Apple or Spotify.
Apple Music is a trademark of Apple Inc. Spotify is a trademark of Spotify AB.

## License

MIT. See [LICENSE](LICENSE).
