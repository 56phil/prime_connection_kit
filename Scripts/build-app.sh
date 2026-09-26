#!/bin/zsh
# Builds PrimeConnectionKit.app from the SwiftPM executable.
#
# A SwiftPM executable has no Info.plist, so this script assembles a proper
# bundle: it compiles in release configuration, writes the bundle metadata, copies
# the binary in, and ad-hoc signs the result so macOS will launch it locally.
#
# Usage: Scripts/build-app.sh [output-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/version.sh"
OUTPUT_DIR="${1:-$ROOT/build}"
APP="$OUTPUT_DIR/PrimeConnectionKit.app"

echo "Building the release binary…"
cd "$ROOT"

# Apple silicon only. Stated explicitly rather than left to the host, so the
# artifact is the same whichever machine runs the build, and asserted below, so a
# wrong-architecture binary cannot be published as if it matched this intent.
ARCH_FLAGS=(--arch arm64)
swift build -c release --product PrimeConnectionKit "${ARCH_FLAGS[@]}"

BIN="$(swift build -c release --product PrimeConnectionKit "${ARCH_FLAGS[@]}" --show-bin-path)/PrimeConnectionKit"
if [[ ! -x "$BIN" ]]; then
  echo "error: the built binary was not found at $BIN" >&2
  exit 1
fi

# Report what was actually produced, and refuse anything but arm64: a silent
# fall back to another architecture would otherwise only be noticed by whoever
# tried to run it.
ARCHITECTURES="$(lipo -archs "$BIN")"
echo "  architectures: $ARCHITECTURES"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  echo "error: expected an arm64 binary, got '$ARCHITECTURES'" >&2
  exit 1
fi

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/PrimeConnectionKit"

# The icon is generated rather than committed: the app deliberately carries no
# binary assets, and drawing it means every size macOS asks for is rendered
# natively instead of being downsampled from one large bitmap.
echo "Drawing the app icon…"
swift "$ROOT/Scripts/make-icon.swift" --out "$OUTPUT_DIR" >/dev/null
cp "$OUTPUT_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>PrimeConnectionKit</string>
	<key>CFBundleIdentifier</key>
	<string>com.primeconnectionkit.app</string>
	<key>CFBundleName</key>
	<string>Prime Connection Kit</string>
	<key>CFBundleDisplayName</key>
	<string>Prime Connection Kit</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>@@VERSION@@</string>
	<key>CFBundleVersion</key>
	<string>@@BUILD_NUMBER@@</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<!-- Documents the reason the app enumerates HID devices. macOS prompts for
	     Input Monitoring only when a device is actually opened. -->
	<key>NSHumanReadableCopyright</key>
	<string>Prime Connection Kit — a native macOS replacement for HP Connectivity Kit.</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>HP Prime Content</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>public.data</string>
			</array>
			<key>CFBundleTypeExtensions</key>
			<array>
				<string>hpapp</string>
				<string>hpprgm</string>
				<string>hpnote</string>
				<string>hplist</string>
				<string>hpmat</string>
				<string>hpmatrix</string>
				<string>hpexammode</string>
				<string>hpappdir</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# Fill in the version, which comes from Scripts/version.sh.
sed -i '' "s/@@VERSION@@/$VERSION/; s/@@BUILD_NUMBER@@/$BUILD_NUMBER/" "$APP/Contents/Info.plist"
if grep -q "@@" "$APP/Contents/Info.plist"; then
  echo "error: a version placeholder was left unfilled" >&2
  exit 1
fi

echo "Signing…"
# Which identity to sign with, in order of preference:
#
# 1. A Developer ID. This is what makes a *downloaded* copy open without a warning,
#    and it is the only kind of certificate that can be notarized. It is therefore
#    preferred over a development certificate when both are installed, because a
#    build intended for release should be the most widely usable one.
# 2. An Apple Development certificate. This keeps the Input Monitoring grant stable
#    across rebuilds — macOS keys that grant to the code signature, and an ad-hoc
#    signature changes on every build, so each rebuild asks for permission again.
# 3. Ad-hoc, which costs the user a Gatekeeper step but needs no certificate.
#
# `SIGN_IDENTITY` overrides the search, which is how CI passes one in.
IDENTITY="${SIGN_IDENTITY:-}"
IS_DEVELOPER_ID=false
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
  if [[ -n "$IDENTITY" ]]; then
    IS_DEVELOPER_ID=true
  else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
  fi
fi
if [[ "$IDENTITY" == Developer\ ID* ]]; then IS_DEVELOPER_ID=true; fi

if [[ -n "$IDENTITY" ]]; then
  echo "  identity: $IDENTITY"
  # A Developer ID signature is timestamped, because notarization rejects an
  # untimestamped one: without a timestamp the signature stops validating when the
  # certificate expires, which would invalidate the notarization with it.
  # Development certificates do not need one, and asking for it makes an offline
  # build fail for no benefit.
  TIMESTAMP_ARGS=(--timestamp=none)
  if [[ "$IS_DEVELOPER_ID" == true ]]; then
    TIMESTAMP_ARGS=(--timestamp)
  fi
  if codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP_ARGS[@]}" \
       --identifier com.primeconnectionkit.app "$APP"; then
    if [[ "$IS_DEVELOPER_ID" == true ]]; then
      echo "  signed with a Developer ID; ready for notarization"
    fi
  else
    echo "warning: signing with '$IDENTITY' failed; falling back to ad-hoc" >&2
    codesign --force --sign - --identifier com.primeconnectionkit.app "$APP"
  fi
else
  echo "  no signing identity found; using ad-hoc"
  echo "  (an ad-hoc signature changes on every build, so macOS will ask for"
  echo "   Input Monitoring permission again after each rebuild)"
  codesign --force --sign - --identifier com.primeconnectionkit.app "$APP"
fi

# Confirm the signature took, so a failure cannot be discovered later by whoever
# downloads it.
codesign --verify --strict "$APP" || {
  echo "error: the signature does not verify" >&2
  exit 1
}

echo
echo "Built $APP"
echo "Run it with:  open '$APP'"
echo "Install it with:  Scripts/install-app.sh"
