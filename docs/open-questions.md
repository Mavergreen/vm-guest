# Open questions with deadlines

Questions that must be answered before a specific phase finishes, because
answering them later means redoing that phase's work. Each names the point
of no return.

---

## Q1. Should the image carry Apple's post-10.9.5 updates?

**Raised:** 2026-09-17, by the user.
**Must be answered before:** P4's pipeline is finalized, and before P5 takes
a baseline measurement.

### Where this stands

Golden #1 is **10.9.5 build 13F34** — the final Mavericks *release*, but not
the final Mavericks *state*. Apple shipped security updates after it, and
Kostarelas specifically recommends the 2016 one.

We deliberately applied none of them. `docs/install-log.md`'s "Deferred
post-install changes" section records why: golden #1 is the baseline every
P5 experiment is compared against, and a hardening script or update that
silently disables a service makes every later measurement unattributable.

That reasoning is still sound for the *baseline*. It says nothing about what
the **pipeline** should produce, which is the actual question.

### Why the deadline is real

P4's pipeline decides what goes into every image built from here on. If
updates belong in the image, the `OSInstall.collection` mechanism is the
natural place — updates as packages, installed during the install, which is
far cleaner than patching a built image afterward. Deciding after P4 ships
means reworking the pipeline rather than configuring it.

### What has been established, measured 2026-09-19

Measured, not inherited: a live 10.9.5 guest (build 13F34) talking to
Apple's servers in 2026, and this host talking to Apple's catalog for 10.9.

**1. Do Apple's update servers still serve 10.9? YES. Settled.**

`softwareupdate -l` in the guest returns five items:

| Identifier | Title | Size as reported |
|---|---|---|
| `iBooksDelta-1.0.1` | iBooks Update (1.0.1) | 14354K |
| `RemoteDesktopClient-3.8.4` | Remote Desktop Client Update (3.8.4) | 7113K |
| `Safari9.1.3Mavericks-9.1.3` | Safari (9.1.3) | 61715K |
| `Security Update 2016-004-10.9.5` | Security Update 2016-004 | 362293K, restart |
| `iTunesX-12.6.2` | iTunes (12.6.2) | 277622K |

The catalog behind them is still up as well:
`https://swscan.apple.com/content/catalogs/others/index-10.9.merged-1.sucatalog`
answers 200 with 975,665 bytes, `IndexDate` 2022-10-18, 333 products.

**2. Which updates exist? Mostly settled -- AND THIS CORRECTS THE BRIEFS.**

The briefs say the last Mavericks security update is **2016-001**. It is
**2016-004**, and the guest is being offered it right now.

**That is the third undated inherited claim this project has found to be
wrong**, after the `usb-tablet` kext (whose author fixed QEMU in 2017, so
the kext the briefs demand is not needed) and "DNS needs configuring in
the guest" (`docs/install-log.md`: it works out of the box). Three is a
pattern, and the pattern is not about these three facts. It is about a
**class of source**: undated third-party write-ups, each correct when
written, each carried forward by the next writer without a date attached.
Every one of them has been wrong in the same direction -- describing a
world that was fixed years ago. Treat an undated claim from that class as
a hypothesis with an experiment attached, never as a fact, and prefer a
measurement from a running system to any of them. `docs/prior-art.md`
names the sources; this is the rule for reading them.

**3. Are they available as standalone `.pkg` downloads? YES for three of
the five, including the one that matters. Two are unexplained.**

Apple's own CDN serves them directly, over plain HTTP, with no account and
no `softwareupdate` involved:

| Update | Packages | Bytes |
|---|---|---|
| Security Update 2016-004 | `SecUpd2016-004Mavericks.pkg` | 370,988,463 |
| Safari 9.1.3 | `Safari9.1.3Mavericks.pkg` | 63,197,064 |
| iTunes 12.6.2 | `iTunesX`, `MobileDevice`, `CoreFP`, `CoreADI`, `iTunesAccess` | 284,285,780 total |

The sizes are how we know these are the same artifacts the guest would
install: each matches the KiB figure `softwareupdate -l` printed, exactly.

The security update was fetched here in full and hashed, so it is already
pinnable in the form `vendor/sources.tsv` takes -- name, URL, sha256, with
the checksum as the identity and the URL as only how to get it:

```
http://swcdn.apple.com/content/downloads/63/01/041-88446-A_AI0EXM8N26/wlglj8xbhacww0zt8rtv5n1o9dkpl72ozq/SecUpd2016-004Mavericks.pkg
sha256 fd71517772928b35e773276b300ef30e0d264ed9d030bf3862625cab5513d1b5
370,988,463 bytes, Last-Modified 2019-10-01
```

Plain HTTP with no TLS is not the exposure it looks like here, for the
same reason it is not for any other ingredient: nothing is trusted because
of where it came from. The checksum is the identity.

**So the reproducible path exists.** These can be pinned and checksummed
like every other ingredient and fed through `OSInstall.collection` by the
`--updates` switch `image/build-image.sh` already carries -- no
`softwareupdate` at build time, no network dependency in the build, no
"do without".

### What is still open

- **Two of the five items are not in that catalog at all.**
  `iBooksDelta-1.0.1` and `RemoteDesktopClient-3.8.4` appear in the
  guest's list, but neither their names nor their packages occur anywhere
  in the 10.9 catalog, and all 333 of its distribution files were fetched
  and searched to be sure. So the guest is being offered two things from a
  source this catalog does not explain. **Ask the guest**, which knows:
  `defaults read /Library/Preferences/com.apple.SoftwareUpdate CatalogURL`
  and `/var/log/install.log` will name what it actually talked to. Until
  then, whether those two have standalone packages is unknown -- and both
  are applications rather than OS updates, so they may well not matter.
- **Nothing here says these updates should be applied.** Whether they
  install cleanly in this guest, and what they change, is untested.

### The shape of the answer

Probably **two images, not one** — which the golden/clone machinery already
supports:

- **A baseline golden**, un-updated, for P5 measurement. Exists today.
- **An updated working image**, which is what anyone should actually run and
  what P6's CI should test against.

If so, the pipeline needs an `--updates` switch rather than a single
opinion, and both images must be reproducible from pinned inputs.

**This is the user's call, and it is still open.** The evidence above says
the reproducible path is available; it does not say the image should take
it. P5's baseline depends on the answer, which is why the deadline is
real.

### Do not

Run `softwareupdate` unattended at image-build time. It reaches Apple's
servers at build time, which makes the build non-reproducible and
network-dependent, and on a 2013 OS talking to 2026 servers it may hang.
`image/payload/firstboot.sh` already has a rule that network-touching steps
carry timeouts.


---

## Q2. Is `usb-net` the right NIC, or just the one that was verified?

**Raised:** 2026-09-17, by the user asking why we did not pick e1000.
**Must be answered before:** P5 reports a network baseline, and before P6
budgets CI job time.

### How we got here

The briefs said `e1000-82545em`: DarwinKVM recommends it for 10.9, and the
design took it as the first thing to try. Inspecting the UTM bundle showed
`NetworkCard: usb-net`, and P1 applied its own rule — where the bundle
disagrees with the briefs' guesses, the bundle wins, because it
demonstrably booted a Mavericks install while the briefs' advice was
inherited and undated.

That was right **for P1**, whose job was to reach a known-good state with
the fewest unknowns. It is probably wrong as a long-term answer.

### Why it is probably wrong

- **`usb-net` is CDC-ECM over EHCI** — USB Ethernet class. It works
  (`AppleUSBCDCECMData` loads during boot) but CDC-ECM is an inefficient
  transport, and it occupies a port on a USB controller 10.9 is already
  demonstrably fussy about.
- **`e1000-82545em` is gigabit-class emulation**, and is what DarwinKVM
  recommends for this exact OS.
- **`virtio-net` is likely fastest.** The perf brief cites
  `pmj/virtio-net-osx` at roughly 2x send and 4x receive versus the
  emulated Intel NIC, and Somlo confirmed it on 10.9.

### The honest status

**We never tested e1000.** It was recorded as "an experiment, not the
baseline" and never run. This is an open question wearing the costume of a
decision.

### One ordering trap

`virtio-net-osx` needs a kext, and this project has already been burned
once by treating a 2016-era "X does not work" as current — `usb-tablet`
turned out to need no kext at all, because its author fixed QEMU in 2017.
**Re-test whether the kext is still required before ranking virtio against
e1000**, rather than assuming the brief's description still holds.
