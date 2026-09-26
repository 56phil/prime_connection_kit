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

echo "Staging…"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

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
