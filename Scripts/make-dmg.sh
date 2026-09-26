#!/bin/zsh
# Packages PrimeConnectionKit.app into a distributable disk image.
#
# The image holds the application and a symlink to /Applications, which is the
# layout people expect: drag the app across to install it. The disk image itself is
# compressed (UDZO), so it downloads smaller than the app bundle it contains.
#
# ## Signing
#
# The app is signed before packaging, by `build-app.sh`, with whatever identity is
# available. A Developer ID certificate is what makes a download open without a
# warning, and it is not present here, so a downloaded copy is quarantined by
# Gatekeeper and has to be opened deliberately. The script reports which case
# applies rather than leaving the user to discover it.
#
# An app signed with a development certificate is re-signed ad-hoc before it is
# packaged, because that certificate carries an issuing team's identifier and a
# development certificate is not distributable anyway. Packaging is refused outright
# if a team identifier survives that, unless `ALLOWED_TEAM_ID` says it is expected —
# a team identifier on a published build cannot be taken back afterwards.
#
# Usage: Scripts/make-dmg.sh [output-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/build}"
APP_NAME="PrimeConnectionKit"
VOLUME_NAME="Prime Connection Kit"

source "$ROOT/Scripts/version.sh"

APP="$OUTPUT_DIR/$APP_NAME.app"
DMG="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"

echo "Building the app…"
"$ROOT/Scripts/build-app.sh" "$OUTPUT_DIR"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP was not produced" >&2
  exit 1
fi

# Build the image's contents in a staging directory. hdiutil copies it in, so the
# staging copy can be discarded afterwards.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Report what the signature will mean to whoever downloads this.
SIGNATURE="$(codesign -dv -v "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ "$SIGNATURE" == Developer\ ID* ]]; then
  echo "  signed with a Developer ID — notarization is possible for this build"
  SIGNING_NOTE="Developer ID"
elif [[ -n "$SIGNATURE" ]]; then
  echo "  signed with: $SIGNATURE"
  echo "  note: not a Developer ID, so macOS will quarantine a downloaded copy"
  SIGNING_NOTE="development"
else
  echo "  signed ad-hoc"
  SIGNING_NOTE="adhoc"
fi

# Never package an app signed with a team that is not ours. A development machine
# frequently carries a certificate issued to an employer, and publishing a release
# with it would put their team identifier on this project's downloads, naming them
# as the team of record for software they have nothing to do with. A development
# certificate cannot be notarized in any case, so nothing is lost by replacing it
# with an ad-hoc signature, which carries no team at all.
if [[ "$SIGNATURE" != Developer\ ID* ]]; then
  INHERITED_TEAM="$(codesign -dv -v "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [[ -n "$INHERITED_TEAM" && "$INHERITED_TEAM" != "not set" ]]; then
    echo "Re-signing ad-hoc…"
    echo "  the app carries team $INHERITED_TEAM from the certificate that signed it"
    echo "  a development certificate is not distributable, and that team identifier"
    echo "  does not belong on a published build"
    # Mirrors the ad-hoc path in build-app.sh rather than inventing a second one.
    codesign --force --sign - --identifier com.primeconnectionkit.app "$APP"
    SIGNATURE=""
    SIGNING_NOTE="adhoc"
  fi
fi

# Assert the property that was just established, rather than trusting the logic
# above: a team identifier in a download is the one thing here that cannot be
# undone after the fact.
FINAL_TEAM="$(codesign -dv -v "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ -n "$FINAL_TEAM" && "$FINAL_TEAM" != "not set" ]]; then
  EXPECTED_TEAM="${ALLOWED_TEAM_ID:-}"
  if [[ -z "$EXPECTED_TEAM" ]]; then
    echo "error: this app is signed with team $FINAL_TEAM, and packaging it would" >&2
    echo "       publish that team identifier as the team of record." >&2
    echo "       If $FINAL_TEAM is your own team, re-run as:" >&2
    echo "         ALLOWED_TEAM_ID=$FINAL_TEAM $0 $OUTPUT_DIR" >&2
    echo "       If it belongs to someone else, sign with your own identity or" >&2
    echo "       ad-hoc (SIGN_IDENTITY=-)." >&2
    exit 1
  fi
  if [[ "$FINAL_TEAM" != "$EXPECTED_TEAM" ]]; then
    echo "error: the app is signed with team $FINAL_TEAM, but ALLOWED_TEAM_ID is" >&2
    echo "       $EXPECTED_TEAM. Refusing to package it." >&2
    exit 1
  fi
  echo "  team identifier: $FINAL_TEAM (matches ALLOWED_TEAM_ID)"
else
  echo "  team identifier: none"
fi

echo "Staging…"
# Deliberately after the signing decisions above: the image is built from this
# copy, so a signature applied afterwards would never reach the download. That is
# how a development certificate's team identifier got into a built image once.
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

echo "Creating the disk image…"
rm -f "$DMG"
# UDZO is a compressed read-only image: the standard shape for distribution, and
# it mounts read-only so nothing in it can be altered in place.
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  -quiet \
  "$DMG"

# Sign the image itself, not only the app inside it. Gatekeeper assesses a disk
# image as a whole when it is opened, and notarization cannot be stapled to an
# unsigned one — `spctl -t open` reports "no usable signature" for it. Only a
# Developer ID is worth doing this with; ad-hoc signing an image achieves nothing.
DMG_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$DMG_IDENTITY" ]]; then
  DMG_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [[ -n "$DMG_IDENTITY" ]]; then
  echo "Signing the disk image…"
  echo "  identity: $DMG_IDENTITY"
  # A timestamp is required: without one the signature stops validating when the
  # certificate expires, which would invalidate the notarization with it.
  # An explicit identifier, rather than the filename-derived one, so the
  # signature is stable if the image is ever renamed.
  codesign --force --sign "$DMG_IDENTITY" --timestamp \
    --identifier com.primeconnectionkit.dmg "$DMG"
  codesign --verify --strict "$DMG"
else
  echo "Not signing the disk image: no Developer ID is installed."
fi

# Verify the image by mounting it and looking at what is actually inside, rather
# than trusting the file that was written.
echo "Verifying…"
MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
trap 'hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; rm -rf "$MOUNT_POINT" "$STAGING"' EXIT

if [[ ! -d "$MOUNT_POINT/$APP_NAME.app" ]]; then
  echo "error: the app is not in the mounted image" >&2
  exit 1
fi
if [[ ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "error: the Applications shortcut is missing from the mounted image" >&2
  exit 1
fi

MOUNTED_BINARY="$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/$APP_NAME"
codesign --verify --strict "$MOUNT_POINT/$APP_NAME.app" || {
  echo "error: the app inside the image failed signature verification" >&2
  exit 1
}

VERSION_IN_IMAGE="$(defaults read "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist" CFBundleShortVersionString)"
echo "  mounted image holds $APP_NAME $VERSION_IN_IMAGE"
echo "  executable is present and the signature verifies"

# Check the team identifier on what is actually inside the image, not on the build
# directory. Those are different artifacts, and asserting on the wrong one reports
# success while shipping a signature that was replaced — which is precisely what the
# ordering in this script once did.
SHIPPED_TEAM="$(codesign -dv -v "$MOUNT_POINT/$APP_NAME.app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ -n "$SHIPPED_TEAM" && "$SHIPPED_TEAM" != "not set" ]]; then
  if [[ "$SHIPPED_TEAM" != "${ALLOWED_TEAM_ID:-}" ]]; then
    echo "error: the app inside the image is signed with team $SHIPPED_TEAM, which" >&2
    echo "       is not the team this build was permitted to use. Refusing to" >&2
    echo "       publish it." >&2
    exit 1
  fi
  echo "  team identifier in the image: $SHIPPED_TEAM"
else
  echo "  team identifier in the image: none"
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "Built $DMG ($SIZE)"

# A checksum lets a downloader confirm the file arrived intact. The file is in the
# standard `shasum -c` format, `hash  filename`, so verification is one command
# rather than a manual comparison — a bare hash would not be checkable that way.
echo "Verifying the checksum file…"
(
  cd "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
  shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null
)
echo "SHA-256: $(awk '{print $1}' "$DMG.sha256")  ($(basename "$DMG").sha256)"

case "$SIGNING_NOTE" in
  "Developer ID")
    echo
    echo "This build can be notarized, which makes it open without any warning:"
    echo "  Scripts/notarize.sh \"$DMG\" <notarytool-profile>"
    ;;
  *)
    echo
    echo "This build is not signed with a Developer ID, so macOS will block a"
    echo "downloaded copy: the app is quarantined and the system kills it on launch."
    echo
    echo "Whoever downloads it has one of two ways past that, both verified on this"
    echo "machine. The first is one command:"
    echo
    echo "  xattr -d com.apple.quarantine \"/Applications/$APP_NAME.app\""
    echo
    echo "The second is to launch it once, be refused, then allow it in"
    echo "System Settings → Privacy & Security → \"Open Anyway\"."
    echo
    echo "Note that right-clicking and choosing Open does NOT bypass this on current"
    echo "macOS versions; that route was removed for apps that are not notarized."
    echo "This is a limitation of the signing certificate, not of the app."
    ;;
esac
