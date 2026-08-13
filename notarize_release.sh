#!/bin/zsh
# Build, sign, notarize, staple, and verify a distributable FanControl DMG.
# Credentials are read from the user's keychain profile; no secret belongs in
# this repository or in a shell script.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
IDENTITY="${SIGNING_IDENTITY:-}"
PROFILE="${NOTARYTOOL_PROFILE:-fancontrol-notary}"

if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  print -u2 "Set SIGNING_IDENTITY to the full Developer ID Application identity."
  print -u2 "Example: SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' zsh notarize_release.sh"
  exit 2
fi

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "$IDENTITY"; then
  print -u2 "No matching Developer ID Application identity was found: $IDENTITY"
  exit 1
fi

if ! /usr/bin/xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  print -u2 "The notarytool keychain profile '$PROFILE' is not available."
  print -u2 "Create it once with:"
  print -u2 "  xcrun notarytool store-credentials '$PROFILE' --apple-id '<Apple ID>' --team-id '<Team ID>' --password '<app-specific password>'"
  exit 1
fi

SIGNING_IDENTITY="$IDENTITY" /bin/zsh "$SRC/build_app.sh"

APP="$SRC/FanControl.app"
DMG="$SRC/FanControl.dmg"
WORK="$(/usr/bin/mktemp -d /private/tmp/fancontrol-notarize.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

print "==> Verify signed app before upload"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign -dvvv "$APP" 2>&1 | /usr/bin/grep -E 'Identifier=|Authority=|TeamIdentifier=|Runtime Version=' || true

print "==> Create DMG"
/usr/bin/hdiutil create -volname FanControl -srcfolder "$APP" \
  -ov -format UDZO "$DMG" >/dev/null

print "==> Submit DMG to Apple notary service"
/usr/bin/xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" --wait --output-format json \
  | /usr/bin/tee "$WORK/notary-result.json"

print "==> Staple and validate the ticket"
/usr/bin/xcrun stapler staple "$DMG"
/usr/bin/xcrun stapler validate "$DMG"
/usr/bin/spctl --assess --type open --context context:primary-signature \
  --verbose=4 "$DMG"

print "==> Done: $DMG"
print "Upload this DMG as a GitHub Release asset only after testing it on a clean Mac."

