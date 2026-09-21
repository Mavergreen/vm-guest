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

### ANSWERED 2026-09-21, by measurement. `e1000-82545em`.

One host (`pet-power-plant`), one image per NIC, one changed `-device`
line, QEMU 8.2.2, `-accel kvm`, `-cpu Penryn`, 2 vCPU, 4096 MB, slirp user
networking — the configuration this project actually ships.

**Method.** Not SSH: OpenSSH 10.5p1 encrypting on an emulated Penryn would
have measured the cipher. A plain HTTP server on the host
(`python3`, no TLS, generating and draining bytes in memory so no disk is
in the path), and `curl` in the guest — `GET /zeros/209715200` for
host→guest and `PUT` of a 200 MB file for guest→host, with `curl`'s own
`%{speed_download}` / `%{speed_upload}` as the number. 200 MB per transfer,
three transfers each direction on the first boot, one each after a reboot.
Runs on `vm/clone.sh` overlays; no golden was written to.

#### 1. Does the virtio kext still exist as a requirement? **Yes. This one is real.**

This was the ordering trap, and it was worth taking seriously: four undated
inherited claims in this project have now been wrong. This one is not.

Booting a guest with `-device virtio-net-pci` and no kext gives **no
network at all** — no SSH after 420 s, the guest sitting at its login
window with the desktop drawn, so the OS is fine and only the NIC is
missing. To find out *why* without a network to ask over, the same image
was booted with `usb-net` (for SSH) **and** `virtio-net-pci` and
`e1000-82545em` beside it. The guest's own IOKit registry answers it:

```
+-o S08@1  <class IOPCIDevice, registered, matched, active>
|     "name" = <"ethernet">
|     "compatible" = <"pci1af4,1","pci1af4,1000","pciclass,020000","S08">
                                        <- no child. nothing claims it.

+-o S10@2  <class IOPCIDevice, registered, matched, active>
|     "compatible" = <"pci1af4,1100","pci8086,100f","pciclass,020000","S10">
| +-o AppleIntel8254XEthernet
|   +-o en1  <class IOEthernetInterface, registered, matched, active>
```

QEMU presents the virtio device, IOKit enumerates it, and **nothing in
10.9 matches it** — no driver child, no `IOEthernetInterface`, no BSD
interface. No `Info.plist` under `/System/Library/Extensions` mentions
`1af4` anywhere. There is no dormant virtio support to be woken up; there
is no virtio networking in this OS. `pmj/virtio-net-osx` is still the only
way to have it, which makes virtio a **kext decision**, not a `-device`
line, and a much larger commitment than this question was asking about.

So virtio was not ranked. It stays selectable by `--nic` because that is
what someone with the kext installed would reach for.

#### 2. The numbers

| device | host → guest | guest → host | link the guest reports | reboot |
|---|---|---|---|---|
| `usb-net` (CDC-ECM) | **1.24 MB/s** | **1.27 MB/s** | `10baseT/UTP <full-duplex>` | survives, keeps `en0` |
| `e1000-82545em` | **174 MB/s** | **23.3 MB/s** | `1000baseT <full-duplex>` | survives, keeps `en0` |
| `virtio-net-pci` | — | — | no interface | — |

Per-transfer, so the spread is visible:

```
usb-net   down  1244668  1240753  1244742 B/s     (168.5 s, 169.0 s, 168.5 s)
usb-net   up    1269114  1268936  1269202 B/s     (165.2 s, 165.3 s, 165.2 s)
e1000     down  170921908  167376081  182956048 B/s   (1.23 s, 1.25 s, 1.15 s)
e1000     up     23072433   22873157   23813123 B/s   (9.09 s, 9.17 s, 8.81 s)
```

**What varied:** almost nothing. `usb-net` repeated to within 0.3%;
`e1000` to within 5% downstream and 4% upstream. These are not noisy
measurements, which is unsurprising once the guest tells you why: **the
CDC-ECM link negotiates 10baseT and 1.24 MB/s is 9.9 Mbit/s.** `usb-net`
was running at precisely the speed it was advertising. That is a device
property, not a tuning one.

`e1000` is **140x receive and 18x send**. Its own asymmetry — 174 MB/s in,
23 MB/s out — is real and repeatable, and is the opposite of the direction
the perf brief cares about; it was not chased further, since the slow
direction is still 18x the incumbent.

#### 3. Reboot survival, and the finding that outranks the benchmark

Both working NICs survive a reboot with their interface name, MAC, DHCP
lease, DNS and default route intact, and the same throughput afterwards
— `e1000` 170.4 MB/s down and 22.4 MB/s up, `usb-net` 1 244 455 B/s down
and 1 269 195 B/s up, both within 0.02% of their pre-reboot figures. The
reboot is a
monitor `system_reset` after an explicit `sync` — a power cycle, because
this guest's account has no password so `sudo` refuses, and the ACPI power
button wants a mouse nobody is driving. The guest's `uptime` either side is
what says the reboot happened.

**But a NIC is build-time state in 10.9, not a runtime option.** An image
installed with `usb-net`, booted with `e1000-82545em` and nothing else
changed, **never came up**: 420 s, no SSH, login window on screen. The
two-NIC probe says why — `en1` exists, `AppleIntel8254XEthernet` is loaded,
and `networksetup -getinfo Ethernet` answers *"Ethernet is not a recognized
network service."* 10.9 records the interfaces it has seen in
`/Library/Preferences/SystemConfiguration` and creates services for them
then; a NIC it meets after installation gets a driver and a BSD interface
and **no service, no DHCP, no route**.

A fresh install with `e1000-82545em` as the only NIC the installer ever saw
configured itself with no help at all: install to SSH in 680 s, `en0`,
DHCP, DNS, service named "Ethernet".

So the switch is `image/build-image.sh --nic`, the manifest records it
(`nic e1000-82545em`), and changing the default **does not migrate existing
images** — anyone holding one built before today keeps `usb-net` until they
rebuild. The two `p4-*` profiles keep `usb-net` for exactly this reason and
now say so in a comment.

#### 4. What this does not settle

- **One host.** Everything above is `pet-power-plant` — 6-core Coffee Lake,
  QEMU 8.2.2. `squirrel-zapper` is a 2-core Broadwell running QEMU 11.1.1,
  where the install is 1.7x slower; the *ranking* should hold, because the
  guest names its own link speed and that is a device-model property, but
  the absolute numbers will not, and three major QEMU versions have touched
  these device models. Ledger entry **G24** carries this, and
  `bin/triangulate.sh` has a verdict function for it.
- **slirp is in every number.** QEMU's user-mode network stack is what this
  project ships and what was measured. A tap device needs root, which this
  work does not take. A faster transport would raise `e1000` and would not
  raise `usb-net`.
- **Only the three candidates Q2 named.** `e1000e`, `vmxnet3` and the
  82540em `e1000` alias were not tested.
- **virtio with the kext** was not attempted. Establishing that the kext is
  still needed was the assignment; installing it is a separate decision.

**Decision: `docs/decisions/0008-guest-nic-e1000.md`.**
