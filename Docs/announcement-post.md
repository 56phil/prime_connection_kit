# Announcement post

Draft for the HP Museum forum (HP Prime subforum), which is the canonical venue for
this. Written to lead with the measurements rather than the application: the
findings are the contribution, and the app is what they were learned from.

---

**Title: Four things the Prime link protocol does differently, and a native Mac
Connectivity Kit**

I've been working on a native macOS replacement for HP Connectivity Kit, because
HP's build is `x86_64` only and I wanted something that runs properly on Apple
silicon. It works — connects, reads and writes content, mirrors to the same working
folder HP uses, screen capture and monitoring — and I'll link it at the end.

But the more useful part is what measuring it against real hardware turned up,
because several things are recorded differently in every source I could find. All
of these contradict what's published, and all four are reproducible:

| Detail | Published sources | What the calculator actually does |
|---|---|---|
| HID report size | 64 bytes | **1024 bytes** |
| Readiness reply | echoes `0xFF` | **`'Y'` = `0x59`** |
| Write acknowledgement | a reply is sent | **nothing is sent** |
| Program transfer payload | the `.hpprgm` container | **the raw UTF-16 text** |

Two notes on why these matter:

**The missing acknowledgement** is the nastiest of them if you're implementing
against the published description. Waiting for a reply that never comes turns a
successful write into a reported failure, and you'd be debugging your transport when
the write actually worked.

**The program payload** is the one I think is most interesting, and it closes
something that's been open a long time.
[libhpcalcs](https://github.com/debrouxl/hplp) has carried this in its TODO list
since 2013:

> strip out leading program metadata, if any, from `.hpprgm` files

The answer is that there is no metadata to strip at transfer time — the calculator
stores a program transfer as **text** and terminates on a NUL. The container on disk
is the form the calculator builds itself. So sending the container makes it keep
only the leading UTF-16 units. The evidence is exact: a container starting
`14 00 00 00` was stored as 4 bytes, and a file of HP's starting
`7C 61 8A B2 FE FF FF FF 00 00` was stored as 10 — in both cases, precisely the
units before the first zero byte. Sending the source text instead round-trips a
1378-character program intact across three reports.

I'd be glad to write these up in more detail, or to send them upstream to `hplp` as
a patch to that TODO item if that's useful.

**On the Mac application.** It's Swift and AppKit, MIT licensed, no third-party
dependencies — IOKit HID directly, `ditto` for the backup format. It reuses
`~/Documents/HP Connectivity Kit` verbatim, so it and HP's Connectivity Kit coexist.
It's an arm64 build; if you're on Intel, building from source works and there's no
download warning that way either. HP Prime G2 over USB, firmware V2.060.650 is what
I've tested against.

https://github.com/56phil/prime_connection_kit

Known gaps, so nobody wastes an evening: firmware updating, exam-mode restriction
authoring, polls and results, and the wireless classroom network are not implemented.
The README has the full list.

---

## Notes for when you post

- **Say which calculator and firmware** you tested against (done above). This
  community will ask, and volunteering it is the difference between a thread about
  your work and a thread about your assumptions.
- **Lead with the findings.** The first half of the post is useful whether or not
  anyone downloads the app. That is what keeps it from reading as promotion.
- **Name the gaps up front.** This audience finds them anyway, and volunteering them
  costs nothing while being caught out costs credibility.
- **Do not say HP abandoned it.** Their 2.4.2 landed on 9 September 2026. The
  defensible and checkable point is that it is still `x86_64` — I downloaded it and
  confirmed the binary architecture rather than inferring it.
- **Offer the upstream patch** to `hplp`. It answers a TODO they've had since 2013,
  and it's the kind of thing that earns goodwill in a small community.

## Other places

- **hpcalc.org** — submit the disk image. HP's own Connectivity Kit has 11,425
  downloads there, so it's where this audience looks.
- **GitHub topics** on the repository: `hp-prime`, `hp-calculator`, `macos`, `swift`,
  `appkit`, `iokit-hid`, `connectivity-kit`.
- **`debrouxl/hplp`** — an issue or PR describing the four findings, which is where
  the protocol knowledge would be most durable.
- Reddit and Discord: I could not verify the current subreddits or servers, so treat
  those as leads to check rather than venues I'd recommend sight-unseen.
