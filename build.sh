#!/bin/bash
# Builds a universal Dimmer.app into ./build and zips it.
set -e
cd "$(dirname "$0")"
rm -rf build && B=build/Dimmer.app
mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources"
cp Info.plist "$B/Contents/Info.plist"
cp AppIcon.icns menubar.png menubar@2x.png "$B/Contents/Resources/"
swiftc -O -target arm64-apple-macos13 main.swift -o build/Dimmer-arm64
swiftc -O -target x86_64-apple-macos13 main.swift -o build/Dimmer-x86_64
lipo -create build/Dimmer-arm64 build/Dimmer-x86_64 -output "$B/Contents/MacOS/Dimmer"
rm build/Dimmer-arm64 build/Dimmer-x86_64
codesign --force -s - "$B"
(cd build && ditto -c -k --keepParent Dimmer.app Dimmer.zip)
shasum -a 256 build/Dimmer.zip
