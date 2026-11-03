#!/usr/bin/env bash
# Builds Clearspace.app (universal: Apple silicon + Intel) and a drag-to-install DMG into dist/.
#
#   scripts/build.sh             # app + dmg
#   scripts/build.sh --app-only  # just dist/Clearspace.app
#   ARCHS=arm64 scripts/build.sh # single architecture (faster)
#
# Needs only the Xcode Command Line Tools. The styled DMG window uses dmgbuild, installed
# into .build/dmgbuild-venv on first run; without network it falls back to a plain DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Clearspace"
MIN_MACOS="14.0"
ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
DIST="dist"
WORK=".build/package"
APP="$DIST/$APP_NAME.app"

APP_ONLY=0
if [[ "${1:-}" == "--app-only" ]]; then APP_ONLY=1; fi

rm -rf "$WORK" "$APP"
mkdir -p "$WORK" "$DIST"

echo "==> Compiling $APP_NAME $VERSION ($ARCHS)"
BINARIES=()
for arch in $ARCHS; do
  triple="$arch-apple-macosx$MIN_MACOS"
  swift build -c release --triple "$triple" --product "$APP_NAME"
  BINARIES+=("$(swift build -c release --triple "$triple" --show-bin-path)/$APP_NAME")
done

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Rendering icon"
swiftc -O scripts/artwork.swift -o "$WORK/artwork"
"$WORK/artwork" icon "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [[ $APP_ONLY == 1 ]]; then
  echo "Done: $APP"
  exit 0
fi

echo "==> Building DMG"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
"$WORK/artwork" dmg-background "$WORK/background.png" 1
"$WORK/artwork" dmg-background "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

VENV=".build/dmgbuild-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV" >/dev/null 2>&1 && "$VENV/bin/pip" install --quiet --disable-pip-version-check dmgbuild || true
fi
if [[ -x "$VENV/bin/dmgbuild" ]]; then
  "$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" -D background="$WORK/background.tiff" "$APP_NAME" "$DMG"
else
  echo "    dmgbuild unavailable, building a plain DMG"
  STAGE="$WORK/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

echo "Done: $DMG"
