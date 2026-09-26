# Launch checklist

Where this stands: the application is complete and hardware-verified, the
screenshots are captured, and `v1.0.1` is published. What is left is one optional
item and the announcing itself.

## The one open item: a Developer ID

Notarization needs a paid Developer ID certificate, which needs Apple Developer
Program membership. Without it, a downloaded copy is quarantined and refused, and
the downloader has to clear the attribute by hand. That is a rough edge on the
download, not a problem with the application — a source build is never quarantined
and has no expiry, so nothing decays while this waits.

You are **not** the Account Holder of the former employer's team, which turns out to
be the easier case.

### What Apple's documentation settles

Two questions were going to be worth asking Apple. Both are answered in their
published help, so nothing needs to be asked:

1. **Can a member leave an organization's team?** *"You can leave an organization's
   development team at any time."* Only an Account Holder is restricted, because the
   role carries legal responsibility — and that is not you.
   ([Leave a team](https://developer.apple.com/help/account/access/leave-a-team/))

2. **Can an Apple ID hold an individual membership while it is on a client's team?**
   Yes — Apple's own enrollment page tells contract developers exactly that: *"You
   should enroll in the Apple Developer Program as an individual."* The two
   memberships coexist; there is no conflict to resolve first.
   ([Program enrollment](https://developer.apple.com/help/account/membership/program-enrollment/))

So a **fresh Apple ID is not needed**, and neither is anyone's cooperation.

### The sequence, when the $99 is available

1. **Enrol as an individual**, with the Apple ID you already use. It is $99 a year,
   it renews automatically, and the card used has to be your own — Apple delays
   enrollment over a card that is not, and asks for photo identification to sort it
   out. Your personal legal name becomes the seller name, which is what you want for
   your own work.

2. **Leave the former employer's team.** In App Store Connect: your name at the top
   right → *Edit Profile* → *Leave Team*. Independent of the enrollment, and worth
   doing whether or not you ever notarize anything.

3. **Create a Developer ID Application certificate** in your new individual
   membership. This is a separate certificate type from the development one, and it
   is issued to your own team identifier — not `SD648P3Y6K`.

4. **Then:**

```
security find-identity -v -p codesigning     # expect a "Developer ID Application" line
./Scripts/make-dmg.sh                        # signs the app and the image
xcrun notarytool store-credentials "pck-notary" \
  --apple-id <you> --team-id <YOUR_TEAM_ID> --password <app-specific-password>
./Scripts/notarize.sh build/PrimeConnectionKit-<version>.dmg pck-notary
```

The app-specific password comes from appleid.apple.com, not the account password.
`notarize.sh` pre-flights the image and will refuse an unsigned, ad-hoc or
untimestamped one rather than let `notarytool` report something cryptic.

For CI, add `MACOS_CERTIFICATE_BASE64`, `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID` and `MACOS_NOTARY_PASSWORD` as
repository secrets. The release workflow then signs, notarizes, staples and
regenerates the checksum — stapling changes the file, so a checksum taken before it
would not match what anyone downloads — and it says so in the release notes.

### The step that is easy to miss

Once you have an individual membership, `security find-identity` lists certificates
for **two** teams: yours and the former employer's. Signing with the wrong one is not
a hypothetical — it is the state this machine is in right now, where the only
certificate installed belongs to a team that has nothing to do with this project.

Packaging refuses to publish an app carrying a team identifier it was not told to
expect, so this cannot reach a download:

```
error: this app is signed with team SD648P3Y6K, and packaging it would
       publish that team identifier as the team of record.
```

It passes `ALLOWED_TEAM_ID=<yours>` to say which team is expected. A development
certificate is also re-signed ad-hoc before packaging, since it is not distributable
in any case and nothing is lost by dropping the identifier.

## Announcing

The strongest material is not the application — it is the four protocol corrections,
because they are verifiable facts the community has wanted for years. In particular:

> `libhpcalcs`' README has carried this in its TODO list since 2013: *"strip out
> leading program metadata, if any, from `.hpprgm` files"* — and the answer is now
> measured: the calculator stores a program transfer as raw UTF-16 text terminated
> by a NUL, and the container is the disk form the calculator builds itself.

Lead with that. A post that hands the community a measurement reads as a
contribution; one that opens with "here is my app" reads as promotion. The draft is
in `Docs/announcement-post.md`.

### Where

1. **hpmuseum.org**, HP Prime subforum. The canonical venue, and there are already
   threads from Mac users hitting exactly this.
2. **hpcalc.org** — where this audience looks: HP's own Connectivity Kit has 11,425
   downloads there.
3. **`debrouxl/hplp`** — the findings answer their 2013 TODO, which is where the
   protocol knowledge will be most durable.
4. Repository topics, already set, for discovery.

### Two things not to claim

- **Not that HP abandoned it.** Their Connectivity Kit 2.4.2 was released on
  9 September 2026 — current, not stale. I downloaded it and checked: it is still
  `x86_64` only, which is the real and checkable point on Apple silicon.
- **Not that it works on every Mac.** It is an arm64 build. Intel users can build
  from source; no Intel binary is published.
