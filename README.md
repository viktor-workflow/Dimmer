<p align="center"><img src="app-icon.png" width="128" alt="Dimmer icon"></p>

# Dimmer

A tiny menu-bar app that dims your Mac's screen below the lowest built-in brightness.

Click the sleeping cat in the menu bar and drag the slider. Dimmer lays a click-through black layer over every screen, so it needs no permissions, makes no network connections and doesn't add itself to Login Items. Your dim level is remembered between launches.

## Install

```sh
brew install --cask viktor-workflow/tap/dimmer
```

Or download `Dimmer.zip` from [Releases](https://github.com/viktor-workflow/Dimmer/releases), unzip it and move `Dimmer.app` to Applications. The app isn't notarised by Apple, so the first time, right-click it and choose **Open**.

## Use

- Drag the slider to dim (up to 92%, so the screen never goes fully black).
- **Off** (⌘0) clears the dimming.
- **Quit Dimmer** (⌘Q) quits and removes the overlay.

To start it at login, add it in System Settings > General > Login Items.

## Build from source

Requires the Xcode Command Line Tools.

```sh
./build.sh   # outputs dist/Dimmer.app and dist/Dimmer.zip
```

Requires macOS 13 or later. Universal (Apple Silicon and Intel).

## Licence

MIT
