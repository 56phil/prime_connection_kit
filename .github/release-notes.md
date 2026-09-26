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

@@GATEKEEPER_SECTION@@
