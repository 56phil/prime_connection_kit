#!/bin/zsh
# Notarizes and staples a disk image, so a downloaded copy opens without a warning.
#
# Notarization is what makes Gatekeeper accept an app that arrived from the
# internet: Apple scans the upload and issues a ticket, which is then stapled to
# the image so the check works offline.
#
# ## This needs a Developer ID
#
# Notarization requires a **Developer ID Application** certificate, which comes
# with a paid Apple Developer account. An "Apple Development" certificate — the
# kind Xcode issues for local work — cannot be notarized. Run
# `security find-identity -v -p codesigning` and look for a `Developer ID
# Application` entry; without one there is nothing this script can do, and a
# downloaded build stays blocked until the user clears its quarantine attribute.
#
# ## One-time setup
#
# Store notarization credentials in the keychain so no password is handled here:
#
#   xcrun notarytool store-credentials "pck-notary" \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# The password is an app-specific password from appleid.apple.com, not the
# account password.
#
# Usage: Scripts/notarize.sh <disk-image.dmg> <keychain-profile>

set -euo pipefail

DMG="${1:-}"
PROFILE="${2:-}"

if [[ -z "$DMG" || -z "$PROFILE" ]]; then
  echo "usage: $0 <disk-image.dmg> <keychain-profile>" >&2
  exit 2
fi
if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG does not exist" >&2
  exit 1
fi

# Refuse early rather than uploading something that cannot be accepted.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no Developer ID Application certificate is installed." >&2
  echo "       Notarization is not possible with a development certificate." >&2
  exit 1
fi

echo "Submitting $DMG for notarization…"
echo "(this waits for Apple's scan; it usually takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "Stapling the ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Confirm what a downloader will actually experience: the Gatekeeper assessment
# should now pass, which it does not for an unstapled image.
echo "Verifying the Gatekeeper assessment…"
if spctl -a -vvv -t open --context context:primary-signature "$DMG"; then
  echo
  echo "Notarized and stapled. A downloaded copy will open without a warning."
else
  echo
  echo "error: Gatekeeper still rejects the image after stapling." >&2
  exit 1
fi
