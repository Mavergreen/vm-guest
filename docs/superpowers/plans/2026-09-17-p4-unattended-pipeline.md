# P4: Unattended Image Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command, from a clean checkout, produces a bootable SSH-reachable Mavericks qcow2 with no human interaction — including building the installer media on Linux, without a Mac.

**Architecture:** Fetch Apple's `InstallESD.dmg` with the download half of Mavericks Forever's `get.sh` (curl/openssl/xxd only, no `hdiutil`). Assemble bootable media the way `eprigorodov/mkosxinstallusb` does, but entirely unprivileged — `udisksctl` provides loop devices and HFS+ mounts without root. Drive the install by injecting a LaunchDaemon into the media's own installer environment, so it runs `installer -pkg OSInstall.mpkg` and reboots with no GUI interaction. A first-boot payload on the target volume then creates the user, installs SSH keys, and skips Setup Assistant.

**Tech Stack:** bash, bats-core, `dmg2img`, `mkfs.hfsplus`, `udisksctl` (udisks2), `rsync`, `sgdisk`, `7z`, QEMU 8.2.2 + KVM, Python 3 `plistlib`.

**Spec:** `docs/superpowers/specs/2026-09-17-mavericks-guest-design.md`, section "P4 — Unattended pipeline (goal #2)". Read also the P4 entries in `NOTES.md` (the rootless finding), `docs/install-log.md` (the click-log this automates), and `docs/decisions/0004-p3-boot-stack-provenance.md`.

## Global Constraints

- **The OS comes from Apple only.** Firmware and bootloaders may be third-party; macOS images may not. `InstallESD.dmg` is fetched from Apple's own servers and SHA-256 verified.
- **Never publish the guest image.**
- **`./bin/run-tests.sh` must pass, including `bin/tier-check.sh --strict`.** The boot stack stays Tier 0.
- **Everything under `${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}`**, never in the repo — it is NFS at ~18 ms per file create.
- **No root, no sudo.** P4's probe established that the whole media pipeline runs unprivileged. If something appears to need root, that is a finding to report, not a reason to reach for sudo.
- **Ask before** installing host packages, host config changes, or anything outside this directory.
- **Prior art has a date.** Re-test rather than inherit; two of this project's inherited claims have already been disproven.
- Commit messages end with:
  `Co-Authored-By: <your model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01FoKSUe9s8WEdm1b1P4epUx`

## What P4 starts from

- Golden #1 (`p2-manual-install`): a working 10.9.5, installed by hand.
- `p3-full`: boots it **unattended** on a Tier 0 boot stack (OpenCore 1.0.7 and OVMF both built offline from pinned source).
- `$MQG_IMAGE_DIR/media/InstallMavericks.iso`: the **reference** media, produced by `get.sh` on a Mac. sha256 `e3d62494…`. This is what a Linux-built image gets diffed against — the reason Approach C ran first.
- `docs/install-log.md`: every screen and click of the manual install. **That document is this plan's specification.**

## The two things P4 must prove

1. **That media can be built on Linux.** If the Linux-built image will not boot, the reference image tells us whether the media or the configuration is at fault. That is the whole reason it exists.
2. **That the install can run with nobody watching.** Unproven. Task 5 is the risk.

---

## File structure

| Path | Responsibility |
|---|---|
| `media/fetch-installesd.sh` | Downloads `InstallESD.dmg` from Apple, SHA-256 verified. |
| `lib/hfs.sh` | Unprivileged HFS+ image handling: create, loop-attach, mount, unmount, detach. Cleans up on failure. |
| `media/build-installer-img.sh` | Assembles bootable installer media from `InstallESD.dmg`. |
| `media/verify-installer-img.sh` | Diffs a built image against the Mac-produced reference. |
| `image/autoinstall/com.mqg.autoinstall.plist` | The LaunchDaemon injected into the installer environment. |
| `image/autoinstall/autoinstall.sh` | What that daemon runs: partition, install, reboot. |
| `image/payload/firstboot.sh` | Runs once on the installed system: user, SSH, Setup Assistant, sleep, updates. |
| `image/build-image.sh` | The orchestrator. Idempotent, resumable, emits a checksummed qcow2 plus a manifest. |
| `tests/hfs.bats`, `tests/media.bats`, `tests/payload.bats` | Tests for the above. |

---

## Task 1: `lib/hfs.sh` — unprivileged HFS+ image handling

**Files:** Create `lib/hfs.sh`; Test `tests/hfs.bats`

**Interfaces:**
- Produces: `hfs_create <path> <size-mib> <volname>`, `hfs_attach <path>` (prints the loop device), `hfs_mount <loopdev>` (prints the mountpoint), `hfs_unmount <loopdev>`, `hfs_detach <loopdev>`, and `hfs_with_mounted <path> <shell-function>` which attaches, mounts, runs, and always cleans up. Tasks 2 and 5 use these.

Every later media task depends on this, and a leaked loop device or mount is the kind of mess that accumulates silently across a debugging session.

- [ ] **Step 1: Write the failing test**

Create `tests/hfs.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/hfs.sh"
    IMG="$BATS_TEST_TMPDIR/t.img"
}

teardown() {
    # Never leave a loop device behind, even if a test failed mid-way.
    if [ -n "${LOOPDEV:-}" ]; then
        hfs_unmount "$LOOPDEV" 2>/dev/null || true
        hfs_detach "$LOOPDEV" 2>/dev/null || true
    fi
}

@test "hfs_create makes a mountable HFS+ image with the requested volume name" {
    hfs_create "$IMG" 32 MQGTEST
    [ -f "$IMG" ]
    run file "$IMG"
    [[ "$output" == *"Macintosh HFS Extended"* ]] || [[ "$output" == *"HFS+"* ]]
}

@test "hfs_create refuses to clobber an existing image" {
    hfs_create "$IMG" 32 MQGTEST
    run hfs_create "$IMG" 32 MQGTEST
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
}

@test "attach, mount, write, read back, unmount, detach" {
    hfs_create "$IMG" 32 MQGTEST
    LOOPDEV=$(hfs_attach "$IMG")
    [[ "$LOOPDEV" == /dev/loop* ]]
    MNT=$(hfs_mount "$LOOPDEV")
    [ -d "$MNT" ]
    printf 'hello hfs\n' > "$MNT/greeting.txt"
    run cat "$MNT/greeting.txt"
    [ "$output" = "hello hfs" ]
    hfs_unmount "$LOOPDEV"
    run mount
    [[ "$output" != *"$MNT"* ]]
    hfs_detach "$LOOPDEV"
    LOOPDEV=""
}

@test "hfs_with_mounted cleans up even when the body fails" {
    hfs_create "$IMG" 32 MQGTEST
    body_that_fails() { return 3; }
    run hfs_with_mounted "$IMG" body_that_fails
    [ "$status" -ne 0 ]
    # Nothing of ours should still be attached to this image.
    run bash -c "losetup -a 2>/dev/null | grep -c '$IMG' || true"
    [ "$output" = "0" ]
}

@test "hfs_with_mounted passes the mountpoint to the body" {
    hfs_create "$IMG" 32 MQGTEST
    body_writes() { printf 'ok\n' > "$1/written.txt"; }
    hfs_with_mounted "$IMG" body_writes
    LOOPDEV=$(hfs_attach "$IMG")
    MNT=$(hfs_mount "$LOOPDEV")
    run cat "$MNT/written.txt"
    [ "$output" = "ok" ]
    hfs_unmount "$LOOPDEV"; hfs_detach "$LOOPDEV"; LOOPDEV=""
}

@test "hfs_attach fails clearly for a file that is not an HFS+ image" {
    printf 'not an image\n' > "$BATS_TEST_TMPDIR/bogus.img"
    run hfs_attach "$BATS_TEST_TMPDIR/bogus.img"
    # Attaching may succeed; mounting must not. Either way, no silent success.
    if [ "$status" -eq 0 ]; then
        LOOPDEV="$output"
        run hfs_mount "$LOOPDEV"
        [ "$status" -ne 0 ]
    fi
}
```

- [ ] **Step 2: Run it, confirm it fails** — `bats tests/hfs.bats`, `lib/hfs.sh` does not exist.

- [ ] **Step 3: Implement `lib/hfs.sh`**

```bash
# shellcheck shell=bash
# Unprivileged HFS+ image handling.
#
# The design assumed this needed sudo for losetup and mount. It does not:
# mkfs.hfsplus operates on a plain file, and udisks2 provides loop devices
# and mounts to a desktop user without a password, auto-loading the hfsplus
# module. See the P4 entry in NOTES.md.
#
# Requires lib/common.sh.

hfs_create() {
    local img=$1 mib=$2 volname=$3
    [ ! -e "$img" ] || die "image already exists: $img"
    require_cmd mkfs.hfsplus truncate
    truncate -s "${mib}M" "$img"
    mkfs.hfsplus -v "$volname" "$img" >/dev/null \
        || die "mkfs.hfsplus failed on $img"
}

# Prints the loop device.
hfs_attach() {
    local img=$1 out
    [ -f "$img" ] || die "no such image: $img"
    require_cmd udisksctl
    out=$(udisksctl loop-setup -f "$img" --no-user-interaction 2>&1) \
        || die "loop-setup failed for $img: $out"
    # "Mapped file <path> as /dev/loopN."
    printf '%s\n' "$out" | grep -oE '/dev/loop[0-9]+' | head -1
}

# Prints the mountpoint.
hfs_mount() {
    local dev=$1 out
    out=$(udisksctl mount -b "$dev" --no-user-interaction 2>&1) \
        || die "mount failed for $dev: $out"
    # "Mounted /dev/loopN at /media/user/VOLNAME"
    printf '%s\n' "$out" | sed -n 's/.* at \(.*\)$/\1/p' | sed 's/\.$//'
}

hfs_unmount() {
    local dev=$1
    udisksctl unmount -b "$dev" --no-user-interaction >/dev/null 2>&1 \
        || warn "unmount reported failure for $dev"
}

hfs_detach() {
    local dev=$1
    # loop-delete wants a polkit agent and fails from a non-interactive
    # shell. The device detaches when its backing file goes away, so a
    # failure here is noted, not fatal.
    udisksctl loop-delete -b "$dev" --no-user-interaction >/dev/null 2>&1 \
        || warn "loop-delete reported failure for $dev (often harmless)"
}

# hfs_with_mounted <img> <function-name> [args...]
# Calls <function-name> <mountpoint> [args...], then always cleans up.
hfs_with_mounted() {
    local img=$1 body=$2
    shift 2
    local dev mnt rc=0
    dev=$(hfs_attach "$img") || return 1
    mnt=$(hfs_mount "$dev") || { hfs_detach "$dev"; return 1; }
    "$body" "$mnt" "$@" || rc=$?
    sync
    hfs_unmount "$dev"
    hfs_detach "$dev"
    return "$rc"
}
```

- [ ] **Step 4: Run the tests, confirm 6 pass.**

- [ ] **Step 5: Confirm no leaks after the suite**

Run: `losetup -a | wc -l` before and after `bats tests/hfs.bats`. The counts must match. If they do not, `hfs_with_mounted`'s cleanup is wrong — fix it before going further, because every later task leans on it.

- [ ] **Step 6: Commit**

```bash
git add lib/hfs.sh tests/hfs.bats
git commit -m "Add unprivileged HFS+ image handling

The design assumed losetup and mount needed sudo. They do not:
mkfs.hfsplus works on a plain file and udisks2 gives a desktop user loop
devices and mounts without a password.

hfs_with_mounted always cleans up, including when its body fails, and a
test asserts that. A leaked loop device is the kind of mess that
accumulates silently across a debugging session.

Co-Authored-By: <your model name> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01FoKSUe9s8WEdm1b1P4epUx"
```

---

## Task 2: Fetch `InstallESD.dmg` from Apple

**Files:** Create `media/fetch-installesd.sh`; Modify `vendor/sources.tsv`; Test `tests/media.bats`

**Interfaces:**
- Produces: `$MQG_IMAGE_DIR/media/InstallESD.dmg`, SHA-256 verified. Task 3 consumes it.

Mavericks Forever's `get.sh` authenticates to `osrecovery.apple.com`, downloads over HTTP and verifies a SHA-256. **The download half needs only `curl`, `openssl` and `xxd`** — it stops before the first `hdiutil`. Lift that half; do not lift the assembly half, which is macOS-only and is what Task 3 replaces.

- [ ] **Step 1: Read the current `get.sh` before writing anything**

Fetch <https://mavericksforever.com/get.sh> and read it. **Do not guess at its protocol.** Record in `NOTES.md`: the exact endpoints, what the session handshake looks like, and the expected SHA-256 of `InstallESD.dmg`. If the site is unreachable, **stop and report** — that is a stop-and-ask condition, and the reference ISO means P4 is not blocked on it for testing Tasks 4 onward.

- [ ] **Step 2: Write the failing test**

Create `tests/media.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "fetch-installesd.sh prints the checksum it expects, without fetching" {
    run "$REPO/media/fetch-installesd.sh" --show-expected
    [ "$status" -eq 0 ]
    # A sha256 is 64 hex characters.
    [[ "$output" =~ [0-9a-f]{64} ]]
}

@test "fetch-installesd.sh refuses to run without the tools it needs" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for t in bash dirname; do ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"; done
    run env PATH="$BATS_TEST_TMPDIR/bin" "$REPO/media/fetch-installesd.sh" --show-expected
    # --show-expected must work without curl; the fetch path must not.
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Implement**, following `boot/fetch-opencorepkg.sh`'s shape: `--show-expected` prints the pinned checksum and exits without touching the network; the fetch path `require_cmd curl openssl xxd`, downloads to `$MQG_IMAGE_DIR/media/InstallESD.dmg.part`, verifies with `verify_sha256` before renaming into place, and is idempotent — an already-present verified file is left alone.

**The checksum is the point.** A partial or substituted download that gets renamed anyway would poison everything downstream. Verify before rename, never after.

- [ ] **Step 4: Run it for real.** Record the wall-clock time and size in `NOTES.md`. If Apple's checksum does not match, **stop and report** — a stop-and-ask condition.

- [ ] **Step 5: Commit**, adding the pinned checksum to `vendor/sources.tsv`.

---

## Task 3: Build installer media on Linux

**Files:** Create `media/build-installer-img.sh`; Test `tests/media.bats`

**Interfaces:**
- Consumes: `lib/hfs.sh`'s functions; `$MQG_IMAGE_DIR/media/InstallESD.dmg`.
- Produces: `$MQG_IMAGE_DIR/media/installer-linux.img` — a GPT image with one HFS+ partition named `OS X Base System`, checksummed. Tasks 4 and 5 consume it.

This is installer Approach A, following `eprigorodov/mkosxinstallusb` but unprivileged and targeting an image file rather than `/dev/sdX`.

The shape, from the design:

1. `dmg2img` `InstallESD.dmg` → a raw image.
2. Attach and mount it. Inside is `BaseSystem.dmg`, plus a `Packages` directory.
3. `dmg2img` `BaseSystem.dmg` → raw; attach and mount that too.
4. Create the target: GPT, one `AF00` (Apple HFS+) partition, volume name `OS X Base System`, sized from the reference — the Mac-produced ISO's partition is 6.55 GB, so size from that rather than guessing.
5. `rsync` BaseSystem's contents onto the target.
6. Remove `System/Installation/Packages` (a symlink into the ESD volume) and replace it with the ESD's real `Packages` directory, plus `BaseSystem.chunklist` and `BaseSystem.dmg`.

**The ownership question, which the P4 probe flagged.** udisks2 mounts as the invoking user, so `rsync -a` cannot preserve root ownership. `mkosxinstallusb` uses `rsync -aAEHW`. **Try it without root first and see whether the installer cares.** It runs as root and may rebuild what it needs. Only if a boot actually fails for ownership reasons is this worth escalating — and then it is a finding to report, not a `sudo` to add quietly.

- [ ] **Step 1: Write the failing test**

Append to `tests/media.bats`:

```bash
@test "build-installer-img.sh reports the layout it will create" {
    run "$REPO/media/build-installer-img.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"OS X Base System"* ]]
    [[ "$output" == *"AF00"* ]]
}

@test "build-installer-img.sh fails clearly without InstallESD.dmg" {
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/empty" \
        "$REPO/media/build-installer-img.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"InstallESD"* ]]
}

@test "build-installer-img.sh refuses to clobber an existing image" {
    mkdir -p "$BATS_TEST_TMPDIR/img/media"
    : > "$BATS_TEST_TMPDIR/img/media/InstallESD.dmg"
    : > "$BATS_TEST_TMPDIR/img/media/installer-linux.img"
    run env MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/img" \
        "$REPO/media/build-installer-img.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exists"* ]]
}
```

- [ ] **Step 2: Run it, confirm it fails.**

- [ ] **Step 3: Implement it**, using `hfs_with_mounted` for every mount so nothing leaks. Support `--describe` (print the intended layout, touch nothing) and `--force` (replace an existing output). Use `sgdisk` for the GPT and `-t 1:AF00`.

Log each stage with `log`, and record byte counts as you go — a `rsync` that silently copies nothing is exactly the failure Task 4 exists to catch, and having the numbers in `run.log` makes it obvious.

- [ ] **Step 4: Build it for real.** Record wall-clock time, the resulting size, and the checksum in `NOTES.md`.

- [ ] **Step 5: Commit.**

---

## Task 4: Verify the Linux-built media against the Mac-produced reference

**Files:** Create `media/verify-installer-img.sh`; Test `tests/media.bats`

**Interfaces:**
- Consumes: both images.
- Produces: a report, and a non-zero exit if the built image is missing anything the reference has.

**A finished `rsync` proves nothing.** This task is the reason the reference image was made first, and the design is explicit about what to check.

Compare, between `installer-linux.img` and `InstallMavericks.iso`:

- **File counts and total sizes** per top-level directory.
- **Every path present in the reference but absent from the build** — the real output of this script. There should be none.
- **The specific files the install depends on**: `System/Library/CoreServices/boot.efi`, `System/Installation/Packages/OSInstall.mpkg`, `System/Installation/BaseSystem.dmg`, `System/Installation/BaseSystem.chunklist`, and all 16 packages.
- **HFS+ compression fidelity.** `mkosxinstallusb`'s README warns that Korean localization can be dropped, and whether HFS+-compressed files survive a Linux `rsync` is explicitly unverified. Compare sizes of a sample of compressed files; a decompressed copy is *larger* on disk, so a size mismatch in that direction is the signal.
- **`dmesg | tail` for `hfsplus` errors** after the build.

Both images can be read with `7z l` without mounting, which makes the comparison cheap and root-free. The reference is an ISO with an Apple Partition Map, the build is GPT — so compare *volume contents*, not raw layout.

- [ ] **Step 1: Write the failing test**

```bash
@test "verify-installer-img.sh reports missing files as a failure" {
    # Two trees, one deliberately missing a file.
    mkdir -p "$BATS_TEST_TMPDIR/a/System/Installation" "$BATS_TEST_TMPDIR/b/System/Installation"
    printf 'x\n' > "$BATS_TEST_TMPDIR/a/System/Installation/OSInstall.mpkg"
    run "$REPO/media/verify-installer-img.sh" --compare-trees \
        "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    [ "$status" -ne 0 ]
    [[ "$output" == *"OSInstall.mpkg"* ]]
}

@test "verify-installer-img.sh passes for identical trees" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    printf 'x\n' > "$BATS_TEST_TMPDIR/a/f"; printf 'x\n' > "$BATS_TEST_TMPDIR/b/f"
    run "$REPO/media/verify-installer-img.sh" --compare-trees \
        "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    [ "$status" -eq 0 ]
}

@test "verify-installer-img.sh names the files an install cannot proceed without" {
    run "$REPO/media/verify-installer-img.sh" --required
    [ "$status" -eq 0 ]
    [[ "$output" == *"boot.efi"* ]]
    [[ "$output" == *"OSInstall.mpkg"* ]]
    [[ "$output" == *"BaseSystem.dmg"* ]]
}
```

- [ ] **Step 2: Run it, confirm it fails. Step 3: Implement. Step 4: Run the tests.**

- [ ] **Step 5: Compare the real images and write up the result**

Run it and put the output in `NOTES.md` verbatim, whatever it says. **If the Linux build is missing files, that is the headline finding of P4** and needs reporting before anything is built on top of it.

- [ ] **Step 6: Commit.**

---

## Task 5: Make the install run with nobody watching

**Files:** Create `image/autoinstall/com.mqg.autoinstall.plist`, `image/autoinstall/autoinstall.sh`; Modify `media/build-installer-img.sh`; Test `tests/payload.bats`

**Interfaces:**
- Consumes: the built installer image; `lib/hfs.sh`.
- Produces: an installer image that, when booted, partitions the target and installs without interaction. Task 8's orchestrator depends on it.

**This is P4's risk.** Everything else is mechanical.

**The mechanism, established by inspecting the media.** The booted installer environment *is* the media volume — it carries 84 LaunchDaemons at `System/Library/LaunchDaemons/` and `OSInstall.mpkg` at `System/Installation/Packages/`. So a LaunchDaemon injected into the media volume runs in the installer environment at boot. **No need to open `BaseSystem.dmg`.**

`image/autoinstall/autoinstall.sh` should, using only tools present in the installer environment (`diskutil`, `installer`, `/usr/bin/*` — do not assume anything else):

1. Wait for the target disk to appear.
2. `diskutil partitionDisk` it: **GPT**, one `JHFS+` partition named `Mavericks`. The click-log is emphatic that APM will not boot under OpenCore/UEFI, and that it is invisible until after a full install.
3. `installer -pkg /System/Installation/Packages/OSInstall.mpkg -target /Volumes/Mavericks`.
4. Drop the first-boot payload (Task 6) onto the target volume.
5. `shutdown -r now`.

Log every step to a file on the target volume, so a failed run can be diagnosed without watching it.

**Identify the target disk carefully.** Do not hardcode `/dev/disk0` — the installer media, the OpenCore image and the target are all attached. Select by *size* or by *being the only unpartitioned disk*, and **refuse to proceed if more than one candidate matches**. Erasing the wrong disk here erases the installer.

- [ ] **Step 1: Write the failing test**

```bash
@test "autoinstall.sh partitions GPT, never APM" {
    run grep -c 'GPT' "$REPO/image/autoinstall/autoinstall.sh"
    [ "$output" -ge 1 ]
    run grep -ci 'APM\|Apple_partition_scheme' "$REPO/image/autoinstall/autoinstall.sh"
    [ "$output" = "0" ]
}

@test "autoinstall.sh refuses to erase when the target is ambiguous" {
    run grep -cE 'refus|ambiguous|more than one' "$REPO/image/autoinstall/autoinstall.sh"
    [ "$output" -ge 1 ]
}

@test "autoinstall.sh never hardcodes disk0" {
    run grep -cE '/dev/disk0([^0-9]|$)' "$REPO/image/autoinstall/autoinstall.sh"
    [ "$output" = "0" ]
}

@test "the LaunchDaemon plist is valid and runs our script at boot" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['Label']); print(' '.join(d['ProgramArguments'])); print(d.get('RunAtLoad'))
" "$REPO/image/autoinstall/com.mqg.autoinstall.plist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"com.mqg.autoinstall"* ]]
    [[ "$output" == *"autoinstall.sh"* ]]
    [[ "$output" == *"True"* ]]
}
```

- [ ] **Step 2: Run it, confirm it fails. Step 3: Write both files. Step 4: Tests pass.**

- [ ] **Step 5: Inject and boot it**

Extend `media/build-installer-img.sh` with `--autoinstall` to copy the plist into `System/Library/LaunchDaemons/` and the script into `System/Installation/` on the media, both root-executable as far as the mount allows.

Then boot it against a **blank** target disk with `p3-full`'s hardware, headless, and watch with `./vm/screenshot.sh`.

- [ ] **Step 6: Work the failure tree, one change at a time, recording everything**

| Symptom | Meaning | Try |
|---|---|---|
| Normal installer GUI appears | The daemon did not run | Check the plist landed in `System/Library/LaunchDaemons/` and is valid; check `Disabled` is not set |
| Daemon runs but `diskutil` finds no target | Disk selection is wrong | Log `diskutil list` output from inside the environment and read it |
| `installer` fails | Package path or target volume wrong | The log on the target volume should say; if the target is unmountable, log to the media instead |
| It installs but does not reboot | `shutdown` unavailable or blocked | Check the log; the install still succeeded, so this is cosmetic |

**Timebox this.** The design allows three materially different attempts before reporting. If the LaunchDaemon route fails three ways, the fallback is a human-driven install of a *golden* and P4 degrading to semi-automatic — say so plainly rather than grinding.

- [ ] **Step 7: Commit** with the honest result, including what did not work.

---

## Task 6: The first-boot payload

**Files:** Create `image/payload/firstboot.sh`, `image/payload/com.mqg.firstboot.plist`; Test `tests/payload.bats`

**Interfaces:**
- Consumes: a freshly installed target volume, from Task 5.
- Produces: an installed system that boots to a usable desktop with SSH, needing no Setup Assistant. Task 8 depends on it; **P6's CI image is this same payload with different parameters.**

The specification for this is `docs/install-log.md`'s Setup Assistant section — the list of what it actually asks. That is why the click-log was written.

What the payload must do, from the design and the click-log:

| Action | How |
|---|---|
| Skip Setup Assistant | `touch /var/db/.AppleSetupDone` |
| Create the user | `dscl` — account **`mavsuser`**, uid 501, in `admin` (gid 80), with a home directory. The click-log records exactly what Setup Assistant produced. |
| Install an SSH key | `~mavsuser/.ssh/authorized_keys`, mode 600, owned by the user; `.ssh` mode 700 |
| Enable Remote Login | `systemsetup -setremotelogin on`, or load `com.openssh.sshd` |
| Disable sleep | `systemsetup -setsleep Never`, `-setcomputersleep Never`, `-setdisplaysleep Never` |
| Disable screensaver | `defaults write` the loginwindow/user domain |
| Disable software update | `softwareupdate --schedule off` |
| Set the clock | The click-log found the guest clock already correct, so **verify rather than force** — and record which |
| Enable auto-login | Already on for a single user; confirm rather than assume |

**Take the SSH public key as a parameter**, defaulting to `~/.ssh/id_*.pub` on the host. Never generate a key into the image and never commit one.

**`softwareupdate` against Apple's 2026 servers may hang or fail.** The guest is a 2013 OS. Give any network-touching step a timeout and treat failure as non-fatal — a payload that hangs forever is worse than one that skips a nicety.

- [ ] **Step 1: Write the failing test**

```bash
@test "firstboot.sh skips Setup Assistant" {
    run grep -c 'AppleSetupDone' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "firstboot.sh creates the account the click-log recorded" {
    run grep -cE 'mavsuser' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
    run grep -cE 'dscl' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "firstboot.sh never contains an embedded private key or password" {
    run grep -ciE 'BEGIN (RSA|OPENSSH|DSA|EC) PRIVATE KEY' "$REPO/image/payload/firstboot.sh"
    [ "$output" = "0" ]
    run grep -ciE '^[^#]*password=[^$"]' "$REPO/image/payload/firstboot.sh"
    [ "$output" = "0" ]
}

@test "every network-touching step has a timeout" {
    # softwareupdate against Apple's 2026 servers can hang on a 2013 OS.
    run bash -c "grep -n 'softwareupdate' '$REPO/image/payload/firstboot.sh' | grep -vc 'timeout'"
    [ "$output" = "0" ]
}

@test "firstboot.sh removes its own LaunchDaemon so it runs exactly once" {
    run grep -cE 'rm .*com\.mqg\.firstboot|launchctl (unload|bootout)' "$REPO/image/payload/firstboot.sh"
    [ "$output" -ge 1 ]
}

@test "the firstboot LaunchDaemon plist is valid and runs at load" {
    run python3 -c "
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
print(d['Label'], d.get('RunAtLoad'), ' '.join(d['ProgramArguments']))
" "$REPO/image/payload/com.mqg.firstboot.plist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"firstboot.sh"* ]]
    [[ "$output" == *"True"* ]]
}
```

- [ ] **Step 2–4: fail, implement, pass.**

**It must run exactly once.** The payload removes its own LaunchDaemon as its last act. A first-boot script that runs on every boot will silently undo manual changes for the rest of the image's life, and the symptom appears long after the cause.

- [ ] **Step 5: Test it on a clone, not on a fresh install**

Faster loop: clone golden #1, inject the payload plus its LaunchDaemon, boot, and check. Golden #1 already has `mavsuser`, so test the *idempotence* path too — the payload must not break an account that already exists.

Verify from the host: `ssh mavsuser@localhost -p <forwarded>` works after boot. That needs `-netdev user,id=net0,hostfwd=tcp::2222-:22` added to the profile — a one-line profile change, and the first time this project has reached into the guest without a screenshot.

- [ ] **Step 6: Commit.**

---

## Task 7: `image/build-image.sh` — the orchestrator

**Files:** Create `image/build-image.sh`; Test `tests/image.bats`

**Interfaces:**
- Consumes: everything above.
- Produces: `$MQG_IMAGE_DIR/images/mavericks-<date>.qcow2` plus `<name>.manifest` recording every input — media checksum, OpenCore and OVMF checksums, config.plist checksum, payload checksum, and the commit this was built from.

**This is the deliverable of goal #2**: one command, clean checkout to bootable image, no interaction.

Parameterised by accelerator (`kvm`/`tcg`), machine type, CPU model and RAM — because **P6 runs this same pipeline under TCG on arm64**, and a second pipeline would be a second thing to keep correct.

**Idempotent and resumable.** Each stage checks whether its output already exists and is valid before doing the work again. A pipeline that cannot resume gets debugged by re-running an hour of work per attempt.

- [ ] **Step 1: Write the failing test**

```bash
@test "build-image.sh --describe lists its stages without doing anything" {
    run "$REPO/image/build-image.sh" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"media"* ]]
    [[ "$output" == *"install"* ]]
    [[ "$output" == *"payload"* ]]
}

@test "build-image.sh rejects an unknown accelerator" {
    run "$REPO/image/build-image.sh" --accel nonsense --describe
    [ "$status" -ne 0 ]
    [[ "$output" == *"accel"* ]]
}

@test "build-image.sh accepts both accelerators the project uses" {
    run "$REPO/image/build-image.sh" --accel kvm --describe
    [ "$status" -eq 0 ]
    run "$REPO/image/build-image.sh" --accel tcg --describe
    [ "$status" -eq 0 ]
}

@test "the manifest records every input that affects the output" {
    run "$REPO/image/build-image.sh" --manifest-fields
    [ "$status" -eq 0 ]
    for f in media opencore ovmf config payload commit; do
        [[ "$output" == *"$f"* ]] || { echo "manifest missing: $f"; return 1; }
    done
}
```

- [ ] **Step 2–4: fail, implement, pass.**

- [ ] **Step 5: Run it end to end** from a clean state. Record total wall-clock in `NOTES.md`, broken down by stage — P6 needs those numbers for its job budget.

- [ ] **Step 6: Commit.**

---

## Task 8: Prove it is reproducible

**Files:** Modify `NOTES.md`, `docs/install-log.md`; Create `docs/decisions/0005-image-pipeline-reproducibility.md`

**The exit criterion**, and the difference between "it worked once" and "it is a pipeline".

- [ ] **Step 1: Build twice, from scratch**

Delete every intermediate — media, installer image, target qcow2 — and run `image/build-image.sh` twice.

- [ ] **Step 2: Compare the outputs**

They will **not** be bit-identical: the install writes timestamps, UUIDs, and random seeds. That is expected and is not the claim being made.

Compare what matters instead:
- Both boot unattended to a desktop.
- Both accept SSH with the provided key.
- `sw_vers` matches.
- The installed file sets match — same paths, same sizes, modulo logs, caches and `/var`.
- Both manifests list identical inputs.

Write the comparison method down; an unstated method is not reproducible either.

- [ ] **Step 3: Verify on a fresh clone**

`git clone` to a temp dir, point `MQG_IMAGE_DIR` somewhere new, and run the pipeline. **This is the real test** — it proves the repo carries everything needed, and nothing depends on state accumulated in this working copy over the session.

This is the one that most often fails, and the failure is always interesting.

- [ ] **Step 4: Write `docs/decisions/0005-image-pipeline-reproducibility.md`**

What "reproducible" means here, precisely: same inputs → an image that behaves identically, not one that is bit-identical. What is pinned, what varies, and why each variation is acceptable.

- [ ] **Step 5: Update the design's phase table** — mark P4 complete, note what it delivers and what it does not.

- [ ] **Step 6: Commit.**

---

## Done means

- [ ] `image/build-image.sh` produces a bootable, SSH-reachable image from a clean checkout with no interaction.
- [ ] Run twice, both images behave identically by the stated method.
- [ ] It works from a fresh `git clone` with a fresh `MQG_IMAGE_DIR`.
- [ ] Installer media is built on Linux, verified against the Mac-produced reference, with any differences recorded.
- [ ] `./bin/run-tests.sh` passes, including `tier-check --strict`.
- [ ] No step needs root. If one does, that is documented as a finding.
- [ ] The manifest records every input.

## Stop and ask if

- Mavericks Forever's `get.sh` is unreachable or Apple's checksum mismatches.
- The Linux-built media is missing files the reference has — report before building on it.
- Three materially different attempts at unattended install all fail; P4 then degrades to semi-automatic and says so.
- Anything appears to need root or a host package.

## What comes next

P5 (performance) gets a repeatable way to produce a clean baseline. P6 (GitHub Actions) reuses this pipeline with `--accel tcg` — which is why the accelerator is a parameter from the start rather than something retrofitted.
