#!/bin/zsh
# Cuts a Kekkai release on GitHub. Installed copies pick it up through
# Kekkai > Check for Updates (and a daily check). Needs a clean tree on main, gh logged in,
# the release key (also pinned in App/Updater.swift) and scripts/fetch-geoip.sh run once.
#
#   scripts/release.sh 0.3.0          bumps the version, builds, signs, commits, pushes, releases
#   scripts/release.sh 0.3.0 --beta   the same, published as a GitHub pre-release labelled Beta
#
# Signing: with KEKKAI_TEAM=<team id> the build is signed by that team and carries the Network
# Extension entitlements, so the filter can load. Without it the build is ad-hoc signed and the
# restricted entitlements are left out (macOS refuses to launch an ad-hoc app that claims them):
# the app, demo mode and updates work, the filter does not.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [--beta], for example 0.3.0}
BETA=${2:-}
[[ -z $BETA || $BETA == --beta ]] || { echo "The second argument can only be --beta."; exit 1; }
KEY=4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08
REPO=mostlygino/Kekkai
OUT=build/release
BUILT=build/ReleaseData/Build/Products/Release/Kekkai.app
ZIP="$OUT/Kekkai-$VERSION.zip"
DMG="$OUT/Kekkai-$VERSION.dmg"
PKG="$OUT/Kekkai-$VERSION.pkg"
TEAM=${KEKKAI_TEAM:-}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Releases come from main."; exit 1; }
[[ -f App/Resources/geoip.bin ]] || { echo "Run scripts/fetch-geoip.sh first, or the release ships without country data."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION already exists."; exit 1; fi
scripts/check.sh

# Until the release commit exists, any failure puts project.yml back.
trap '[[ -n ${COMMITTED:-} ]] || git checkout -- project.yml' EXIT
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
xcodegen generate >/dev/null

if [[ -n $TEAM ]]; then
  SIGNING=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic)
  KIND="signed by team $TEAM"
else
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER=)
  KIND="ad-hoc, filter disabled"
fi
LOG=$(mktemp -t kekkai-release)
if ! xcodebuild -project Kekkai.xcodeproj -scheme Kekkai -configuration Release -derivedDataPath build/ReleaseData build \
     CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M%S)" KEKKAI_CHANNEL="$([[ -n $BETA ]] && echo Beta || echo Release)" \
     KEKKAI_COMMIT="$(git rev-parse --short=7 HEAD)$([[ -z $(git status --porcelain) ]] || echo -dirty)" KEKKAI_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SIGNING[@]}" >"$LOG" 2>&1; then
  grep -E ': error:' "$LOG" | sort -u
  echo "Build failed, nothing released. Log: $LOG"
  exit 1
fi
rm -f "$LOG"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
[[ $BUILT_VERSION == "$VERSION" ]] || { echo "Built version is $BUILT_VERSION, not $VERSION."; exit 1; }
codesign --verify --deep --strict "$BUILT"

rm -rf "$OUT" && mkdir -p "$OUT"
# Three ways in: the DMG and the installer for people, the zip for the updater. All signed with the release key.
ditto -c -k --keepParent "$BUILT" "$ZIP"
scripts/make-dmg.sh "$BUILT" "$DMG"
scripts/make-pkg.sh "$BUILT" "$PKG"
for f in "$ZIP" "$DMG" "$PKG"; do
  gpg --local-user "$KEY" --detach-sign --output "$f.sig" "$f"
  gpg --verify "$f.sig" "$f" 2>/dev/null
done

git diff --quiet project.yml || git commit -qm "chore: release v$VERSION" project.yml
COMMITTED=1
git tag -a "v$VERSION" -m "Kekkai $VERSION${BETA:+ Beta}"
git push origin main "v$VERSION"
NOTES="**Install:** open \`Kekkai-$VERSION.dmg\` and drag Kekkai into Applications, or run the guided installer \`Kekkai-$VERSION.pkg\`. Installed copies update themselves (Kekkai > Check for Updates), using the zip.

**Build:** $KIND. Needs macOS 26 or later.

**First open:** the build isn't notarised yet, so macOS may say it can't check it. Right-click Kekkai in Applications and choose Open, once.

**Verify:** every file has a .sig made with the Kekkai release key, e.g. \`gpg --verify Kekkai-$VERSION.dmg.sig\`."
if [[ -n $BETA ]]; then
  gh release create "v$VERSION" --repo "$REPO" --prerelease --title "Kekkai $VERSION Beta" --notes "$NOTES" \
    "$DMG" "$DMG.sig" "$PKG" "$PKG.sig" "$ZIP" "$ZIP.sig"
else
  gh release create "v$VERSION" --repo "$REPO" --title "Kekkai $VERSION" --notes "$NOTES" \
    "$DMG" "$DMG.sig" "$PKG" "$PKG.sig" "$ZIP" "$ZIP.sig"
fi
echo "Released Kekkai $VERSION ($KIND)."
