# Brief: Interactive performance for the OS X 10.9 guest on QEMU/KVM (Linux Mint 22.3 host)

## Goal
Make the working Mavericks guest from `mavericks-qemu-brief.md` pleasant to use interactively. Every change must be measured, reversible, and scripted. This is tuning, not re-bring-up: start from the known-good command line and change one thing at a time.

## Context
- Without a GPU that 10.9 has drivers for, the guest has no Quartz Extreme or Core Image acceleration: the CPU draws everything. Expect gains from CPU tuning and from reducing work, not miracles.
- Real acceleration requires passthrough of a physical GPU (Phase 5). Everything else is incremental.
- Known prior art, all of which needs verifying here:
  - **pmj/virtio-net-osx 0.9.4:** known to work on 10.7–10.9 under QEMU/KVM, per its README. In VirtualBox it measured about 2× faster TCP sending and 4× faster receiving than the emulated Intel NIC. Somlo also confirmed it on 10.9. https://github.com/pmj/virtio-net-osx
  - **ivanagui2/VMQemuVGA:** its release notes say it should work from 10.6 through 10.10. They only mention VirtualBox, despite the name. https://github.com/ivanagui2/VMQemuVGA
  - **VMsvga2** (for VMware's display device): covers 10.5+ but was abandoned in 2014 in favor of VMware's own driver. QiuMike/VMsvga2ForQEMU adapted it to macOS Catalina on QEMU/KVM, which shows it can work against QEMU's device, though far newer than 10.9. https://sourceforge.net/projects/vmsvga2/ and https://github.com/QiuMike/VMsvga2ForQEMU
  - **Stock QEMU `vmware-svga`** implements VMware's display device minimally: most 2D acceleration commands are missing and there's no 3D, per the README of the qemus/qemu-vmvga fork. That fork adds 3D through DXVK/Vulkan, but it targets Windows guests, and KVM needs `enable_vmware_backdoor=Y` for it. https://github.com/qemus/qemu-vmvga
  - **Docker-OSX issue #867** (2025) asks for VMware's graphics driver plus `vmware-svga` with more VRAM, unresolved. Nobody has this working off the shelf.
  - **steelbrain/reims-vgpu** does NOT apply: it needs macOS 11+ guests with Metal. Its per-guest golden snapshots with throwaway clones are worth copying, though: use them for every experiment here.

## Ground rules
- Study prior art before inventing anything. If you can't fetch a source, say so; don't guess its contents.
- Take a golden snapshot of the working guest first (disk-level copy-on-write clone). Every experiment runs on a throwaway clone. Changes are promoted to a new golden only after measurement and user approval.
- One variable per experiment. Record the exact command line, guest changes, and results in `NOTES.md`.
- Third-party kexts (VMQemuVGA, VMsvga2, virtio-net): download from the original repos only. Record checksums. Prefer building from source when practical, and log any build changes needed for 10.9.
- Ask before using `sudo`, changing the host kernel command line or module options, rebooting the host, binding devices to vfio-pci, or buying/installing hardware.

## Phase 0: Baseline measurements
- **A repeatable benchmark script**, run in the guest over SSH where possible, measuring:
  - cold boot to SSH-ready (host-side timer);
  - login to a usable desktop;
  - time to launch Safari, TextEdit, and Terminal (cold and warm);
  - window drag/resize smoothness and Mission Control responsiveness. Capture these as screen recordings or frame-time estimates from the host side; describe the method used.
  - a CPU benchmark and a disk throughput test (e.g. `dd` with sensible block sizes, noting caching effects);
  - network throughput with `iperf3` (build it for 10.9 if needed, and log how).
- **Qualitative notes:** is the pointer laggy? Are there tearing or redraw artifacts?
- Every later phase reports against this baseline.

## Phase 1: CPU and memory
- **CPU models:** compare the current model against newer models 10.9 supports natively. Start with `Haswell-noTSX` plus `+invtsc` (as OSX-KVM uses), then try others.
  - If 10.9 panics on a model, try OpenCore's `Cpuid1Data`/`Cpuid1Mask` to make it report a supported CPU while keeping the newer instruction sets. Log the exact settings.
- **vCPU count and pinning:** 2, 4, and 6 vCPUs, pinned to physical cores (not SMT siblings); topology via `-smp`. Record the host's topology.
- **Memory:** 4 GB vs 8 GB. Hugepages on vs off.
- **Host:** CPU governor `performance` vs the default. Record which cores Mint's desktop is using.
- **Timekeeping:** confirm the guest clock stays stable and there's no TSC-related stutter.

## Phase 2: Storage and network
- **Disk:** raw vs qcow2, `cache=none` vs the default, `aio=io_uring` vs `native` vs `threads`. Stay on AHCI (no known 10.9 virtio block driver; confirm, don't assume).
- **Network:** install pmj/virtio-net-osx 0.9.4 and switch to `virtio-net-pci`. Compare with the current e1000 variant using `iperf3`.
  - Check kext load behavior on 10.9, and whether signing or `kext-dev-mode` is needed. My belief (unverified) is that 10.9 only warns about unsigned kexts.
  - Keep the e1000 as a fallback until virtio proves stable over a multi-hour transfer and a sleep/wake or snapshot cycle.

## Phase 3: Reduce guest work
- **Apply one at a time and measure:**
  - disable window animations (`NSAutomaticWindowAnimationsEnabled`);
  - disable the Dock launch animation (`launchanim`) and shorten Mission Control animation (`expose-animation-duration`);
  - shorten window resize time (`NSWindowResizeTime`);
  - disable Dashboard;
  - turn off Spotlight indexing (`mdutil -a -i off`) *only if the user agrees*;
  - disable unneeded login items and agents.
- **Resolution and color depth:** compare 1280×800, 1440×900, and 1920×1080.
- **Deliverable:** one script that applies the approved set, and one that reverts it.

## Phase 4: Display device, driver, and transport
- **Stock devices:**
  - `-vga std`: try different `vgamem_mb` values. Record which resolutions 10.9 offers and whether it sees the extra VRAM.
  - `-device vmware-svga`: without a driver, as a baseline.
- **VMQemuVGA:**
  - on `-vga std` and on `vmware-svga`;
  - record: loads cleanly? which resolutions? any 2D speedup? any artifacts?
- **VMsvga2:**
  - on `vmware-svga`, using the original and the QiuMike QEMU variant (rebuilt for 10.9 if necessary);
  - record the same things.
- **Only if the user approves the extra work:** a quick feasibility check of qemus/qemu-vmvga with VMsvga2's 3D path (needs `enable_vmware_backdoor`). Stop after one day of effort and report.
- **Pointer:** `usb-tablet` vs `usb-mouse`. Record lag, drift, and whether 10.9 handles absolute positioning.
- **Transport:** compare QEMU's local display (GTK vs SDL), QEMU's VNC server, and 10.9's built-in Screen Sharing reached over the network. Report which *feels* fastest, with whatever measurement you can justify.

## Phase 5: GPU passthrough (plan only, unless the user says go)
- **Survey the host:** CPU and chipset IOMMU support, IOMMU groups (`find /sys/kernel/iommu_groups`), free PCIe slots, power supply, and whether the host has its own display output (e.g. an iGPU) or needs a second card.
- **Research GPUs** that 10.9 drives natively with no extra kexts (likely NVIDIA Kepler and AMD Radeon HD 7000-class, but verify each exact model against 10.9 driver lists and real reports). Prefer cheap used cards with clean IOMMU grouping and known passthrough behavior.
  - Read DarwinKVM's GPU/passthrough documentation first (repo source, since docs.darwinkvm.com was parked).
- **Write `PASSTHROUGH-PLAN.md`:**
  - candidate cards, with evidence;
  - required host kernel parameters and `vfio-pci` binding;
  - any GPU ROM (vBIOS) handling;
  - OpenCore changes;
  - display arrangement (second monitor, KVM switch, or capture);
  - risks and the rollback steps.
- **Don't touch host boot configuration** until the user approves the plan.

## Deliverables
- `bench/`: the benchmark scripts.
- `run.sh`, updated with the approved tuning; old variants are kept as named profiles.
- Guest tweak apply/revert scripts.
- Kext install notes, with checksums and build logs.
- `NOTES.md`: every experiment and result.
- `PASSTHROUGH-PLAN.md`.
- **A final report covering:**
  - a baseline-vs-tuned table;
  - what helped, what didn't, and what broke;
  - the recommended default configuration;
  - which recommendations are specific to this host (CPU topology, IOMMU groups), since those matter for generalization.

## Stop and ask if
- A kext causes panics that the throwaway clone can't isolate.
- Any change requires host kernel or boot changes.
- A phase produces no measurable improvement after its planned experiments. Report before inventing new ones.
- Passthrough looks feasible and hardware would need to be acquired.
