# Launch checklist

Working notes for getting this in front of people, and for the one piece that is
not a code problem.

## Blocking

- [ ] **Decide the Apple ID route** (below). Everything else here is done or can be
      done without it.
- [ ] **Capture the screenshots.** `Scripts/capture-screenshot.sh` is ready and
      verified, but Screen Recording permission is required first, which could not
      be granted on your behalf. See below.

## Done

- [x] MIT licence, in `LICENSE`, referenced from the README.
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
./Scripts/notarize.sh build/PrimeConnectionKit-1.0.0.dmg pck-notary
```

The certificate and the image are separate: `make-dmg.sh` signs, `notarize.sh`
uploads and staples. The second command needs an app-specific password from
appleid.apple.com, not the account password.

For CI, add `MACOS_CERTIFICATE_BASE64` and `MACOS_CERTIFICATE_PASSWORD` as
repository secrets and the release workflow signs properly instead of ad-hoc. It
does not notarize yet — that needs the credentials stored on the runner too.

## Screenshots

The capture script is written, syntax-checked, and its window lookup is verified
against the running app. It cannot complete here because Screen Recording is
denied to this terminal, which is a permission no script can grant itself.

Grant **System Settings → Privacy & Security → Screen Recording** to your terminal,
reopen it, then with the app running:

```
./Scripts/capture-screenshot.sh main-window          # the three-pane window
./Scripts/capture-screenshot.sh program-editor       # a program open for editing
./Scripts/capture-screenshot.sh monitor              # the classroom monitor
```

Each writes `Docs/screenshots/<name>.png`. The window is captured by its own
identifier, so it does not matter what else is on screen.

Worth picturing, in order of how much they would help:

- the main window with a calculator's content tree visible,
- a program open in the editor, since that is the thing people come to do,
- the Monitor window, because it is the classroom feature HP charges attention for.

Then reference them from the README. A calculator application asks people to take a
lot on trust when it shows them nothing.

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
