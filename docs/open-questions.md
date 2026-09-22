# Open questions with deadlines

Questions that must be answered before a specific phase finishes, because
answering them later means redoing that phase's work. Each names the point
of no return.

**Both questions on this page are now answered.** They are kept rather
than deleted because each records what was measured and what it cost to
find out, and because both corrected a claim this project had inherited
and believed: Q1 that the last Mavericks security update is 2016-001 (it
is 2016-004), and Q2 that `usb-net` was a choice (it was an inheritance,
and the guest had been on a ten-megabit link since P1).

New questions belong here when they have a **deadline** — a phase whose
work would have to be redone if the answer arrived later. A question
without one belongs in the task list or in `docs/configuration-register.md`,
which is where knobs go to have their provenance recorded.

---

## Q1. Should the image carry Apple's post-10.9.5 updates? — **ANSWERED 2026-09-22**

**Answer: two images. `--updates none` stays the P5 baseline; `--updates
security` becomes the default for images people actually run.**

Chosen by the user, 2026-09-22, over "security only", "stay bare" and
"updated by default with no bare option".

### What the answer rests on

Measured 2026-09-21, live, on a 10.9.5 guest (build 13F34) against
Apple's servers:

- **Apple still serves 10.9 updates in 2026.** `softwareupdate -l`
  returns five.
- **Three are downloadable as standalone `.pkg` files**, so they can be
  pinned and checksummed like every other ingredient rather than fetched
  by `softwareupdate` at build time: **Security Update 2016-004**
  (370,988,463 bytes, sha256 `fd715177…`, fetched and hashed here),
  Safari 9.1.3, iTunes 12.6.2.
- `iBooksDelta` and `RemoteDesktopClient-3.8.4` are in no catalogue found
  so far, and are not offered.
- **The briefs were wrong about which update is last.** They say Security
  Update 2016-001; it is **2016-004**. The fourth undated inherited claim
  this project has caught.

### The shape

| value | what it installs | for |
|---|---|---|
| `none` | nothing | **P5's baseline.** Every performance measurement compares against it, and an update that silently disables a service would make those unattributable — `docs/install-log.md` records that reasoning and it still holds *for the baseline* |
| `security` | Security Update 2016-004 | **the default.** What anyone running a dev VM should get |
| `all` | + Safari 9.1.3, iTunes 12.6.2 | opt-in; they are applications rather than the OS |

Both are reproducible from pinned inputs, both are distinguishable by
their manifests, and the golden/clone machinery already supports keeping
two.

### Built, 2026-09-22

All of it, as configuration rather than a rewrite, exactly as P4 intended:
the three packages are pinned in `vendor/sources.tsv` (seven rows — iTunes
12.6.2 is one softwareupdate product made of five flat packages),
`image/fetch-updates.sh` resolves a selection to an ordered package list,
and they ride to the guest the way the OpenSSH packages already do.

Three things the packages themselves settled, none of which was guessable
from the outside:

- **They install BEFORE the family's OpenSSH.** 2016-004's payload contains
  `./usr/bin/ssh` and `./usr/sbin/sshd`, so the other order would have
  undone the OpenSSH replacement and reintroduced the defect that cost a
  full install to find in P4.
- **`sw_vers` is not the witness.** `ProductVersion` stays 10.9.5. What
  moves is the receipt
  (`com.apple.pkg.update.security.2016-004Mavericks.13F1911`) and
  `sw_vers -buildVersion`, **13F34 → 13F1911**, because the update carries
  `SystemVersion.plist`.
- **The media's 512 MiB margin is not spare room.** It leaves 483.8 MiB
  free, measured off the HFS+ volume header; 2016-004 is 353.8 MiB and
  `all` is 685 MiB. Hence `media/build-installer-img.sh --extra-space-mib`,
  which defaults to 0 and so leaves `none` geometrically identical.

`iBooksDelta-1.0.1` and `RemoteDesktopClient-3.8.4` are recorded in
`INGREDIENTS.md` as an ingredient with a written reason and no pin, because
there is no URL to pin.

**Decision: `docs/decisions/0011-updates-in-the-default-image.md`.**

### Unchanged

**Never run `softwareupdate` at image-build time.** It reaches Apple's
servers during the build, which makes the build non-reproducible and
network-dependent, and a 2013 OS talking to 2026 servers may hang.

---

## Q2. Is `usb-net` the right NIC, or just the one that was verified? — **ANSWERED 2026-09-21**

**Answer: `e1000-82545em`, and it is now the default.** See
`docs/decisions/0008`, `docs/host-profile.md` G24 and the Q2 entries in
`NOTES.md`.

### What was measured

Same image, same host, one variable, on `vm/clone.sh` overlays. **Not over
SSH** — OpenSSH 10.5p1 encrypting on an emulated Penryn would have
benchmarked the cipher, not the NIC — but over plain HTTP from a host-side
server, 200 MB per transfer, three runs each way.

| device | host→guest | guest→host | link the guest reports |
|---|---|---|---|
| `usb-net` (the old default) | 1.24 MB/s | 1.27 MB/s | `10baseT/UTP` |
| **`e1000-82545em`** | **174 MB/s** | **23.3 MB/s** | `1000baseT` |
| `virtio-net-pci` | — | — | no interface at all |

**140x receive, 18x send.** `usb-net` was not misconfigured: 1.24 MB/s
*is* 9.9 Mbit/s, which is what CDC-ECM over EHCI negotiates. The guest had
been running on a ten-megabit link since P1.

### The virtio kext claim held — the first inherited claim that did

A guest booted with three NICs at once (`usb-net` for SSH plus both
candidates) so IOKit could be read from inside: the virtio device
enumerates as `pci1af4,1` and **nothing matches it** — no driver child, no
`IOEthernetInterface` — while the e1000 beside it in the same boot has
both, and no `Info.plist` under `/System/Library/Extensions` mentions
`1af4`. There is no dormant support to wake. Whether a kext would beat
e1000's 23.3 MB/s send is a separate question, deferred with P5.

### The finding that outranks the benchmark

**A NIC is build-time state.** An image installed with `usb-net` and then
booted with e1000 never came up — the driver loaded, `en1` appeared, and
the system reported "Ethernet is not a recognized network service". So
`--nic` is a build flag, the manifest records it, and changing the default
migrates nothing: existing goldens keep `usb-net` until rebuilt.

### Scope

All of it is QEMU 8.2.2 on the primary host. **G24 records that the
ranking is QEMU's, not physics**, and carries a verdict function so
another host can speak to it.
