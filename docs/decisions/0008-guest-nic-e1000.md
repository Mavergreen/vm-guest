# 0008 — The guest's NIC is `e1000-82545em`, and a NIC is build-time state

Date: 2026-09-21
Status: accepted, on measurement

`docs/open-questions.md` Q2 asked whether `usb-net` was the right network
device or merely the one P1 had verified. It was the latter. This records
what replaced it and what the measurement found on the way.

## Decision

**`image/build-image.sh` defaults to `-device e1000-82545em,netdev=net0`.**
`--nic` selects among `usb-net`, `e1000-82545em` and `virtio-net-pci`, and
the manifest records which one an image was built with.

## Why

Measured on the primary host (`pet-power-plant`, i7-8700B, QEMU 8.2.2,
`-accel kvm`), one changed line, unencrypted HTTP against a host-local
server, 200 MB per transfer, three transfers each direction:

| device | host -> guest | guest -> host | link the guest reports |
|---|---|---|---|
| `usb-net` (CDC-ECM) | 1.24 MB/s | 1.27 MB/s | `10baseT/UTP <full-duplex>` |
| `e1000-82545em` | 174 MB/s | 23.3 MB/s | `1000baseT <full-duplex>` |
| `virtio-net-pci` | no link | no link | no interface at all |

That is **140x receive and 18x send**. The gap is not a tuning difference:
the guest's own `ifconfig` reports the CDC-ECM link as 10baseT, and
1.24 MB/s is 9.9 Mbit/s. `usb-net` was running at exactly the speed it said
it was.

`e1000-82545em` is also the device 10.9 already has a driver for.
`AppleIntel8254XEthernet` 3.1.4b1 loads and claims it with nothing added,
and `networksetup` calls the result "Ethernet" rather than
"RNDIS/QEMU USB Network Device". And it stops occupying a port on the USB
controller that G13 records 10.9 as being fussy about.

## Why not `virtio-net-pci`

**The kext is still required, and this is the first time anyone here
checked.** The brief's claim came from a 2016-era source, which is the
class of claim this project has been wrong about four times. This time the
claim held:

QEMU presents the device and IOKit enumerates it —
`compatible = <"pci1af4,1","pci1af4,1000","pciclass,020000">` — and
**nothing matches it**. The node has no driver child and no
`IOEthernetInterface`, while the `e1000` beside it in the same boot has
both. No file under `/System/Library/Extensions` mentions `1af4` at all.
There is no virtio networking in stock 10.9 to be re-tested into existence.

So `virtio-net-pci` stays in `--nic`'s list, because it is what someone
would try after installing `pmj/virtio-net-osx`, and a switch that refuses
the interesting case is not useful. It is documented as producing an image
with no network until that kext is present.

## The finding that outranks the benchmark

**A NIC is build-time state in 10.9, not a runtime option.** The OS records
the interfaces it has seen in
`/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist` and
creates network *services* for them there and then. Boot an
already-installed guest with a NIC it has never met and you get:

- the device enumerated and its driver matched,
- a BSD interface (`en1`) and a hardware port,
- **no network service, no DHCP, no route, no SSH.**

Measured in both directions: an image installed with `usb-net` booted with
`e1000-82545em` never answered SSH (420 s, guest sitting at its login
window), and the same image booted with both NICs showed `en1` present,
`AppleIntel8254XEthernet` loaded, and `networksetup -getinfo Ethernet`
answering "Ethernet is not a recognized network service."

Three consequences, and they are the reason this is an ADR and not a
one-line default change:

1. **`--nic` belongs to the build, and the manifest records it.** It is an
   input that changes what is in the image, like `--updates`.
2. **A profile's `-device` line must match the disk it names.** The two
   `p4-*` profiles keep `usb-net` for exactly this reason and say so.
3. **Changing the default does not migrate existing images.** Anyone with an
   image built before today keeps `usb-net` until they rebuild.

## What would change this

- **A different QEMU.** Everything here was measured on 8.2.2.
  `squirrel-zapper` has 11.1.1; ledger entry G24 is the hypothesis and
  `bin/triangulate.sh` now reports on it.
- **Tap or vhost instead of slirp.** Every number above went through QEMU's
  user-mode network stack, which is what this project actually ships. A
  faster transport would raise the `e1000` numbers and almost certainly not
  the `usb-net` ones, since 10baseT is a property of the device model.
- **The virtio kext.** If `pmj/virtio-net-osx` is installed and works, the
  ranking is open again — but it is then a *kext decision*, which is a
  larger commitment than a `-device` line, and the perf brief's 2x/4x is
  against an emulated Intel NIC, not against 10 Mbit CDC-ECM.

## What was not measured

`e1000` (the 82540em alias), `e1000e` and `vmxnet3` were not tested. The
question was which of the three candidates Q2 named should be the default,
and one of them is 140x the incumbent.
