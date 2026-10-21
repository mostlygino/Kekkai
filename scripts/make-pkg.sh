#!/bin/zsh
# Builds a guided installer for Kekkai (Kekkai-<version>.pkg): welcome, licence, install into /Applications,
# a closing page with first steps, and the raked-gravel side panel from scripts/make-art.swift (light and dark).
#
#   scripts/make-pkg.sh                          the Release build from scripts/install.sh -> build/pkg/Kekkai-<version>.pkg
#   scripts/make-pkg.sh <Kekkai.app> <out.pkg>   used by release.sh
#
# Unsigned unless KEKKAI_INSTALLER_ID names a "Developer ID Installer" identity in the keychain.

set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:-build/InstallData/Build/Products/Release/Kekkai.app}
[[ -d $APP ]] || { echo "No app at $APP. Build first (scripts/install.sh)."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT=${2:-build/pkg/Kekkai-$VERSION.pkg}
WORK=$(mktemp -d -t kekkai-pkg)
trap 'rm -rf "$WORK"' EXIT

# Payload: the app at /Applications/Kekkai.app. Not relocatable, so Installer never "updates" a stray copy
# of Kekkai somewhere else on the disk instead of installing into Applications.
mkdir -p "$WORK/root/Applications"
ditto "$APP" "$WORK/root/Applications/Kekkai.app"
# Strip extended attributes (provenance, quarantine): pkgbuild can't carry them and complains for each one.
xattr -cr "$WORK/root/Applications/Kekkai.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/components.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --install-location / \
  --identifier com.mostlygino.Kekkai --version "$VERSION" "$WORK/Kekkai-component.pkg" \
  2> >(grep -v '^write: Permission denied' >&2) >/dev/null   # pkgbuild noise on macOS 27; the package is complete

# Resources: pages, licence and artwork.
mkdir -p "$WORK/res"
cp scripts/pkg/welcome.html scripts/pkg/conclusion.html "$WORK/res/"
# The licence page: a plain summary first, then the full AGPL text.
{
  echo "Kekkai is free software under the GNU Affero General Public License, version 3 or (at your option)"
  echo "any later version (AGPL-3.0-or-later). It comes with no warranty; the full licence follows."
  echo
  echo "The Kekkai name, icon and artwork are not covered by this licence (see BRAND.md in the source)."
  echo
  cat LICENSE
} > "$WORK/res/license.txt"
swift scripts/make-art.swift pkg "$WORK/art" >/dev/null
tiffutil -cathidpicheck "$WORK/art/installer.png" "$WORK/art/installer@2x.png" -out "$WORK/res/installer.tiff" 2>/dev/null
tiffutil -cathidpicheck "$WORK/art/installer-dark.png" "$WORK/art/installer-dark@2x.png" -out "$WORK/res/installer-dark.tiff" 2>/dev/null
sed "s/__VERSION__/$VERSION/" scripts/pkg/distribution.xml > "$WORK/distribution.xml"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
SIGN=()
[[ -n ${KEKKAI_INSTALLER_ID:-} ]] && SIGN=(--sign "$KEKKAI_INSTALLER_ID")
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/res" --package-path "$WORK" "${SIGN[@]}" "$OUT" >/dev/null
pkgutil --check-signature "$OUT" >/dev/null 2>&1 || true
echo "PKG: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
