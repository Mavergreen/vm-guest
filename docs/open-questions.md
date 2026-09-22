# Open questions with deadlines

Questions that must be answered before a specific phase finishes, because
answering them later means redoing that phase's work. Each names the point
of no return.

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
