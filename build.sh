#!/bin/bash
# Builds a universal Dimmer.app into ./dist and zips it.
set -e
cd "$(dirname "$0")"
rm -rf dist && B=dist/Dimmer.app
mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
cp Info.plist "$B/Contents/Info.plist"
cp AppIcon.icns menubar.png menubar@2x.png "$B/Contents/Resources/"
swiftc -O -target arm64-apple-macos13 main.swift -o dist/Dimmer-arm64
swiftc -O -target x86_64-apple-macos13 main.swift -o dist/Dimmer-x86_64
lipo -create dist/Dimmer-arm64 dist/Dimmer-x86_64 -output "$B/Contents/MacOS/Dimmer"
rm dist/Dimmer-arm64 dist/Dimmer-x86_64
codesign --force -s - "$B"
(cd dist && ditto -c -k --keepParent Dimmer.app Dimmer.zip)
shasum -a 256 dist/Dimmer.zip
