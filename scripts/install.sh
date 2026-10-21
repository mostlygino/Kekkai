#!/bin/zsh
# Builds Kekkai and installs it in /Applications, replacing (and trashing) the copy that is there.
#
#   scripts/install.sh                 ad-hoc build: app, demo mode and updates work, the filter can't load
#   KEKKAI_TEAM=ABCDE12345 scripts/install.sh
#                                      signed by your Apple Developer team, with the Network Extension
#                                      entitlements, so Raise Barrier can install and run the filter
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TEAM=${KEKKAI_TEAM:-}
BUILT=build/InstallData/Build/Products/Release/Kekkai.app
TARGET=/Applications/Kekkai.app

[[ -f App/Resources/geoip.bin ]] || scripts/fetch-geoip.sh
xcodegen generate >/dev/null
if [[ -n $TEAM ]]; then
  SIGNING=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
else
  # macOS won't launch an ad-hoc app that claims Network Extension entitlements, so leave them out.
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER=)
fi
LOG=$(mktemp -t kekkai-install)
if ! xcodebuild -project Kekkai.xcodeproj -scheme Kekkai -configuration Release -derivedDataPath build/InstallData build \
     KEKKAI_COMMIT="$(git rev-parse --short=7 HEAD)$([[ -z $(git status --porcelain) ]] || echo -dirty)" KEKKAI_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SIGNING[@]}" >"$LOG" 2>&1; then
  grep -E ': error:|error: ' "$LOG" | sort -u | head -20
  echo "Build failed. Full log: $LOG"
  exit 1
fi
rm -f "$LOG"
codesign --verify --deep --strict "$BUILT"

if [[ -e $TARGET ]]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$TARGET\"" >/dev/null
fi
ditto "$BUILT" "$TARGET"
xattr -cr "$TARGET"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print KekkaiCommit' "$TARGET/Contents/Info.plist"), ${TEAM:+team $TEAM}${TEAM:-ad-hoc}) in $TARGET"
