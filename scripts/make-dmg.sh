#!/bin/zsh
# Builds a drag-to-install DMG for Kekkai: a raked-gravel garden as background (scripts/make-art.swift),
# the app icon as volume icon, Kekkai left, Applications right, joined by the cord. LZMA-compressed.
# No Finder scripting: dmgbuild writes the window layout itself, so it also works unattended.
#
#   scripts/make-dmg.sh                          the Release build from scripts/install.sh -> build/dmg/Kekkai-<version>.dmg
#   scripts/make-dmg.sh <Kekkai.app> <out.dmg>   used by release.sh
#
# First run sets up dmgbuild in build/dmg-tools (a private Python environment).

set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:-build/InstallData/Build/Products/Release/Kekkai.app}
[[ -d $APP ]] || { echo "No app at $APP. Build first (scripts/install.sh)."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT=${2:-build/dmg/Kekkai-$VERSION.dmg}
TOOLS=build/dmg-tools
WORK=$(mktemp -d -t kekkai-dmg)
trap 'rm -rf "$WORK"' EXIT

if [[ ! -x $TOOLS/bin/dmgbuild ]]; then
  echo "Setting up dmgbuild in $TOOLS…"
  python3 -m venv "$TOOLS"
  "$TOOLS/bin/pip" install --quiet --upgrade pip dmgbuild
fi

swift scripts/make-art.swift dmg "$WORK/art" >/dev/null
tiffutil -cathidpicheck "$WORK/art/background.png" "$WORK/art/background@2x.png" -out "$WORK/art/background.tiff" 2>/dev/null
mkdir -p "$WORK/Kekkai.iconset"
cp App/Assets.xcassets/AppIcon.appiconset/icon_*.png "$WORK/Kekkai.iconset/"
iconutil -c icns "$WORK/Kekkai.iconset" -o "$WORK/art/VolumeIcon.icns"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$TOOLS/bin/dmgbuild" -s scripts/dmg/settings.py \
  -D app="$APP" -D icon="$WORK/art/VolumeIcon.icns" -D background="$WORK/art/background.tiff" \
  "Kekkai" "$OUT" 2> >(grep -v "is deprecated" >&2) >/dev/null
hdiutil verify -quiet "$OUT"
echo "DMG: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
