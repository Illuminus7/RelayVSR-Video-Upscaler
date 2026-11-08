#!/bin/bash
# Packs build/RelayVSR.app into build/RelayVSR-<version>.dmg: the app plus a link to
# /Applications, for drag-and-drop installation. Run scripts/build_app.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/RelayVSR.app"
[ -d "$APP" ] || { echo "Build the app first: scripts/build_app.sh" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="build/RelayVSR-$VERSION.dmg"

# Staged outside iCloud Drive, without extended attributes, so the copy inside the image
# keeps a valid signature and carries nothing from this Mac.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/RelayVSR"
ditto --noextattr --norsrc "$APP" "$WORK/RelayVSR/RelayVSR.app"
codesign --verify --deep --strict "$WORK/RelayVSR/RelayVSR.app"
ln -s /Applications "$WORK/RelayVSR/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "RelayVSR $VERSION" -srcfolder "$WORK/RelayVSR" \
    -fs APFS -format ULFO -ov "$WORK/RelayVSR.dmg"
mv "$WORK/RelayVSR.dmg" "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
