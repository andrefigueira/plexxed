# Plexxed

A fast, native macOS client for your Plex Media Server.

Plexxed plays your files straight off the server through mpv, so the server never has to transcode. It opens instantly from a local cache and keeps out of the way while you watch.

## What it does

- **Direct play.** Anything mpv can open plays as the original file, with VideoToolbox hardware decoding and a deep read-ahead cache.
- **Instant launch.** Home, libraries and artwork are cached on disk and refreshed in the background.
- **Finds your server on its own.** On your home network it talks to the server over plain HTTP. Away from home it falls back to Plex's secure and relay addresses.
- **Works with the rest of Plex.** Resume points, watched state, your audio and subtitle choices and external subtitle files all come from Plex, and changes go back to Plex so your other apps see them.
- **Skip Intro and Up Next.** Uses Plex's intro and credits markers, with a countdown to the next episode.
- **Recommendations from your own history.** Top picks, "Because you watched" rows and a row for the actor or director you watch most, all computed on your Mac.
- **A quiet player.** Controls fade after a moment of stillness, and everything has a key.

## Requirements

- macOS 26 or later
- Xcode 26 (Swift 6.2 or later)
- mpv from Homebrew, which provides libmpv

```sh
brew install mpv
```

## Build and run

```sh
git clone https://github.com/andrefigueira/plexxed.git
cd plexxed
scripts/build.sh
open build/Plexxed.app
```

`scripts/build.sh debug` makes a debug build. The app is signed ad hoc for your own Mac and loads libmpv from Homebrew when it starts, so keep mpv installed.

On first launch, sign in with your Plex account in the browser and pick a server. macOS asks for Local Network access the first time. Allow it so Plexxed can reach your server directly.

## Keyboard

| Action | Key |
| --- | --- |
| Play or pause | Space |
| Back or forward 10 seconds | Left, Right (Shift for 60 seconds) |
| Volume | Up, Down |
| Mute | M |
| Full screen | F, or double-click |
| Skip intro | S |
| Next episode | N |
| Leave the player | Esc or Command-W |

## How recommendations work

Every movie and show becomes a set of weighted features: genres, director, writers, cast, studio, country, decade and audience (kids, teen or adult from the content rating). Rare features count for more, so a shared director matters more than a shared "Drama".

Your watch history builds a taste profile from those features. Recent plays weigh more than old ones, binged shows and rewatched films weigh more than a single episode, and films you gave up on early count against their kind.

Unwatched titles are scored against that profile, nudged by rating and how recently they were added, then re-ranked so each row stays varied. Each row holds one title per franchise, and kids titles are kept out of grown-up rows. "Because you watched" rows also get a boost from Plex's own similar-titles list.

The whole thing runs in a few milliseconds on a library of a few hundred titles. The only requests it makes go to your own server.

## Privacy

- Your Plex token is stored in `~/Library/Application Support/Plexxed/credentials.json`, readable only by your user account. It is only sent to plex.tv and to your own servers.
- Logs are written to `~/Library/Logs/Plexxed.log` and never include tokens.
- Nothing is sent to anyone else. There is no analytics or tracking.

## Project layout

| Folder | What's in it |
| --- | --- |
| `Sources/Plexxed/App` | App state, sign-in and server connection |
| `Sources/Plexxed/Plex` | The Plex API client and models |
| `Sources/Plexxed/Player` | The mpv wrapper, the video layer, playback sessions and the player UI |
| `Sources/Plexxed/Recommendations` | The recommendation engine and the data it loads |
| `Sources/Plexxed/UI` | Views, shared components and the design tokens in `Theme.swift` |
| `Sources/Plexxed/Support` | Response cache, image pipeline, logging and storage |
| `Sources/Cmpv` | The module map that exposes libmpv to Swift |
| `scripts` | The app bundle build script and the icon generator |

Video is drawn by mpv's OpenGL render API into a `CAOpenGLLayer`, only when mpv has a new frame. `swift scripts/make-icon.swift` redraws `Resources/AppIcon.icns`.

For development, `--open <ratingKey>` opens an item's page and `--play <ratingKey>` starts playing it as soon as the app connects:

```sh
open build/Plexxed.app --args --play 12345
```

## Contributing

Issues and pull requests are welcome. Please keep changes small and focused, and match the existing style.

## License

MIT, see [LICENSE](LICENSE).

Plexxed links against libmpv. Homebrew's mpv is built under the GPL, so any build you distribute with libmpv bundled inside has to follow the GPL as well.

Plexxed is an independent project with no connection to Plex, Inc. Plex is a trademark of Plex, Inc.
