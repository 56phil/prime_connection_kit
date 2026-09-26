Native macOS replacement for [HP Connectivity Kit](https://www.hp.com), for
HP Prime calculators.

**Requires macOS 14 or later.** No driver and no kernel extension: the app reaches
the calculator through IOKit HID, which macOS already provides. HP's own
Connectivity Kit can stay installed alongside it — both use the same working
folder, `~/Documents/HP Connectivity Kit`.

Verify the download before opening it:

```sh
shasum -a 256 -c PrimeConnectionKit-@@VERSION@@.dmg.sha256
```

### If macOS refuses to open it

This build is signed but **not notarized**, because notarization requires a paid
Developer ID certificate rather than the development certificate used here. macOS
therefore quarantines anything downloaded from the internet and kills it on launch.

To run it, clear the quarantine attribute after dragging the app to Applications:

```sh
xattr -d com.apple.quarantine "/Applications/PrimeConnectionKit.app"
```

Alternatively, launch it once, let it be refused, then allow it under
**System Settings → Privacy & Security → Open Anyway**.

Note that right-clicking the app and choosing *Open* does not bypass this on
current macOS versions; that route no longer applies to apps that are not
notarized.

### First launch

macOS asks for **Input Monitoring** permission, which it requires before any
application may open a USB HID device. Grant it, then quit and reopen the app.
Until then the app reports that the calculator could not be opened, rather than
failing quietly.
