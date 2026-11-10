#!/bin/bash
# Builds RelayVSR.app into ./build, with the ComfyUI engine bundled inside it.
#
# Signing:
#   default                       ad-hoc signature (runs on this Mac; other Macs will block it)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#                                 signs every binary with the hardened runtime, for distribution
#   NOTARY_PROFILE=<profile>      also notarizes and staples the app; create the profile once with
#                                 xcrun notarytool store-credentials <profile>
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
STAGE="build/engine-stage"

# Stages the engine once (Python, PyTorch, ComfyUI, int8-Fast). Skipped when already staged.
./scripts/build_engine.sh

# Refuse to bundle an engine that is incomplete, or that carries a copied virtualenv.
for required in "$STAGE/python/bin/python3" "$STAGE/ComfyUI/main.py" \
                "$STAGE/ComfyUI/custom_nodes/ComfyUI-AppleSilicon-int8-Fast/__init__.py"; do
    [ -e "$required" ] || { echo "Engine is incomplete, missing: $required" >&2; exit 1; }
done
# An engine staged by an older version of this script may still carry the decoder attention
# patch it used to add; with PyTorch 2.14 that patch only slows the engine down.
rm -rf "$STAGE/ComfyUI/custom_nodes/relayvsr_mps_attention"
# Never bundle an engine that still names this Mac's folders.
./scripts/scrub_engine.sh
if [ -e "$STAGE/ComfyUI/.venv" ]; then
    echo "The staged engine contains ComfyUI/.venv, which the app does not use. Delete $STAGE and rebuild." >&2
    exit 1
fi

swift build -c release

FINAL="build/RelayVSR.app"
# The app is assembled and signed outside iCloud Drive: iCloud keeps Finder attributes on a
# bundle folder, and codesign refuses to sign a bundle that has them. The signed app is then
# copied into ./build.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/RelayVSR.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/RelayVSR" "$APP/Contents/MacOS/RelayVSR"
# Release builds keep debug-map entries that name this Mac's build folder; drop them.
strip -S -x "$APP/Contents/MacOS/RelayVSR"
# The linker also adds search paths into the build Mac's Swift toolchains (which can sit in the
# home folder). The app uses the Swift runtime built into macOS, so keep only /usr/lib ones.
otool -l "$APP/Contents/MacOS/RelayVSR" | awk '/cmd LC_RPATH/ {getline; getline; print $2}' |
while IFS= read -r rpath; do
    case "$rpath" in /usr/lib/*) ;; *) install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/RelayVSR" ;; esac
done
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ditto keeps the symlinks inside the bundled Python intact.
ditto --noextattr --norsrc "$STAGE" "$APP/Contents/Resources/Engine"
# The app's own engine add-ons (see each one's __init__.py), loaded by ComfyUI as custom nodes.
for addon in EngineAddons/*/; do
    ditto --noextattr --norsrc "$addon" "$APP/Contents/Resources/Engine/ComfyUI/custom_nodes/$(basename "$addon")"
done
find "$APP/Contents/Resources/Engine/ComfyUI/custom_nodes" -name "__pycache__" -type d -prune -exec rm -rf {} +
xattr -cr "$APP"

# Nothing in the app may name this Mac's folders (home folder or project location).
leaks="$(grep -rlaF -e "$HOME" -e "$PWD" "$APP" 2>/dev/null || true)"
if [ -n "$leaks" ]; then
    echo "Build-machine paths found in the app:" >&2
    echo "$leaks" >&2
    exit 1
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> Signing ad-hoc"
    codesign --force --deep --sign - "$APP"
else
    echo "==> Signing with $SIGN_IDENTITY (hardened runtime)"
    ENT="Resources/engine.entitlements"
    # Inner binaries first: every Mach-O file in the engine (dylibs, .so modules, executables).
    find "$APP/Contents/Resources/Engine" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q "Mach-O"; then
            codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$SIGN_IDENTITY" "$file"
        fi
    done
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    [ "$SIGN_IDENTITY" != "-" ] || { echo "Notarization needs SIGN_IDENTITY (a Developer ID)." >&2; exit 1; }
    echo "==> Notarizing"
    ZIP="$WORK/RelayVSR-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "Signature verified."

rm -rf "$FINAL" "build/RelayVSR.zip"
mkdir -p build
ditto "$APP" "$FINAL"
# For sharing: a zip of the clean signed app. iCloud Drive re-adds Finder attributes to the
# copy in ./build, which then fails `codesign --strict` (it still runs on this Mac).
ditto -c -k --norsrc --noextattr --keepParent "$APP" "build/RelayVSR.zip"
codesign --verify --deep "$FINAL"
echo "Built $FINAL and build/RelayVSR.zip"
