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

## What changed in @@VERSION@@

- **Set Clock from Computer** did nothing. The command was sent without the date and
  time body the calculator needs, and one sent without it is accepted and leaves the
  clock exactly as it was. The menu item also reported success whatever happened,
  which is how it went unnoticed.

@@GATEKEEPER_SECTION@@
