# Brief: OS X 10.9 Mavericks guest on QEMU/KVM (Linux Mint 22.3 host)

## Goal
A Mavericks 10.9.x guest that installs, completes first-boot setup, and reboots cleanly under plain `qemu-system-x86_64` with KVM. Everything must be reproducible from scripts in this directory, because the setup will later be generalized to other hosts. No libvirt/virt-manager unless plain QEMU proves impossible.

## Ground rules
- Read and adapt prior art. Don't invent from scratch. Sources, in priority order:
  1. **Adam Kostarelas, March 2026:** https://adam.kostarelas.com/blog/mavericks-in-utm-on-silicon/
     - The most recent *verified* 10.9 install on QEMU, done through UTM on Apple Silicon (TCG emulation, not KVM).
     - It uses OVMF + OpenCore, and the installer media is `get.sh`'s dmg.
     - His UTM bundle is at `.../Mavericks-OSX-10.9-Config.utm.zip` on that page. It contains the firmware and OpenCore images that worked.
  2. **Mykola Grymalyuk (khronokernel), 2021:** https://khronokernel.com/apple/silicon/2021/01/17/QEMU-AS.html
     - The guide Kostarelas followed: UTM settings, CPU flags, and troubleshooting.
     - Prebuilt OpenCore images are in `khronokernel/khronokernel.github.io` under `Binaries/OpenCore/`. `EFI-LEGACY.img` covers 10.6–10.14.
  3. **Gabriel Somlo's CMU page:** https://www.contrib.andrew.cmu.edu/~somlo/OSXKVM/
     - Chameleon + SeaBIOS on KVM; explicitly covers 10.9.
  4. **royalgraphx/DarwinKVM** on GitHub.
     - Has an OpenCore Mavericks guide under `installguides/11-Mavericks/`.
     - docs.darwinkvm.com currently serves a parked page, so read the source in the repo.
  5. **kholia/OSX-KVM**, for `OpenCore-Boot-macOS.sh` and the OpenCore image tooling.
     - Do NOT use its `fetch-macOS` script; it doesn't offer 10.9.
  6. **thenickdude/KVM-Opencore**, for OpenCore config details.
- If you can't fetch a source, say so. Don't guess its contents.
- **Prebuilt binaries: firmware and bootloader are fine, macOS images are not.**
  - Allowed as a known-good baseline: bootloader/firmware images from Kostarelas's UTM bundle and khronokernel's `Binaries/`. Record their checksums in `NOTES.md`.
  - Forbidden: any prebuilt macOS disk image from a third party, including khronokernel's `Catalina-SETUP.qcow2`. The OS comes from Apple only (see Step 1).
- Ask before using `sudo`, before installing packages, and before touching anything outside this directory.
- Keep `NOTES.md` as you go: every command line tried, what happened, panic text, and what fixed it. Failures are as valuable as successes.

## Preconditions to check and report first
- CPU vendor/model (`lscpu`). Intel is the documented KVM path; AMD is a known-harder case, so flag it and stop for instructions.
- `/dev/kvm` exists and is usable by the user.
- `qemu-system-x86_64 --version`, and the path to the OVMF firmware from the `ovmf` package.
- Likely packages: `qemu-system-x86 ovmf dmg2img hfsprogs kpartx gdisk rsync xxd openssl curl unzip`, plus `python3` for reading plists.
- `echo 1 > /sys/module/kvm/parameters/ignore_msrs` (sudo). Somlo and OSX-KVM both require it.

## Step 1: Get the installer
Mavericks Forever's `get.sh` (https://mavericksforever.com/get.sh) authenticates to osrecovery.apple.com, downloads `InstallESD.dmg` over HTTP, and checks its SHA-256. It **will not run on Linux as-is**: it requires `hdiutil` and exits if that's missing. The assembly half (merging `Packages` into `BaseSystem`) is macOS-only.

Kostarelas booted `get.sh`'s finished `InstallMacOSXMavericks.dmg`, converted to a raw image with `hdiutil convert -format UDTO`, directly under OVMF + OpenCore. So the target artifact is known to work: a raw image of that merged installer volume.

Pick one of these approaches:
- **A (Linux only; the default).**
  - **Download.** Copy `get.sh`'s download portion, through the SHA-256 verification, into `fetch-installesd.sh`. Stop before the first `hdiutil`; this part needs only curl, openssl, and xxd. Keep the checksum check.
  - **Assemble.** Follow eprigorodov/mkosxinstallusb (https://github.com/eprigorodov/mkosxinstallusb). It does the same merge as `get.sh` using Linux tools:
    - `dmg2img` + `kpartx`/`losetup -P` to mount InstallESD, then BaseSystem;
    - `mkfs.hfsplus -v "OS X Base System"` on the target;
    - `rsync -aAEHW` BaseSystem across;
    - remove `System/Installation/Packages`, then copy in the ESD's `Packages`, `BaseSystem.chunklist`, and `BaseSystem.dmg`.
  - **Retarget it.** That script writes to a `/dev/sdX`. Target a loop device over a raw image file instead, GPT with an AF00 partition sized like `get.sh`'s (about 6.6 GB).
  - **Verify it; a finished rsync proves nothing.** Linux hfsplus has at least one known problem: the script's README says Korean localization can be dropped. It's also unverified whether HFS+-compressed files in BaseSystem survive the copy. So:
    - compare file counts and sizes between the source and the copy;
    - check `dmesg` for hfsplus errors;
    - treat any "damaged package" or missing-file error in the installer as a likely copy problem, and log it.
- **B (fallback if A's image is broken): boot the pieces unmerged.**
  - Boot `base.img` with `esd.img` attached as a second disk; it should mount as "OS X Install ESD".
  - Check whether the stock installer finds its packages. `get.sh` removes `System/Installation/Packages` before copying, which suggests it's a link into the ESD volume. That's a hypothesis; verify it.
  - If it doesn't, use the installer's Terminal: format the target in Disk Utility, then run `installer -pkg "/Volumes/OS X Install ESD/Packages/OSInstall.mpkg" -target "/Volumes/<target>"`. Or do `get.sh`'s hdiutil/cp steps inside the guest, where Apple's tools exist.
- **C (if the user supplies a Mac or its output).** Run `get.sh` unmodified on a Mac, copy `InstallMacOSXMavericks.dmg` here, and `dmg2img` it. This is exactly the path Kostarelas proved, so use it as the known-good reference to diff against A's output.
- **Not recommended: OpenCore's `macrecovery.py`.**
  - Its 10.9 invocation is `-b Mac-F60DEB81FF30ACF6 -m 00000000000FNN100`. It fetches only a recovery image, which needs internet inside the guest to install. It is not offline media.
  - Try it only if A–C all fail. Nobody here has verified that Mavericks online reinstall still works against Apple's servers.
- **Don't use gibMacOS.** Its catalogs don't reach 10.9. Beware lookalike "gibMacOS" sites; corpnewt/gibMacOS on GitHub is the only real one.

## Step 2: Boot path
Start with the known-good configuration, then move toward components built or chosen yourself.
- **2a. Reproduce Kostarelas's setup under KVM (the default).**
  - **Unpack.** Download and unzip his UTM bundle. A `.utm` is a directory containing `config.plist` plus images.
  - **Record.** Parse `config.plist` and write down every setting in `NOTES.md`: architecture, machine type, CPU model and flags, extra QEMU arguments, memory, core count, every drive (interface and image type), NIC model, and display device.
    - Nobody has inspected this bundle for this brief. Report what's actually in it.
  - **Translate** those settings into a plain `qemu-system-x86_64` command line.
    - Keep his OVMF and OpenCore images.
    - Swap TCG for `-enable-kvm`, and set `-cpu` so KVM accepts it.
- **2b. Swap in stock components, one at a time, once 2a works.**
  - **Firmware.** Replace his OVMF with Mint's `ovmf` package.
    - He notes his OVMF is about 5 years old: it "just worked", and a current build was untested.
    - If the stock one fails, log how, and keep the old one pinned (with its checksum) for now.
  - **Bootloader.** Try khronokernel's `EFI-LEGACY.img` too, then an OpenCore image built from current OpenCorePkg release sources, following DarwinKVM's Mavericks config.
    - OVMF can't read HFS+, so every OpenCore image needs an HFS+ driver (`OpenHfsPlus.efi` or `HfsPlus.efi`).
  - The endpoint is a bootloader you can rebuild from source. That is what generalization needs.
- **2c. Chameleon + SeaBIOS (Somlo), the fallback if OpenCore fails under KVM.**
  - `-kernel <chameleon boot file>` plus `-smbios type=2`.
  - The Chameleon binary Somlo links may be gone. If so, report it; don't substitute a random build.

## Step 3: Starting QEMU flags (the UTM bundle wins wherever it disagrees; log every change)
- **Machine and cores:** `-enable-kvm -machine q35 -m 4096 -smp 2`.
  - **Keep SMP for the first boot after install.** Somlo reports that 10.9 first boot fails without it. khronokernel also found multicore much faster under TCG.
  - Kostarelas's template used 8 GB; 10.9 idled at about 2.9 GB. So 4 GB is fine to start.
- **CPU:** in order of preference:
  1. whatever the bundle specifies;
  2. khronokernel's `Penryn,+ssse3,+sse4.1,+sse4.2,+popcnt,+xsave,+xsaveopt,check` plus `vendor=GenuineIntel`;
  3. Somlo's `core2duo,vendor=GenuineIntel`.
- **SMC:** `-device isa-applesmc,osk=...`, taking the OSK value from OSX-KVM's `OpenCore-Boot-macOS.sh`.
  - khronokernel's settings list has no applesmc device, which suggests his OpenCore image emulates the SMC itself. Check the bundle and the OpenCore config before adding it, and note which you rely on.
- **Disks:**
  - Try the q35 AHCI controller first: a qcow2 target of 40G or more, plus the installer image.
  - khronokernel attached EFI, installer, and target disks all over USB. If AHCI disks don't show up in the OpenCore picker or the installer, switch to `usb-storage`.
- **Network:**
  - Try `e1000-82545em` first; DarwinKVM specifies it for 10.9.
  - khronokernel used vmxnet3 in UTM. Try it if the e1000 fails.
- **Input:** `-usb -device usb-kbd -device usb-mouse` (Somlo), then `usb-tablet`. If the mouse is dead under OpenCore, khronokernel suggests Ctrl+Option+arrows.
- **Display:** Kostarelas saw about 3 MB of VRAM. Chess, Launchpad, and video were slideshows, and UTM wouldn't pass a parameter to fix it.
  - Plain QEMU can: try `-device VGA,vgamem_mb=64` (or larger) and record whether 10.9 sees more VRAM and gets more resolutions.
  - Don't expect acceleration.

## Step 4: Post-install (ask before running anything inside the guest)
- **Network in the guest.**
  - If DNS doesn't work, set the resolver to a public one; Kostarelas needed 1.1.1.1.
  - In the installer environment, khronokernel's `scutil` recipe (`d.init` / `d.add ServerAddresses * ...` / `set State:/Network/Service/PRIMARY_SERVICE_ID/DNS`) does the same.
  - For any error contacting Apple servers, check the guest clock first.
- **Updates and hardening.** Kostarelas recommends Apple's 2016 security update and Mavericks Forever's optional post-install hardening script. List what they would change and wait for approval.
- **Record what works and what doesn't:** sound, resolution changes, sleep, shutdown, and the Safari/TLS limitations (he found the modern web mostly broken in the stock Safari).

## Deliverables
- **Scripts:** `fetch-installesd.sh`, `build-installer-img.sh` (the retargeted mkosxinstallusb logic, with its verification), `build-opencore.sh` (once you've moved past the bundle's image), `run-install.sh`, `run.sh`.
- **`NOTES.md`**, including the full contents of the UTM bundle's `config.plist` and the checksums of every third-party binary used.
- **A final report covering:**
  - the exact working command line and firmware/bootloader versions;
  - which installer approach worked (A/B/C, plus the verification results for A) and which boot path (2a/2b/2c);
  - which third-party binaries are still required, and why;
  - known broken items (graphics/VRAM, sound, resolution, sleep, etc.);
  - every host-specific assumption. These are what generalization will have to replace. For later versions, adespoton/utmconfigs on GitHub is the analogous config collection.

## Stop and ask if
- The host is AMD.
- The Apple download fails or the checksum mismatches.
- The UTM bundle, khronokernel's images, or another required upstream artifact (Chameleon binary, DarwinKVM Mavericks config) is unavailable.
- Three materially different attempts at the same stage all fail.
