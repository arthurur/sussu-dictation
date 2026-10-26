#!/usr/bin/env bash
# Builds Sussu.app, signs it and installs it to ~/Applications.
# Signing with your Apple Development identity keeps the Accessibility grant across rebuilds;
# ad-hoc signing (the fallback) makes macOS forget it every time.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

app=build/Sussu.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Sussu "$app/Contents/MacOS/"
# SwiftPM resource bundles from dependencies (FluidAudio) are looked up in Contents/Resources.
cp -R .build/release/*.bundle "$app/Contents/Resources/"
cp Info.plist "$app/Contents/"
cp Assets/AppIcon.icns "$app/Contents/Resources/"

identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
# The bundle ID predates the rename. Keeping it keeps the microphone and Accessibility grants.
codesign --force --sign "${identity:--}" --identifier com.arthurrolim.dictate "$app"

pkill -x Sussu || true
rm -rf ~/Applications/Sussu.app
mkdir -p ~/Applications
cp -R "$app" ~/Applications/
open ~/Applications/Sussu.app
echo "Installed and launched ~/Applications/Sussu.app"
