#!/bin/zsh
# Captures the application's main window as a PNG, for the README.
#
# ## Permission
#
# Capturing the screen requires Screen Recording permission, which macOS grants to
# the *calling* application — the terminal, not this script. Without it,
# `screencapture` fails with "could not create image from display". Grant it under
# System Settings → Privacy & Security → Screen Recording, then reopen the
# terminal.
#
# ## Usage
#
# With the app running in the state you want pictured:
#
#   Scripts/capture-screenshot.sh main-window
#
# Writes Docs/screenshots/<name>.png. The window is captured by its own identifier
# rather than by screen region, so anything overlapping it is excluded and the
# standard window shadow is included.

set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  echo "usage: $0 <name>    e.g. $0 main-window" >&2
  echo >&2
  echo "The app's main window is captured to Docs/screenshots/<name>.png." >&2
  exit 2
fi

# The argument is a name, not a path, and the output location is fixed. A path
# would otherwise be joined onto the output directory and produce something like
# Docs/screenshots//tmp/shot.png, which fails as an empty capture and points the
# blame at Screen Recording rather than at the argument.
if [[ "$NAME" == */* ]]; then
  echo "error: the argument is a name, not a path (got '$NAME')." >&2
  echo "       Images are always written to Docs/screenshots/<name>.png." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/Docs/screenshots"
OUTPUT="$OUTPUT_DIR/$NAME.png"
mkdir -p "$OUTPUT_DIR"

# Ask Core Graphics for the window identifier. Matching on the owner name and
# requiring an on-screen window avoids picking up a menu or a tooltip.
WINDOW_ID="$(swift - "$1" <<'SWIFT'
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PrimeConnectionKit"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
// The owner name is the bundle's display name, "Prime Connection Kit", not the
// executable's name, so it is matched with spaces removed rather than by the
// executable's spelling.
func isOurApp(_ owner: String) -> Bool {
    owner.replacingOccurrences(of: " ", with: "").contains("PrimeConnectionKit")
}

// The largest window owned by the app is the main one; a toolbar or panel is
// smaller and would produce a confusing picture.
var best: (id: Int, area: Int)?
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          isOurApp(owner),
          let id = window[kCGWindowNumber as String] as? Int,
          let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
          let width = boundsDict["Width"] as? Double,
          let height = boundsDict["Height"] as? Double
    else { continue }
    let area = Int(width * height)
    if best == nil || area > best!.area { best = (id, area) }
}
guard let id = best?.id else { exit(1) }
print(id)
SWIFT
)" || {
  echo "error: no PrimeConnectionKit window is on screen." >&2
  echo "       Launch the app first, and put it in the state you want pictured." >&2
  exit 1
}

echo "Capturing window $WINDOW_ID to $OUTPUT…"
# -o omits the shadow; -x suppresses the capture sound. The window is captured by
# identifier, so it does not matter what else is on screen.
if ! screencapture -x -o -l "$WINDOW_ID" "$OUTPUT" 2>/dev/null; then
  echo "error: screencapture failed." >&2
  echo "       This is almost always missing Screen Recording permission." >&2
  echo "       Grant it to this terminal under System Settings → Privacy &" >&2
  echo "       Security → Screen Recording, then reopen the terminal." >&2
  exit 1
fi

if [[ ! -s "$OUTPUT" ]]; then
  echo "error: $OUTPUT was not written, or is empty." >&2
  exit 1
fi

# Report the size so an unexpectedly small or blank capture is obvious here rather
# than in the README.
SIZE="$(sips -g pixelWidth -g pixelHeight "$OUTPUT" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd× -)"
echo "Wrote $OUTPUT ($SIZE, $(du -h "$OUTPUT" | cut -f1))"
