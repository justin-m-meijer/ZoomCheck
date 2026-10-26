#!/bin/bash
# Signs, notarizes and publishes a draft release that the GitHub workflow created. Runs on the maintainer's
# Mac: the Developer ID certificate stays in the local keychain and the notary credentials in a local
# notarytool profile, so no Apple keys are stored in GitHub.
#
# One-time setup on this Mac:
#   - the "Developer ID Application" certificate in your login keychain (Xcode → Settings → Accounts, or import the .p12)
#   - a notarytool profile:  xcrun notarytool store-credentials zoomcheck-notary
#     (with an App Store Connect API key, or your Apple ID and an app-specific password)
#   - gh logged in with access to this repository
#
# Usage:  scripts/sign-release.sh v1.2.3            sign, notarize and replace the DMG in the draft
#         scripts/sign-release.sh v1.2.3 --publish  ... and publish the release (it is immutable after that)
#
# Overrides: SIGN_IDENTITY="Developer ID Application: …"  NOTARY_PROFILE=other-profile
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/sign-release.sh v1.2.3 [--publish]}"
PUBLISH="${2:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag must look like v1.2.3, got '$TAG'" >&2; exit 1; }
VERSION="${TAG#v}"
PROFILE="${NOTARY_PROFILE:-zoomcheck-notary}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | awk -F'"' '{print $2}')}"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' identity in your keychain (see the setup above)." >&2; exit 1; }

[[ "$(gh release view "$TAG" -R "$REPO" --json isDraft -q .isDraft)" == "true" ]] \
  || { echo "$TAG is not a draft release in $REPO (published releases are immutable)." >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { hdiutil detach -quiet "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "→ Downloading the draft's DMG"
gh release download "$TAG" -R "$REPO" -p "*.dmg" -D "$WORK/in"
IN_DMG="$(ls "$WORK"/in/*.dmg | head -1)"
DMG_NAME="$(basename "$IN_DMG")"

echo "→ Taking the app out of the DMG"
mkdir -p "$WORK/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mnt" "$IN_DMG"
ditto "$WORK/mnt/ZoomCheck.app" "$WORK/ZoomCheck.app"
hdiutil detach -quiet "$WORK/mnt"

echo "→ Signing with: $IDENTITY"
git show "$TAG:Resources/ZoomCheck.entitlements" > "$WORK/ZoomCheck.entitlements" 2>/dev/null \
  || cp Resources/ZoomCheck.entitlements "$WORK/ZoomCheck.entitlements"
codesign --force --options runtime --timestamp --entitlements "$WORK/ZoomCheck.entitlements" \
  --sign "$IDENTITY" "$WORK/ZoomCheck.app"
codesign --verify --strict --verbose=2 "$WORK/ZoomCheck.app"

echo "→ Building the DMG"
mkdir -p "$WORK/stage" "$WORK/out"
ditto "$WORK/ZoomCheck.app" "$WORK/stage/ZoomCheck.app"
ln -s /Applications "$WORK/stage/Applications"
OUT_DMG="$WORK/out/$DMG_NAME"
hdiutil create -quiet -volname ZoomCheck -srcfolder "$WORK/stage" -ov -format UDZO "$OUT_DMG"
codesign --force --timestamp --sign "$IDENTITY" "$OUT_DMG"

echo "→ Notarizing (profile: $PROFILE); this usually takes a few minutes"
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT_DMG"
spctl --assess --type open --context context:primary-signature --verbose "$OUT_DMG"

echo "→ Replacing the DMG in draft $TAG"
gh release upload "$TAG" "$OUT_DMG" -R "$REPO" --clobber
BODY="$(gh release view "$TAG" -R "$REPO" --json body -q .body)"
SIGNED="Signed and notarized by Apple. Open the DMG, drag ZoomCheck to Applications and open it."
NEW_BODY="$(printf '%s' "$BODY" | perl -0pe 's/^⚠️ Not notarized\..*?Open Anyway\*\*\./'"$SIGNED"'/m')"
gh release edit "$TAG" -R "$REPO" --notes "$NEW_BODY" >/dev/null

if [[ "$PUBLISH" == "--publish" ]]; then
  gh release edit "$TAG" -R "$REPO" --draft=false >/dev/null
  echo "✓ $TAG is signed, notarized and published: $(gh release view "$TAG" -R "$REPO" --json url -q .url)"
else
  echo "✓ $TAG is signed and notarized; still a draft. Publish it with: gh release edit $TAG -R $REPO --draft=false"
  echo "  (or click Publish on GitHub)"
fi
