# Brief: Guest integration code for the OS X 10.9 guest on QEMU/KVM

## Goal
Improve everyday interactive use of the Mavericks guest (pointer feel, host↔guest clipboard, resize-to-window, graceful control from the host) by adopting existing code where possible and writing new code where necessary. The work is mostly on the guest side.

**Follows:** `mavericks-qemu-brief.md` (bring-up) and `mavericks-kvm-perf-brief.md` (tuning). Start from the tuned golden snapshot and reuse its benchmark and snapshot tooling. Real graphics acceleration is **out of scope**; that's GPU passthrough, planned in the performance brief.

## Premise
The biggest frustrations in a VM are usually not drawing speed but pointer lag, a fixed resolution, and no shared clipboard. Those are fixable with modest code. Record every decision and result in `NOTES.md`.

## Prior art (study before writing anything; if a source can't be fetched, say so)
- **pmj/QemuUSBTablet-OSX:** a driver letting OS X guests use QEMU's `usb-tablet` absolute pointing device. https://github.com/pmj/QemuUSBTablet-OSX
- **pmj/virtio-net-osx:**
  - its README says other virtio device types would attach to the same `VirtioPCIDriver`;
  - a 2018 commit, "Part 1 of driver for standardised PCI Virtio devices", adds virtio capability detection and MSI/MSI-X interrupt enumeration, and pulls in pmj's kextgizmos helper library. https://github.com/pmj/virtio-net-osx
- **pmj/kextgizmos:** helpers for kext development. https://github.com/pmj/kextgizmos
- **QEMU's built-in SPICE agent host side:** QEMU 6.1+ implements the SPICE agent protocol as a chardev connected to QEMU's own clipboard, so copy/paste works without a SPICE client. Usage: `-chardev qemu-vdagent,id=vdagent -device virtserialport,chardev=vdagent,name=com.redhat.spice.0`. https://www.kraxel.org/blog/2021/05/qemu-cut-paste/
- **utmapp/vd_agent:** a macOS SPICE guest agent, clipboard only. Its build assumes Apple Silicon with Homebrew GLib in both architectures, so expect porting work for 10.9. https://github.com/utmapp/vd_agent
- **proxmox-mac-guest:** `mac-guest-agent` (a QEMU guest agent for macOS) runs over an ISA serial port; its `spice-vdagent` uses a separate virtio serial port. https://github.com/proxmox-mac-guest/spice-vdagent (find the agent repo from there)
- **litecreator/virtio-gpu-macos:** an alpha `virtio-gpu` IOFramebuffer driver. Targets 10.15+ ("untested on older versions"); the basic framebuffer works, cursor support is partial. https://github.com/litecreator/virtio-gpu-macos
- **VMsvga2** (https://sourceforge.net/projects/vmsvga2/, and QiuMike/VMsvga2ForQEMU) and **ivanagui2/VMQemuVGA**: open-source 10.9-era display drivers, already evaluated in the performance brief.
- **QEMU source:** `hw/display/vmware_vga.c` (for which VMware display commands QEMU actually implements, especially the cursor ones), `hw/display/virtio-gpu*.c`, `ui/vdagent.c`, and `qga/`.

## Ground rules
- Adopt and adapt before writing from scratch. Respect upstream licenses. Prefer contributing fixes back upstream over permanent forks.
- **Kernel code:**
  - build on 10.9 with a period-appropriate Xcode and SDK; record the exact versions;
  - test only on throwaway clones;
  - debug through QEMU's gdb stub (`-s`) with Apple's Kernel Debug Kit for the exact 10.9.x build (report if it can't be obtained);
  - never promote a kext to the golden image without an unload/reload test and a soak test.
- Verify, don't assume, how 10.9 handles unsigned kexts. Record whether `kext-dev-mode` or anything else is needed.
- User-space code: target the 10.9 SDK, avoid dependencies Mavericks can't satisfy, and keep daemons small and auditable. launchd plists go in the usual places.
- Ask before using `sudo` on the host, before any upstream contribution, and before starting any milestone marked **(approval)**.

## Milestones
**M0: Absolute pointer (no new code expected).**
- Install QemuUSBTablet-OSX (from source if practical) and switch to `-device usb-tablet`.
- Measure against the baseline: pointer lag, drift, the host↔guest cursor edge, and multi-hour stability.
- If it fails on 10.9: diagnose and fix it upstream-style. Only if that's hopeless, propose a `virtio-input` kext **(approval)**.

**M1: A host↔guest channel without kexts.**
- Test whether stock 10.9 drives QEMU's `isa-serial` and `pci-serial` devices. Check `ioreg`, look for `/dev/cu.*`/`/dev/tty.*`, and do a loopback echo test against a host-side chardev (socket or pty).
- Record which device works, if any, and its throughput and reliability.

**M2: A virtio-serial kext (only if M1 fails, or if M3 needs a named port) (approval).**
- Build on pmj's virtio PCI driver work and kextgizmos.
- Implement the virtio-serial device (virtio-console with multiport), exposing one `/dev` character device per named port, with port names discoverable (e.g. via `ioreg` properties).
- Soak test: sustained bidirectional transfer, host chardev reconnects, guest sleep/wake, unload/reload.

**M3: Clipboard over the SPICE agent protocol.**
- Host: QEMU's built-in agent chardev on the `com.redhat.spice.0` port, with QEMU's GTK or VNC display.
- Guest: port utmapp/vd_agent to 10.9, or write a minimal agent from the protocol spec. Clipboard only at first: text, then images.
  - Match the existing agent design: a system LaunchDaemon owns the port; a per-user LaunchAgent handles `NSPasteboard`.
- Document how the port device is found (M1's serial device or M2's kext).
- Test Unicode text, large text, images, and repeated fast copy/paste in both directions.

**M4: QEMU guest agent.**
- Evaluate proxmox-mac-guest's `mac-guest-agent` and QEMU's own agent (`qga/`) for building on 10.9.
- Needed: ping, guest info, graceful shutdown/reboot, network interfaces, exec, file read/write, time get/set.
- Transport: whatever M1 or M2 provided.
- Show a host-side script driving shutdown and exec. Note what this would mean for the GitHub Actions brief: host-driven control without SSH setup.
- Add time resync after snapshot restore/resume, here or in a small separate daemon.

**M5: Hardware cursor and resize-to-window in the existing display drivers.**
- First, audit which VMware cursor and mode commands QEMU's `vmware-svga` implements, from the source code.
- Then, in VMsvga2 or VMQemuVGA (pick one and justify it), add or fix:
  - a hardware cursor, so the host draws the pointer;
  - dirty-rectangle updates;
  - arbitrary display modes.
- Wire the SPICE agent's monitor-configuration messages (from M3's agent) to switch the guest display mode, so the guest follows the host window size.
- Measure the feel against M0's results.

**M6: Backport virtio-gpu to 10.9 (only if M5 hits limits in QEMU's device) (approval).**
- Assess litecreator/virtio-gpu-macos for 10.9: API use, SDK, and matching.
- Scope: a 2D framebuffer, change flushes, the cursor queue, and display-info events for host-driven resize.
- Prefer contributing 10.9 support upstream.

## Explicitly out of scope (and why)
- **3D acceleration (Quartz Extreme / Core Image):** it needs an IOAccelerator kext plus a user-space OpenGL renderer plugin and a host-side command stream. That's research-sized; passthrough is cheaper.
- **Shared folders:** use SMB, NFS, or sshfs over OSXFUSE instead of writing a 9p or virtiofs kext.
- **A virtio block driver:** AHCI is adequate for interactive feel.

## Deliverables
- Per milestone:
  - source (a fork or a new repo, as agreed);
  - build scripts for 10.9;
  - an installer package or install script;
  - a host-side QEMU flags fragment;
  - test scripts;
  - a section in `NOTES.md` with results against the baseline.
- `run.sh` profiles that enable each integration independently.
- **A final report covering:**
  - what was adopted vs. written;
  - what's stable enough for the golden image;
  - known bugs;
  - what can be contributed upstream;
  - which pieces are reusable for other OS X versions or for the GitHub Actions runner.

## Stop and ask if
- A kext panics in a way the throwaway clones and gdb can't isolate.
- A milestone marked (approval) is next.
- The Kernel Debug Kit or a period Xcode for 10.9 can't be obtained.
- Adopting a project would need a license-incompatible change, or a permanent fork.
- Any milestone takes more than about twice its initial estimate. Report before continuing.
