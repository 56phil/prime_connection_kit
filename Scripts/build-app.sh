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
swift build -c release --product PrimeConnectionKit

BIN="$(swift build -c release --product PrimeConnectionKit --show-bin-path)/PrimeConnectionKit"
if [[ ! -x "$BIN" ]]; then
  echo "error: the built binary was not found at $BIN" >&2
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
# Prefer a real signing identity over ad-hoc. macOS keys the Input Monitoring
# grant to the code signature, and an ad-hoc signature changes on every build, so
# each rebuild would ask for permission again. A team-signed build keeps the grant.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "  identity: $IDENTITY"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --identifier com.primeconnectionkit.app "$APP" || {
    echo "warning: signing with '$IDENTITY' failed; falling back to ad-hoc" >&2
    codesign --force --sign - --identifier com.primeconnectionkit.app "$APP"
  }
else
  echo "  no signing identity found; using ad-hoc"
  echo "  (an ad-hoc signature changes on every build, so macOS will ask for"
  echo "   Input Monitoring permission again after each rebuild)"
  codesign --force --sign - --identifier com.primeconnectionkit.app "$APP"
fi

echo
echo "Built $APP"
echo "Run it with:  open '$APP'"
echo "Install it with:  Scripts/install-app.sh"
