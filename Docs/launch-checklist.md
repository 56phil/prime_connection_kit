# Launch checklist

Working notes for getting this in front of people, and for the one piece that is
not a code problem.

## Blocking

- [ ] **Decide the Apple ID route** (below). Everything else here is done or can be
      done without it.

## Done

- [x] MIT licence, in `LICENSE`, referenced from the README.
- [x] **Screenshots captured**, with the app running against the real calculator:
      `Docs/screenshots/main-window.png` (three-pane window with the content tree),
      `program-editor.png` (the `first_primes` program open for editing), and
      `monitor.png` (the Monitor window, "1 calculator connected"). Screen
      Recording permission had to be granted to the terminal first; a script
      cannot grant itself that permission.
- [x] **Monitor window crash fixed.** Opening it with a calculator attached killed
      the process with `NSInternalInconsistencyException` from inside AppKit's
      layout pass. Root cause: `loadView()` called
      `register(_:forItemWithIdentifier:)` *before* assigning
      `collectionViewLayout`; assigning a layout clears the registered item
      classes, so `makeItem(withIdentifier:for:)` fell back to loading a nib named
      `Thumbnail`, found none, and threw. Reproduced outside the app in a minimal
      `NSCollectionView` harness, where the same ordering threw and the reversed
      ordering did not. Fixed in `MonitorViewController.loadView()` by assigning
      the layout before registering.
- [x] Release build prefers a Developer ID, uses the hardened runtime, and
      timestamps the signature — that combination is what notarization requires,
      and each part was verified against a real signature, not assumed.
- [x] The disk image is signed itself, not only the app inside it. Gatekeeper
      assesses the image when it is opened, and a ticket cannot be stapled to an
      unsigned one.
- [x] `Scripts/notarize.sh` pre-flights the image: it refuses an unsigned,
      ad-hoc-signed or untimestamped one, because `notarytool`'s own error for those
      is not obvious.
- [x] Source-build install path documented as the primary one, since a locally
      built app is never quarantined.

## The Developer ID situation

The Apple ID is tied up with a former employer. Two consequences, and the second
is the one that needs care.

### 1. Notarization is blocked, and so is the cleanest onboarding

Without a Developer ID, a downloaded copy is quarantined by macOS and killed on
launch. That is verified on this machine, not assumed: `spctl` returns `rejected`
and the process exits with signal 9. Every download costs a frightening error and a
manual step.

The source-build path sidesteps it entirely, because quarantine is attached at
download rather than at build. That is why the README now leads with it.

### 2. The installed certificate belongs to their team

```
CN = Apple Development: philhuffman56@icloud.com (M7CWTA82Q8)
OU = SD648P3Y6K          <- the employer's team identifier
O  = Philip Huffman      <- the certificate holder's name, not a company
```

`O=Philip Huffman` is the holder's own name; the **`OU` is the team**, and that is
theirs. Signing personal releases with it would put their team identifier on your
own work, which is worth avoiding regardless of notarization.

Nothing has been published that carries it. The released image is ad-hoc signed
with no team identifier, and a search of the whole repository history finds no
employer identifiers.

### What to establish, in order

1. **Are you the Account Holder of that team, or a member?**

   This determines the timeline more than anything else. An Apple Developer Program
   team has exactly **one** Account Holder, and Apple has no mechanism to simply
   reassign it — so if you are the holder, detaching means a team transfer or
   stepping down in a specific order, and it needs their cooperation.

   If you have access to App Store Connect → Users and Access, that answers it.

2. **Can this Apple ID hold an individual membership while it is associated with
   their team?**

   This is the question to put to Apple, and it is the one that decides whether you
   wait or start today. A Developer ID is a separate membership, and enrolling as an
   *individual* is ordinary — the certificate reads "Developer ID Application:
   Philip Huffman", your own name, with your own team identifier.

   If the answer is yes: enroll now, install the certificate, and
   `Scripts/notarize.sh` completes the chain. Nothing else is blocked.

   If the answer is no: a **fresh Apple ID enrolled as an individual** for your own
   work sidesteps it entirely. Less tidy, entirely legitimate, and it does not
   depend on anyone else doing anything.

3. **Ask them to remove you from the team** once it is safe to do so, so the Apple
   ID is genuinely untangled.

### When a Developer ID exists

```
security find-identity -v -p codesigning          # expect a "Developer ID Application" line
./Scripts/make-dmg.sh                             # signs the app and the image
xcrun notarytool store-credentials "pck-notary" \
  --apple-id <you> --team-id <TEAMID> --password <app-specific-password>
source Scripts/version.sh
./Scripts/notarize.sh "build/PrimeConnectionKit-$VERSION.dmg" pck-notary
```

The certificate and the image are separate: `make-dmg.sh` signs, `notarize.sh`
uploads and staples. The second command needs an app-specific password from
appleid.apple.com, not the account password.

For CI, five repository secrets. The first two sign the build; all five also
notarize it:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_BASE64` | the Developer ID Application certificate, exported as a `.p12`, base64-encoded (`base64 -i cert.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | the password given to that export |
| `MACOS_NOTARY_APPLE_ID` | the Apple ID used to enroll |
| `MACOS_NOTARY_TEAM_ID` | the team identifier of the individual membership (10 characters, seen in `security find-identity -v -p codesigning`) |
| `MACOS_NOTARY_PASSWORD` | an app-specific password from appleid.apple.com — not the account password |

The workflow reads the notarization credentials into the environment and tests those
variables, because `secrets` are not available to `if` expressions. Note that an
**ad-hoc signed image can never be notarized**: `notarize.sh` refuses one up front,
since `notarytool`'s own error for it is not obvious.

## Screenshots

Captured. `Scripts/capture-screenshot.sh` writes `Docs/screenshots/<name>.png`,
capturing the window by its own identifier so anything overlapping it is excluded:

```
./Scripts/capture-screenshot.sh main-window          # the three-pane window
./Scripts/capture-screenshot.sh program-editor       # a program open for editing
./Scripts/capture-screenshot.sh monitor              # the classroom monitor
```

Capturing the screen requires Screen Recording permission, which macOS grants to
the *calling* application — the terminal, not the script. Grant it under System
Settings → Privacy & Security → Screen Recording, then reopen the terminal.

What the three show:

- the main window with a calculator's content tree visible,
- a program open in the editor, since that is the thing people come to do,
- the Monitor window, because it is the classroom feature HP charges attention for.

`README.md` references `main-window.png`. A calculator application asks people to
take a lot on trust when it shows them nothing, so the other two are worth adding
where they fit the prose.

## Announcing

The strongest material is not the app — it is the four protocol corrections, because
they are verifiable facts the community has wanted for years. In particular:

> `libhpcalcs`' README has carried this in its TODO list since 2013: *"strip out
> leading program metadata, if any, from `.hpprgm` files"* — and the answer is now
> measured: the calculator stores a program transfer as raw UTF-16 text terminated
> by a NUL, and the container is the disk form the calculator builds itself.

Lead with that. A post that gives the community a measurement reads as a
contribution; one that opens with "here is my app" reads as promotion.

### Where

1. **hpmuseum.org**, HP Prime subforum. The canonical venue. There are already
   threads from Mac users hitting exactly this, including on Apple silicon.
2. **hpcalc.org** — where the audience already looks for this: HP's own
   Connectivity Kit has 11,425 downloads there.
3. **Offer the findings upstream to `debrouxl/hplp`**, which answers their TODO.
4. **GitHub topics** on the repository, for discovery.

### Two things not to claim

- **Not that HP abandoned it.** Their Connectivity Kit 2.4.2 was released on
  9 September 2026 — current, not stale. (I downloaded it and checked: it is still
  `x86_64` only, which is the real and checkable point on Apple silicon.)
- **Not that it works on every Mac.** It is an arm64 build. Intel users can build
  from source; no Intel binary is published.
