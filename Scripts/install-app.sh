#!/bin/zsh
# Installs PrimeConnectionKit.app into /Applications.
#
# Unlike HP's Connectivity Kit, this app needs no kernel extension and no driver
# installation: it talks to the calculator through IOKit HID, which macOS provides.
# Installing is therefore just copying the bundle and confirming its signature.
#
# Usage: Scripts/install-app.sh [destination-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/PrimeConnectionKit.app"

if [[ ! -d "$DEST_DIR" ]]; then
  echo "error: $DEST_DIR does not exist" >&2
  exit 1
fi
if [[ ! -w "$DEST_DIR" ]]; then
  echo "error: $DEST_DIR is not writable by $(whoami)" >&2
  exit 1
fi

echo "Building…"
"$ROOT/Scripts/build-app.sh" "$ROOT/build"

# Refuse to replace an app that is currently running: overwriting a live bundle
# leaves the running process reading files that no longer exist.
if pgrep -f "PrimeConnectionKit.app/Contents/MacOS/PrimeConnectionKit" >/dev/null 2>&1; then
  echo "error: Prime Connection Kit is running — quit it and try again" >&2
  exit 1
fi

echo
echo "Installing to $DEST…"
rm -rf "$DEST"
ditto "$ROOT/build/PrimeConnectionKit.app" "$DEST"

# Verify what was actually installed rather than what was built. A signature that
# does not validate makes macOS ask for Input Monitoring permission on every launch.
echo
echo "Verifying the installed bundle…"
codesign --verify --deep --strict "$DEST" 2>&1 || {
  echo "error: the installed app failed signature verification" >&2
  exit 1
}

# `codesign -dv` only prints Authority lines at -v or above; without the flag the
# output looks ad-hoc even when a real identity signed it.
SIGNATURE="$(codesign -dv -v "$DEST" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -n "$SIGNATURE" ]]; then
  echo "  signed by: $SIGNATURE"
else
  echo "  signed ad-hoc (macOS will re-ask for Input Monitoring after each rebuild)"
fi

BUNDLE_ID="$(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier)"
VERSION="$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString)"
echo "  bundle id: $BUNDLE_ID"
echo "  version:   $VERSION"
echo "  size:      $(du -sh "$DEST" | cut -f1)"

echo
echo "Installed $DEST"
echo
echo "The first launch asks for Input Monitoring permission, which macOS requires"
echo "before any application may open a USB HID device:"
echo
echo "  System Settings → Privacy & Security → Input Monitoring"
echo
echo "Quit and reopen the app after granting it. Until then it reports that the"
echo "calculator could not be opened, rather than failing silently."
echo
echo "Launch it with:  open '$DEST'"
