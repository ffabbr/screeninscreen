#!/bin/bash
# Builds ScreenInScreen.app (Release) and a styled DMG installer.
# Usage: packaging/package.sh [version]
set -euo pipefail

VERSION="${1:-0.0.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ScreenInScreen"
VOL="$APP_NAME Installer"          # must match packaging/dmg_DS_Store!
DD="$ROOT/build/dd"
BIN="$DD/Build/Products/Release"
APP="$BIN/$APP_NAME.app"

echo "==> Building $APP_NAME $VERSION"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" build >/dev/null

# Ad-hoc sign so Gatekeeper offers "Open Anyway" rather than "app is damaged".
# Entitlements matter here: the app needs Screen Recording.
# The explicit identifier-based designated requirement keeps TCC grants
# (Screen Recording, Accessibility) valid across rebuilds — the default
# ad-hoc requirement is cdhash-based and breaks them on every build.
# Must match PRODUCT_BUNDLE_IDENTIFIER in the Xcode project.
echo "==> Ad-hoc code-signing"
codesign --force --deep --timestamp=none \
  --entitlements "$ROOT/$APP_NAME.entitlements" \
  -r='designated => identifier "app.screeninscreen.ScreenInScreen"' \
  --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2

echo "==> Building DMG"
WORK="$BIN/dmg-stage"; DMG_TMP="$BIN/rw.dmg"; DMG_OUT="$BIN/$APP_NAME-$VERSION.dmg"
MNT="/Volumes/$VOL"
diskutil unmount force "$MNT" >/dev/null 2>&1 || true
rm -rf "$WORK" "$DMG_TMP" "$DMG_OUT"; mkdir -p "$WORK"
cp -R "$APP" "$WORK/$APP_NAME.app"
ln -s /Applications "$WORK/Applications"

hdiutil create -srcfolder "$WORK" -volname "$VOL" -fs HFS+ -format UDRW -ov "$DMG_TMP" >/dev/null
hdiutil attach "$DMG_TMP" -nobrowse -mountpoint "$MNT" >/dev/null

DS_CACHE="$ROOT/packaging/dmg_DS_Store"
if [ -f "$DS_CACHE" ]; then
  cp "$DS_CACHE" "$MNT/.DS_Store"; sync
else
  echo "==> No cached DS_Store; styling via Finder (needs automation permission)"
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 100, 1120, 460}
    set vo to icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 144
    set position of item "$APP_NAME.app" of container window to {145, 185}
    set position of item "Applications" of container window to {575, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  sync
  cp "$MNT/.DS_Store" "$DS_CACHE" 2>/dev/null || true
fi

for _ in $(seq 1 12); do
  hdiutil detach "$MNT" -force >/dev/null 2>&1 && break
  sleep 2
done

hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_OUT" >/dev/null
rm -f "$DMG_TMP"; rm -rf "$WORK"

echo "==> Done: $DMG_OUT"
hdiutil verify "$DMG_OUT" 2>&1 | tail -1
