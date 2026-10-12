# NowMusicBar

I wanted the song I'm listening to written in my Mac's menu bar, with a little album-art thumbnail. I didn't want to pay for an app to do it, so I made this. It's been useful to me, and maybe you'll find it useful too.

![NowMusicBar in the menu bar](docs/menubar.png)

![Hovering over NowMusicBar](docs/demo.gif)

- **Click** the menu-bar item to play or pause. **Right-click** for the menu.
- **Hover** for a panel with artwork, a draggable track timer, Shuffle, Previous, Play/Pause, Next, Repeat, and **+** to add the song to your library.
- Opens at login. Follows light and dark mode and respects Reduce Motion.
- Apple Music and Podcasts only. Other audio (Safari, Spotify) is ignored.

## Build

Needs macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
./build.sh
```

This compiles NowMusicBar, installs it in `/Applications` and opens it. The first time you use **+**, macOS asks whether NowMusicBar may control Music.

## How it reads Podcasts

The Podcasts app can't be scripted, and since macOS 15.4 apps are blocked from reading the system's now-playing info directly. NowMusicBar runs a small helper (`helper.m`) inside the system Perl, which is still allowed to read it. Other menu-bar players use the same approach. **A future macOS update may close this**, and Podcasts would then stop showing. Add to library uses Music's own scripting.

## Status

A personal project, shared as-is. No support or updates are promised.

## License

MIT
