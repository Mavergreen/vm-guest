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

### What has to be established first

1. **Do Apple's update servers still serve 10.9 in 2026?** Untested. If
   `softwareupdate -l` returns nothing, most of this question dissolves and
   the answer becomes "obtain the standalone packages or do without".
2. **Which updates exist?** Security Update 2015-006 and 2016-001 are the
   commonly cited last ones for Mavericks. Confirm rather than assume; this
   project has already been wrong twice by inheriting undated claims.
3. **Are they downloadable as standalone `.pkg` files?** If so they can be
   pinned and checksummed like every other artifact here, and fed through
   `OSInstall.collection`. That would keep the pipeline reproducible and
   offline-capable, which `softwareupdate` at build time would not.

### The shape of the answer

Probably **two images, not one** — which the golden/clone machinery already
supports:

- **A baseline golden**, un-updated, for P5 measurement. Exists today.
- **An updated working image**, which is what anyone should actually run and
  what P6's CI should test against.

If so, the pipeline needs an `--updates` switch rather than a single
opinion, and both images must be reproducible from pinned inputs.

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
