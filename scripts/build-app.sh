#!/bin/bash
# Builds build/Zamazka.app for Apple silicon and Intel and signs it ad hoc
# (no paid Apple certificate; without any signature Apple silicon refuses to run it).
#   scripts/build-app.sh            the app only
#   scripts/build-app.sh --dmg      plus dist/Zamazka-<version>-macOS.dmg and its SHA-256
#   scripts/build-app.sh --install  plus a copy in /Applications
#   scripts/build-app.sh --native   this Mac's architecture only, for a quick local build
set -euo pipefail
cd "$(dirname "$0")/.."

DMG=0; INSTALL=0; ARCHS="arm64 x86_64"
for arg in "$@"; do
    case "$arg" in
        --dmg) DMG=1 ;;
        --install) INSTALL=1 ;;
        --native) ARCHS="$(uname -m)" ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

APP=build/Zamazka.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ ! -f Resources/AppIcon.icns ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    swift scripts/make-icon.swift Resources/AppIcon.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

BINARIES=()
for arch in $ARCHS; do
    swift build -c release --product Zamazka --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch" >/dev/null
    BINARIES+=(".build/$arch/release/Zamazka")
done
lipo -create -output "$APP/Contents/MacOS/Zamazka" "${BINARIES[@]}"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Zamazka"))"

if [[ $DMG == 1 ]]; then
    mkdir -p dist
    IMAGE="dist/Zamazka-$VERSION-macOS.dmg"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Программы"
    rm -f "$IMAGE"
    hdiutil create -volname "Замазка" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$IMAGE" >/dev/null
    (cd dist && shasum -a 256 "$(basename "$IMAGE")" > "$(basename "$IMAGE").sha256")
    echo "Built $IMAGE"
    cat "$IMAGE.sha256"
fi

if [[ $INSTALL == 1 ]]; then
    pkill -x Zamazka 2>/dev/null || true
    rm -rf /Applications/Zamazka.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Zamazka.app"
fi
