# vmavs in Go, Phase 4: installer media and the privops microVM

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- `vmavs media` builds bootable Mavericks installer media from Apple's
  `InstallESD.dmg`, as `media/build-installer-img.sh` does. It needs no
  Mac, no root and no host mount. The finished media carries the same
  files, byte for byte, as the shell tree's.
- `internal/privops` drives the busybox microVM: all reading and writing
  of HFS+ volumes happens inside it, as uid 0.
- `vmavs media digest` gives the content digest phase 5's manifest
  records.

**Architecture:**
- **`internal/privops`** is the host side of `lib/privops.sh` and
  `lib/privops-qemu-linux.sh`. It:
  - finds a kernel;
  - checks that busybox is static, by reading its ELF headers, with no
    `ldd`;
  - resolves modules through `modprobe`;
  - writes the initramfs in Go (newc cpio, gzip), with no `cpio`;
  - runs QEMU through `proc.Runner`, with a deadline;
  - reads the console's marker lines.

  The guest side stays busybox shell. That means `media/privops/*.sh`,
  embedded as they are, plus the `/init` script, which gets a file of
  its own in `assets/privops/init.sh`, held byte-equal to the heredoc in
  `lib/privops-qemu-linux.sh`.
- **`internal/media`** is the host side of `build-installer-img.sh`,
  `content-digest.sh`, `lib/hfs.sh` and the `--check-sums` half of
  `verify-installer-img.sh`:
  - the GPT comes from `diskimg`, and `mkfs.hfsplus` formats the volume;
  - the volume is copied into the partition sparsely, in Go;
  - it stages the injectables as a tar;
  - it edits `OSInstall.collection`;
  - it runs the four microVM passes;
  - it checks the result against Apple's pinned checksums;
  - it writes the sidecar.
- **`internal/lock`** is the directory-and-pid lock with stale takeover
  that the media build uses today (spec §5 "Locks"). Phase 5's pipeline
  reuses it.
- **`internal/cli`** gains the `vmavs media` subcommand, its `digest`
  action, and a `media` row in `vmavs doctor`.

**Tech Stack:**
- Go 1.26 standard library: `debug/elf`, `archive/tar`, `compress/gzip`,
  `encoding/xml`, `crypto/sha256`, `os`, `io`.
- No new modules.
- External tools, all run through `proc.Runner`:
  - `qemu-system-x86_64`, or `VMAVS_QEMU`;
  - `dmg2img`;
  - `mkfs.hfsplus`;
  - `modprobe`, optional;
  - `xz` and `zstd`, only when a module is compressed that way;
  - a static `busybox`, which goes into the initramfs, never run on the
    host.

**Spec:** `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`:
- §2: `vmavs media` and the conventions;
- §3: `media/`, `assets/privops/`, and the external tools that remain;
- §5: state and locks;
- §7: tests and parity;
- §9: phase 4.

## Global Constraints

- `go.mod` stays `go 1.26.0`. Use plain `go` commands and never set
  `GOFLAGS` for project commands. Add no module dependency.
- **The shell tree must keep working unchanged.**
  - Don't edit any existing shell file, `lib/`, `boot/`, `media/`,
    `image/`, `bin/`, `NOTES.md` history, `assets/pins/sources.tsv` or
    `components/`. Adding new files under `assets/` is allowed.
  - `./bin/run-tests.sh` exits 0. Check its status directly:
    `./bin/run-tests.sh >FILE 2>&1; echo $?`.
  - `bin/ingredient-fingerprint.sh` prints
    `a864536bf4402c760eb1b284a7b0f64f5f691485b3971a0f1cd7797554aa1d82`.
- **Commit no third-party bytes.** Never commit Apple's, busybox's or a
  kernel's bytes. Test fixtures are synthetic:
  - fake consoles;
  - fake ESDs, made of small generated files;
  - generated tarballs.
- **No test uses the network,** and no test needs Apple's bytes.
- **The real microVM runs in tests only when the host can run it.** One
  test, `TestTheMicroVMRunsAPayload`, boots it. It runs only when
  `privops.Backend.Missing()` is empty and `/dev/kvm` is writable, and
  it skips cleanly otherwise. Everything else uses `proc.Fake`.
- **Only Task 9 builds real media.**
  - Its ESD comes from adoption, and all HTTP goes to a dead proxy.
  - It never writes into `~/.local/share/mavericks-qemu-guest`. It
    reads the shell tree's files and hard-links from them, as phases 2
    and 3 did.
- **Packages have fixed jobs.**
  - Flags and argv live only in `internal/cli`.
  - `internal/config` places the top-level directories and the media's
    output and work directories.
  - External programs run through `proc.Runner`.
  - `internal/privops` knows nothing about installer media, and
    `internal/media` knows nothing about QEMU's command line.
- **Conventions are spec §2's:**
  - exit codes 0/1/2;
  - signals;
  - `vmavs <cmd>:` logging on stderr;
  - stdout carries only output.
- **Every claim is labelled MEASURED, INHERITED or REASONED.** Record
  `date -u +%FT%TZ` with every measurement. A task that changes the
  source of a MEASURED claim greps for dependent claims and fixes them in
  the same task.
- **Deletion: only delete what you can prove you created.** That means:
  - the media's own work files;
  - a previous `build/installer-media.img` when `--force` is given;
  - temp files.
- **Tests that exec an external tool skip cleanly when it is absent.**
  That covers `bash`, `sgdisk`, `mkfs.hfsplus`, `python3`, `dmg2img`,
  `qemu-system-x86_64` and `busybox`.
  - A parity test that runs a shell script using GNU-only options is
    also gated on `runtime.GOOS == "linux"`.
  - The `go-macos` CI job runs the rest.
- All of these are clean:
  - `gofmt -l`;
  - `go vet ./...`;
  - `go test -race ./...`;
  - staticcheck 2026.2.1 (v0.8.1 from the module cache is the same tag).
- The build succeeds for linux/amd64, darwin/amd64, darwin/arm64 and
  netbsd/amd64. The privops backend is Linux-only at run time: on other
  hosts, `Missing()` says so.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QX6srqxQqri25igdYHqmNo
  ```

## Rulings this plan makes (the spec is amended in Task 8)

1. **Where the media goes.** The media is written to
   `build/installer-media.img`, with a `.sha256` sidecar, and its scratch
   goes to `work/media/`. Both paths come from `config.Paths`.
   - Spec §5's state layout has no `media/`. Installer media is a
     long-lived build output that image builds reuse, like the firmware
     beside it.
   - The shell tree's `media/installer-linux.img` is never written or
     adopted: its sidecar goes stale the first time it is mounted.
2. **The media is built under a temp name and renamed into place.** It is
   assembled as `build/installer-media.img.building` and renamed only
   after the verify pass and the checksum. The shell wrote the final path
   directly, relying on its lock. The lock stays, and the rename means a
   killed build never leaves media that looks finished.
3. **The environment knobs go.**
   - `MQG_MEDIA_MARGIN_MIB` becomes the constant `MarginMiB = 512`.
   - `MQG_PRIVOPS_MEM`, `MODULES`, `BOOT_DIR`, `MODULES_DIR` and `KVER`
     become fields on `privops.Backend`, for tests. They are not
     environment variables.
   - `MQG_PRIVOPS_TIMEOUT` becomes `vmavs media --privops-timeout`, with a
     default of 15m. The shell's comments record a slow host needing
     more.
   - `MQG_PRIVOPS_BACKEND` goes: `qemu-linux` is the only backend.
4. **busybox linkage is read from its ELF headers, not from `ldd`.** A
   `PT_INTERP` program header means dynamic, no header means static, and
   a file that isn't ELF is unknown. This needs no `ldd` and has no
   libc-specific output to parse. It is more exact, and the verdicts are
   the shell's.
5. **The initramfs is written in Go, so the host no longer needs `cpio`.**
   It is newc format, gzip-compressed.
6. **The image-against-reference comparison stays shell for now.**
   `verify-installer-img.sh`'s mode that compares the built image with
   the Mac-made `InstallMavericks.iso` uses 7z, Python and Unicode
   normalisation. Go's standard library has no normaliser, and the build
   never calls this mode. It stays a second-tier shell tool, decided with
   the others after phase 6 (spec §9).
   - Go ports what the build needs: `--check-sums` and `--required`.
   - `privops-selftest.sh` stays too. Doctor's media row reports the
     same requirements, and Task 9 boots the real thing.
7. **The guest's `/init` script gets a file of its own.** It lives in
   `assets/privops/init.sh`, a new file. Today it is a heredoc inside
   `lib/privops-qemu-linux.sh`, and `go:embed` needs a file. A parity
   test holds the two byte-equal until phase 6 deletes the heredoc.
8. **`vmavs media` fetches its own ESD** through `fetch.InstallESD`,
   adopting the shell tree's download, as `firmware` does its sources.
   The first-boot package and the extra packages come in as flags,
   `--firstboot-pkg` and `--extra-pkg`, as they do in the shell.
   Building them is phase 5's pipeline.

## Facts this plan relies on

MEASURED on 2026-09-25, by reading the files named, unless marked
otherwise.

- **`media/build-installer-img.sh`**:
  - **Constants.** Partition sizing: `REFERENCE_PARTITION_BYTES=6550020096`,
    `MARGIN_MIB=512` and `BASE_PART_MIB = ceil(ref/1MiB) + margin`, which
    is 6247 + 512 = 6759. The partition is `BASE_PART_MIB + --extra-space-mib`.
    The volume name is `OS X Base System`, and `FIRSTBOOT_PKG_NAME=mqg-firstboot.pkg`.
  - **The autoinstall files**, each as source → destination, mode:
    - `autoinstall.sh` → `private/etc/rc.cdrom.local`, 755
    - `minstallconfig.xml` → `System/Installation/Packages/Extras/minstallconfig.xml`, 644
    - `OSInstall.collection` → `System/Installation/Packages/OSInstall.collection`, 644
  - **Flags.** It accepts `--describe`, `--force`, `--keep-work` and
    `--autoinstall`. `--firstboot-pkg P` and `--extra-pkg P` each imply
    `--autoinstall`, and `--extra-pkg` is repeatable. It also takes
    `--extra-space-mib N`.
  - **The steps, in order:**
    1. Check the privops backend first.
    2. Require the ESD.
    3. Check the xar magic of the first-boot and extra packages.
    4. Take the media lock, `<out>.lock`, a directory holding a `pid`
       file, taking over a stale one.
    5. Refuse an existing out unless `--force` is given.
    6. Run `dmg2img -s -i ESD -o work/esd.img`.
    7. Create the GPT image `hfs_create_gpt out PART_MIB "OS X Base System"`.
    8. Microvm pass 1, `extract-basesystem.sh`, with `ro:esd.img` and
       `raw:basesystem.dmg`. `basesystem.dmg` is first made as sparse as
       the ESD image, then truncated to `MQG-BASESYSTEM-BYTES`, and its
       sha is checked against `MQG-BASESYSTEM-SHA256`.
    9. Run `dmg2img -s -i basesystem.dmg -o basesystem.img`.
    10. Stage the injectables, only with `--autoinstall`:
        - put the autoinstall files in a staging directory with their
          modes;
        - add the first-boot package, as `mqg-firstboot.pkg` at 644,
          plus one `<string>` line inserted before `</array>` in
          `OSInstall.collection`, idempotently, then re-parse the plist;
        - add the extra packages, at 644, under their basenames;
        - tar the staging directory's non-directory entries into
          `inject.tar`.
    11. Pass 2, `assemble.sh`, with `ro:basesystem.img`, `ro:esd.img` and,
        if the tar exists, `raw:inject.tar`. Then the `MQG-SUM-ESD` lines
        are checked against `media/apple-packages.sha256`.
    12. Run `sync`.
    13. Pass 3, `fix-ownership.sh`.
    14. Pass 4, `verify-packages.sh`, whose `MQG-SUM-MEDIA` lines are
        checked the same way.
    15. Checksum the media.
    16. Write the `.sha256` sidecar, which is three comment lines and then
        `<sha>  <basename>`.
    17. Unless `--keep-work`, remove the work files.

    It prints out's path on stdout.
- **`lib/hfs.sh` `hfs_create_gpt IMG MIB NAME`:**
  - `mkfs.hfsplus -v NAME` runs on a separate sparse file of MIB MiB.
  - The image is `MIB+2` MiB, with partition 1 from 2048 to
    `2048 + MIB*2048 - 1`, type AF00, named NAME.
  - The volume goes in with `dd … seek=1M conv=notrunc,sparse`.
  - It refuses an existing image.
- **`hfs_mark_clean IMG [START]`** reads the block size and total blocks
  at `START+1024+40` (`>II`). The volume length is their product. In the
  headers at `START+1024` and `START+length-1024`, whose signature must
  be `H+` or `HX`, it sets attribute bit `0x100`, clears `0x800`, and
  writes the attributes back at offset +4.
- **`lib/privops-qemu-linux.sh`:**
  - **Modules.** The list is `nls_base nls_utf8 hfsplus virtio virtio_ring virtio_pci virtio_blk`.
    Each is resolved with `modprobe -S KVER -n --show-depends M`, taking
    the `insmod PATH` lines. The fallback is a search under
    `MODULES_DIR/KVER` for `M.ko{,.zst,.xz,.gz}`. A module found neither
    way means it is built in: warn and continue.
    - Staged modules are decompressed.
    - Dependencies are deduplicated.
    - The load order goes in `lib/modules/load-order`.
  - **Kernel candidates, in order:**
    - `BOOT/vmlinuz-KVER`
    - `MODULES/KVER/vmlinuz`
    - `BOOT/kernel-KVER`
    - `BOOT/vmlinuz-linux`
    - `BOOT/vmlinuz`
    - `BOOT/kernel-*`

    The first three are "keyed" to the running kernel.
  - **The initramfs** holds `bin/busybox`, `dev`, `proc`, `sys`, `mnt`,
    `lib/modules/*`, `disk-roles` (one role per line, in attach order),
    `init` (the heredoc, mode 755) and `payload.sh`.
  - **The QEMU command:**
    ```
    qemu-system-x86_64 -enable-kvm -m 512 -nographic -no-reboot -kernel K -initrd I \
      -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=<comma list>" \
      -drive file=TARGET,format=raw,if=virtio [-drive file=P,format=raw,if=virtio[,readonly=on]]...
    ```
    stdin is `/dev/null`, and stdout and stderr go to a console file.
    The timeout is 900 s.
  - **The console:**
    - `MQG-PRIVOPS-SOURCE-MOUNT-FAILED` fails the run, naming the
      conversion.
    - No `MQG-PRIVOPS-OK` fails it.
    - `MQG-PRIVOPS-OK rc=0` is success.
    - Payload lines are logged after stripping ANSI escapes, carriage
      returns, `^\[[ 0-9.]+\]` kernel lines, `MQG-PRIVOPS-*` and blank
      lines, each indented four spaces.
  - **The missing report** has one line per missing requirement:
    - `qemu-system-x86_64 (not on PATH)`
    - `cpio (not on PATH)`
    - `busybox (not on PATH)`, or the dynamic-busybox sentence
    - `a readable kernel image for KVER (looked for: …)`
- **`media/content-digest.sh IMG`:**
  - It makes a 32 MiB scratch HFS+ volume, `MQG DIGEST`, as the target,
    and a sparse 256 MiB listing file.
  - It runs the `content-digest.sh` payload with `ro:IMG` and
    `raw:listing`.
  - It reads the markers `MQG-DIGEST-FILES`, `-HASHED`, `-BYTES`,
    `-SIZE` and `-SHA256`, requires `FILES == HASHED`, truncates the
    listing to SIZE, and verifies its sha.
  - It prints `<sha256 of listing>  <n> files  <bytes> bytes  0 unreadable`.
    `--list` prints the listing first.
- **`media/verify-installer-img.sh`:**
  - `--check-sums FILE` compares `<sha>  <name>` lines, after stripping
    a leading `./`, against `media/apple-packages.sha256` (non-comment
    lines). It reports `NAME: MISSING -- the media does not have it` and
    `NAME: FAILED -- <got> is not what Apple shipped (<want>)`, sorted.
  - `--required` prints the 19 paths in `REQUIRED`.
- **`image/build-image.sh`'s `updates_extra_mib`** is
  `ceil(sum of the update packages' bytes / 1 MiB) + 64`, or 0 for
  `none`.
- **This host:** busybox is at `/usr/bin/busybox`, a static ELF. The
  kernel is `/boot/vmlinuz-7.2.6-1-t2-noble`, and it is readable. KVM is
  available. `dmg2img`, `mkfs.hfsplus` and sgdisk are installed.

## File structure

| Path | Responsibility |
|---|---|
| `assets/privops/init.sh` (new) | the microVM's `/init`, byte-equal to the heredoc in `lib/privops-qemu-linux.sh` |
| `embed.go`, `embed_test.go` | also embed `media/privops/*.sh`, `image/autoinstall/*`, `assets/privops/init.sh` |
| `internal/config/config.go` | `Paths.InstallerMedia()`, `Paths.MediaWork()` |
| `internal/lock/lock.go`, `lock_test.go` | directory-and-pid lock with stale takeover |
| `internal/privops/backend.go`, `requirements.go`, `initramfs.go`, `run.go`, tests | the microVM backend |
| `internal/media/hfs.go`, `apple.go`, `inject.go`, `build.go`, `digest.go`, tests | installer media |
| `internal/cli/media.go`, `media_test.go`, `doctor.go` | `vmavs media`, `vmavs media digest`, the doctor row |
| `README.md`, spec | commands, tools, phase status |

## Carrying the bats knowledge over (spec §7)

| bats test | Go test (task) |
|---|---|
| privops: kernel discovery (Debian, Arch, /lib/modules copy, Gentoo, none; keyed beats generic; only keyed paths count) | `TestKernel*` (2) |
| privops: missing report names every requirement; kernel line lists paths; nothing missing when met | `TestMissing*` (2) |
| privops: dynamic busybox reported as the wrong busybox; unknown linkage | `TestBusyboxLinkage*` (2): ELF-based (Ruling 4) |
| privops: unknown backend | none: one backend (Ruling 3) |
| privops: timeout reports itself; console streamed to a file | `TestRunTimeout`, `TestRunStreamsTheConsoleToAFile` (3) |
| privops: compressed modules staged; roles written into the initramfs; unknown role refused; missing extra image named before boot | `TestInitramfs*`, `TestRunRefuses*` (3) |
| privops: source ro / target not; a source that won't mount is its own failure | `TestRunDrives`, `TestRunSourceMountFailure` (3) |
| privops: microVM copies HFS+ keeping hardlinks, setuid and root; selftest | `TestTheMicroVMRunsAPayload` (3, when the host can) and Task 9's real build |
| hfs: create, refuse clobber, GPT with one AF00, mark-clean both headers, refuse non-HFS+, partitioned image | `TestCreateHFSGPT*`, `TestMarkClean*` (4) |
| hfs: nothing mounts on the host | `TestNothingMounts` (6): no Runner call is `mount`, `losetup`, `udisksctl` |
| media: describe reports the layout, touches nothing; sizes from the reference; fails without the ESD; refuses clobber | `TestDescribe*`, `TestBuildRefuses*` (6) |
| media: check-sums against Apple; pinned sums cover the packages; sha256 format; check-packages names the wrong one | `TestCheckAppleSums*` (5) |
| media: required files | `TestRequiredFiles` (5) |
| media: assembly never chowns; injectables staged before ownership | `TestPassOrder` (6) |
| media: lock refuse, takeover, removal | `TestLock*` (1) |
| media: content digest explains itself; skips boot artifacts; bulk hashing; counts; mounts nothing; read-only | `TestDigest*` (7); the payload is the shell's, unchanged |
| media: verify-installer-img image comparison, Unicode | stays: Ruling 6 |
| media: fetch-installesd.sh | phase 2 |

---

### Task 1: The embedded guest scripts, the media paths, and the lock

**Files:**
- Create: `assets/privops/init.sh`
- Modify: `embed.go`, `embed_test.go`
- Modify: `internal/config/config.go`, `internal/config/config_test.go`
- Create: `internal/lock/lock.go`, `internal/lock/lock_test.go`

**Interfaces:**
- Produces:
  - `vmguest.Files`, which also holds:
    - `media/privops/{assemble,content-digest,extract-basesystem,fix-ownership,verify-packages}.sh`
    - `image/autoinstall/{autoinstall.sh,minstallconfig.xml,OSInstall.collection}`
    - `assets/privops/init.sh`
  - `config.Paths.InstallerMedia() string`, which is `build/installer-media.img`.
  - `config.Paths.MediaWork() string`, which is `work/media`.
  - `lock.Acquire(dir string, pid int) (*lock.Lock, error)` and
    `(*Lock).Release() error`.

- [ ] **Step 1: Create `assets/privops/init.sh`**

Extract the heredoc exactly with awk: every line strictly between
`cat > "$root/init" <<'INIT'` and the line `INIT`.

```bash
awk '/^    cat > "\$root\/init" <<'"'"'INIT'"'"'$/{f=1;next} /^INIT$/{f=0} f' lib/privops-qemu-linux.sh > assets/privops/init.sh
head -2 assets/privops/init.sh   # #!/bin/busybox sh / B=/bin/busybox
```

Do not edit it. The file carries no header comment of its own, so that
it stays byte-equal to the heredoc.

- [ ] **Step 2: Write the failing tests**

`embed_test.go` gains:
- the eight new paths in its list;
- `TestInitIsTheShellTreesHeredoc`.

The new test reads `lib/privops-qemu-linux.sh`, extracts the heredoc
with the same rule in Go (the lines strictly between the
`cat > "$root/init" <<'INIT'` line and the next line that is exactly
`INIT`), and compares the result byte for byte with
`fs.ReadFile(Files, "assets/privops/init.sh")`. Each extracted line
keeps its trailing `\n`.

`internal/config/config_test.go`:

```go
func TestMediaPaths(t *testing.T) {
	p := Paths{Home: "/h"}
	if p.InstallerMedia() != "/h/build/installer-media.img" || p.MediaWork() != "/h/work/media" {
		t.Fatal(p.InstallerMedia(), p.MediaWork())
	}
}
```

`internal/lock/lock_test.go` (the tests the bats media-lock tests pin):
1. **`TestAcquireCreatesTheLockAndReleaseRemovesIt`.** `Acquire(dir, os.Getpid())` makes `dir/`, whose `dir/pid` holds the pid and a newline. `Release` removes `dir`.
2. **`TestASecondBuilderIsRefused`.**
   - Hold a lock whose pid file names a live process: this test's own pid, or a `sleep` child it starts and later kills.
   - `Acquire` returns an error naming that pid and the lock directory.
3. **`TestAStaleLockIsTakenOver`.**
   - A pid file names a pid that is not running: start `true` with `exec.Command`, `Wait` for it, and use its pid.
   - `Acquire` succeeds and reports the takeover: it returns a `*Lock` whose `TookOver` field is the old pid.
   - Afterwards `dir/pid` holds the new pid.
4. **`TestALockWithNoPidIsTakenOver`.** An empty directory counts as stale. The shell's `${holder:-unknown}` case covers this.
5. **`TestReleaseOnlyRemovesItsOwnLock`.**
   - After `Acquire`, rewrite `dir/pid` to another pid, as a later taker would.
   - `Release` leaves the directory alone and returns an error saying the lock is no longer this process's.

- [ ] **Step 3: Implement**

`embed.go`: add
`media/privops/*.sh image/autoinstall/autoinstall.sh image/autoinstall/minstallconfig.xml image/autoinstall/OSInstall.collection assets/privops/init.sh`
to the `//go:embed` line. Extend the doc comment: the microVM's scripts
and the unattended-install hooks travel in the binary.

`internal/config/config.go`:

```go
// InstallerMedia is where vmavs media writes the installer disk image it
// builds (Ruling 1 of phase 4): a build output reused by image builds, so
// under build/ beside the firmware, never the shell tree's
// media/installer-linux.img.
func (p Paths) InstallerMedia() string { return filepath.Join(p.Build(), "installer-media.img") }

// MediaWork is the media build's scratch: the raw conversions of the ESD
// and BaseSystem (several GB), the injectables' tar, the microVM console.
func (p Paths) MediaWork() string { return filepath.Join(p.Work(), "media") }
```

`internal/lock/lock.go`:

```go
// Package lock is a build lock that works everywhere vmavs does: a
// directory, created atomically by mkdir, holding the holder's pid. It is
// not flock(2): the lock must be visible to the shell tree's builders
// too, which use exactly this shape (media/build-installer-img.sh), and a
// directory is what OS X's shell tools can take as well. A lock whose
// holder is no longer running is stale, and is taken over rather than
// left to block every later build (spec §5, "Locks").
package lock

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// A Lock is held until Release.
type Lock struct {
	Dir      string
	PID      int
	TookOver int // the stale holder's pid, 0 if the lock was free (-1: unknown)
}

// Acquire takes the lock at dir for pid.
func Acquire(dir string, pid int) (*Lock, error) {
	l := &Lock{Dir: dir, PID: pid}
	if err := os.Mkdir(dir, 0o755); err != nil {
		if !errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
		}
		holder := readPID(dir)
		if holder > 0 && alive(holder) {
			return nil, fmt.Errorf("pid %d is already building here (lock %s): two builders sharing one image corrupt it, and each verifies its own cache and sees nothing wrong -- wait for it, or stop it and remove %s", holder, dir, dir)
		}
		l.TookOver = holder
		if holder == 0 {
			l.TookOver = -1
		}
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("cannot remove the stale lock %s: %w", dir, err)
		}
		if err := os.Mkdir(dir, 0o755); err != nil {
			return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		os.Remove(dir)
		return nil, err
	}
	return l, nil
}

// Release removes the lock, but only while it is still this holder's.
func (l *Lock) Release() error {
	if got := readPID(l.Dir); got != l.PID {
		return fmt.Errorf("the lock %s now names pid %d, not %d; leaving it", l.Dir, got, l.PID)
	}
	return os.RemoveAll(l.Dir)
}

func readPID(dir string) int {
	b, err := os.ReadFile(filepath.Join(dir, "pid"))
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0
	}
	return n
}

// alive is kill(pid, 0): EPERM means it exists and is someone else's.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
```

`syscall.Kill` exists on linux, darwin and netbsd. Confirm the four
cross-builds after writing this.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 . ./internal/config/ ./internal/lock/ -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add assets/privops embed.go embed_test.go internal/config internal/lock
git commit   # subject: "embed the microVM's scripts and the install hooks; the media's paths; a build lock"
```

---

### Task 2: The privops requirements (`internal/privops`)

**Files:**
- Create: `internal/privops/backend.go`, `internal/privops/requirements.go`, `internal/privops/requirements_test.go`

**Interfaces:**
- Consumes: `proc.Runner`.
- Produces:
  - ```go
    type Backend struct {
        Runner     proc.Runner
        QEMU       string        // qemu binary (config.QEMU)
        BootDir    string        // "/boot"
        ModulesDir string        // "/lib/modules"
        KVer       string        // uname -r
        Modules    []string      // DefaultModules
        MemMiB     int           // 512
        Timeout    time.Duration // 15m
        GOOS       string        // runtime.GOOS
        Log        func(string, ...any)
    }
    ```
  - `NewBackend(r proc.Runner, qemu string, log func(string, ...any)) (Backend, error)`, which fills the defaults and reads the release from `uname -r`.
  - `DefaultModules`.
  - `(Backend) KernelCandidates() []string` and `(Backend) Kernel() (string, error)`.
  - `(Backend) KernelIsKeyed(path string) bool`.
  - `BusyboxLinkage(path string) string`, which returns `static`, `dynamic` or `unknown`.
  - `(Backend) Missing() []string`.

- [ ] **Step 1: Write the failing tests**

`internal/privops/requirements_test.go` covers what `tests/privops.bats`
pins. It uses fixture directories and no real `/boot`:

1. **`TestKernelDiscovery`** is a table. Each row lays out files under
   `t.TempDir()` as `boot/` and `modules/`, sets
   `KVer: "6.1.0-test"`, and checks that `Kernel()` finds the file:
   - Debian `boot/vmlinuz-6.1.0-test`;
   - Arch `boot/vmlinuz-linux`;
   - `modules/6.1.0-test/vmlinuz`;
   - Gentoo `boot/kernel-6.1.0-test`;
   - `boot/vmlinuz`;
   - `boot/kernel-other`, the glob.

   Extra rows:
   - no kernel at all: an error, and nothing printed;
   - both `boot/vmlinuz-linux` and `boot/vmlinuz-6.1.0-test` present:
     the keyed one wins.

   A kernel file with mode 0 is skipped: it is not readable. Skip that
   case when the test runs as root.
2. **`TestKernelCandidatesMatchTheShell`.** With bash present and the
   same fixture root:
   ```
   bash -c '. lib/common.sh; . lib/privops.sh; . lib/privops-qemu-linux.sh; privops_qemu_linux_kernel_candidates'
   ```
   is run with `MQG_PRIVOPS_BOOT_DIR`, `MQG_PRIVOPS_MODULES_DIR` and
   `MQG_PRIVOPS_KVER` set. Its lines must equal `KernelCandidates()`,
   including the glob's expansion.
3. **`TestOnlyKeyedPathsCountAsKeyed`.** The first three candidate forms
   are keyed; `vmlinuz-linux`, `vmlinuz` and `kernel-other` are not.
4. **`TestBusyboxLinkage`.**
   - A static binary is `static`. Build one with `go build`, which with
     `CGO_ENABLED=0` makes a static ELF on Linux, into `t.TempDir()`.
     Skip if the toolchain is unavailable.
   - A dynamic binary is `dynamic`. Use `/bin/sh` when it is an ELF
     with `PT_INTERP`; skip otherwise.
   - A text file is `unknown`, and so is a missing file.
5. **`TestMissingNamesEveryRequirement`.**
   - The fake Runner's `LookPath` knows nothing, and the fixture has no
     kernel.
   - `Missing()` has one line each for `qemu-system-x86_64 (not on PATH)`,
     `busybox (not on PATH)` and
     `a readable kernel image for 6.1.0-test (looked for: <every candidate, space-separated>)`.
   - `cpio` is not listed (Ruling 5).
6. **`TestMissingReportsADynamicBusyboxAsTheWrongOne`.**
   - `LookPath("busybox")` returns the dynamic fixture.
   - The line reads `a statically linked busybox: <path> is dynamically linked, and the initramfs has no loader or libraries for it (Debian: busybox-static)`.
7. **`TestNothingIsMissingWhenAllIsMet`.** qemu and busybox are on the
   fake PATH, busybox is the static fixture, and a kernel is present:
   `Missing()` is empty.
8. **`TestMissingOnAnotherOS`.**
   - `GOOS: "darwin"` gives exactly one line:
     `the qemu-linux privops backend (it boots a Linux kernel with its own modules; this host is darwin)`.
   - No other probing happens.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/privops/ 2>&1 | head`
Expected: the package does not exist.

- [ ] **Step 3: Implement**

`internal/privops/backend.go`:

```go
// Package privops does privileged filesystem work without host privilege:
// it boots a busybox initramfs under QEMU, with the host's own kernel,
// attaches the images as virtio disks, and runs a payload script there
// as uid 0. Building macOS installer media needs root-owned HFS+ files,
// and Linux gives an unprivileged user no way to write them; a VM where
// we are genuinely root does (lib/privops.sh has the whole argument).
//
// The host side is Go; the guest side is busybox shell -- /init
// (assets/privops/init.sh) and the caller's payload. The two speak
// through the disks and through marker lines on the serial console.
package privops

import (
	"bytes"
	"context"
	"fmt"
	"runtime"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

// DefaultModules are loaded in the guest, with their dependencies:
// hfsplus and the NLS it needs, and virtio for distributions that build
// it as modules (Debian builds it in; staging a built-in module costs a
// warning).
var DefaultModules = []string{"nls_base", "nls_utf8", "hfsplus", "virtio", "virtio_ring", "virtio_pci", "virtio_blk"}

// Backend is the qemu-linux privops backend on one host.
type Backend struct {
	Runner     proc.Runner
	QEMU       string
	BootDir    string
	ModulesDir string
	KVer       string
	Modules    []string
	MemMiB     int
	Timeout    time.Duration
	GOOS       string
	Log        func(string, ...any)
}

// NewBackend is a Backend for this host: /boot, /lib/modules, the running
// kernel's release, 512 MiB, a 15-minute bound on a pass.
func NewBackend(r proc.Runner, qemu string, log func(string, ...any)) (Backend, error) {
	b := Backend{Runner: r, QEMU: qemu, BootDir: "/boot", ModulesDir: "/lib/modules",
		Modules: DefaultModules, MemMiB: 512, Timeout: 15 * time.Minute, GOOS: runtime.GOOS, Log: log}
	if b.GOOS != "linux" {
		return b, nil
	}
	var out bytes.Buffer
	if err := r.Run(context.Background(), proc.Cmd{Name: "uname", Args: []string{"-r"}, Stdout: &out}); err != nil {
		return b, fmt.Errorf("cannot ask uname for the kernel release: %w", err)
	}
	b.KVer = strings.TrimSpace(out.String())
	return b, nil
}

func (b Backend) logf(f string, a ...any) {
	if b.Log != nil {
		b.Log(f, a...)
	}
}
```

`internal/privops/requirements.go`:

```go
package privops

import (
	"debug/elf"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// KernelCandidates is every path a kernel image might be at, most
// specific first. The first three carry the running release, so the
// modules staged from ModulesDir/KVer load into them; the rest are
// generic names distributions use (Arch's vmlinuz-linux, Alpine's
// vmlinuz, Gentoo's kernel-*), tried only when no keyed one exists,
// because a kernel of another release rejects every module and the
// failure then looks like an HFS+ problem.
func (b Backend) KernelCandidates() []string {
	c := []string{
		filepath.Join(b.BootDir, "vmlinuz-"+b.KVer),
		filepath.Join(b.ModulesDir, b.KVer, "vmlinuz"),
		filepath.Join(b.BootDir, "kernel-"+b.KVer),
		filepath.Join(b.BootDir, "vmlinuz-linux"),
		filepath.Join(b.BootDir, "vmlinuz"),
	}
	glob, _ := filepath.Glob(filepath.Join(b.BootDir, "kernel-*"))
	if len(glob) == 0 {
		glob = []string{filepath.Join(b.BootDir, "kernel-*")} // what the shell prints when nothing matches
	}
	return append(c, glob...)
}

// Kernel is the first readable candidate.
func (b Backend) Kernel() (string, error) {
	for _, c := range b.KernelCandidates() {
		if f, err := os.Open(c); err == nil {
			fi, serr := f.Stat()
			f.Close()
			if serr == nil && fi.Mode().IsRegular() {
				return c, nil
			}
		}
	}
	return "", fmt.Errorf("no readable kernel image for %s (looked for: %s)", b.KVer, strings.Join(b.KernelCandidates(), " "))
}

// KernelIsKeyed says whether path carries the running release.
func (b Backend) KernelIsKeyed(path string) bool {
	for _, k := range b.KernelCandidates()[:3] {
		if path == k {
			return true
		}
	}
	return false
}

// BusyboxLinkage reads an executable's ELF headers: a PT_INTERP program
// header names a dynamic loader, which an initramfs holding one binary
// does not have. static, dynamic, or unknown (not ELF, or unreadable) --
// and unknown is not reported as missing: refusing to build on a guess
// would be a worse failure than the one this catches.
func BusyboxLinkage(path string) string {
	f, err := elf.Open(path)
	if err != nil {
		return "unknown"
	}
	defer f.Close()
	for _, p := range f.Progs {
		if p.Type == elf.PT_INTERP {
			return "dynamic"
		}
	}
	return "static"
}

// Missing is one line per unmet requirement, and nothing when the backend
// can run here. Every one is named, not just the first: a report naming
// one of several costs a round trip per guess.
func (b Backend) Missing() []string {
	if b.GOOS != "linux" {
		return []string{fmt.Sprintf("the qemu-linux privops backend (it boots a Linux kernel with its own modules; this host is %s)", b.GOOS)}
	}
	var m []string
	if _, err := b.Runner.LookPath(b.QEMU); err != nil {
		m = append(m, b.QEMU+" (not on PATH)")
	}
	if bb, err := b.Runner.LookPath("busybox"); err != nil {
		m = append(m, "busybox (not on PATH)")
	} else if BusyboxLinkage(bb) == "dynamic" {
		m = append(m, fmt.Sprintf("a statically linked busybox: %s is dynamically linked, and the initramfs has no loader or libraries for it (Debian: busybox-static)", bb))
	}
	if _, err := b.Kernel(); err != nil {
		m = append(m, fmt.Sprintf("a readable kernel image for %s (looked for: %s)", b.KVer, strings.Join(b.KernelCandidates(), " ")))
	}
	return m
}
```

The shell's glob prints the literal `BOOT/kernel-*` when nothing
matches, and `KernelCandidates` does the same, which keeps the parity
test's lines equal. `Kernel()` tries that literal path and finds nothing
there, which is harmless.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/privops/ -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS. The shell-parity test runs here.

- [ ] **Step 5: Commit**

```bash
git add internal/privops
git commit   # subject: "privops: what the microVM needs, found and named as lib/privops-qemu-linux.sh does, without ldd or cpio"
```

---

### Task 3: The initramfs and the run (`internal/privops`)

**Files:**
- Create: `internal/privops/initramfs.go`, `internal/privops/run.go`, `internal/privops/run_test.go`

**Interfaces:**
- Consumes: Task 2, `vmguest.Files` (`assets/privops/init.sh`).
- Produces:
  - `type Disk struct{ Role, Path string }`, where Role is `"ro"` or `"raw"`.
  - `(Backend) Run(ctx context.Context, target string, payload []byte, disks []Disk) (console []byte, err error)`.
  - `Markers(console []byte, name string) []string`: every value after `name + " "`, with carriage returns stripped.
  - `(Backend) buildInitramfs(ctx context.Context, payload []byte, roles []string) ([]byte, error)`, unexported.

- [ ] **Step 1: Write the failing tests**

`internal/privops/run_test.go` uses a fake Runner and a fixture
backend: a static busybox made as in Task 2, a fixture kernel file, and
a fake module tree.

1. **`TestInitramfsHoldsWhatTheGuestNeeds`.** Read the gzip'd newc
   archive back with a small reader in the test. The reader has to be
   written, because the standard library has no newc reader: parse the
   110-byte headers, with 4-byte padding.
   - It holds `bin/busybox`, with the busybox fixture's bytes and mode
     0755.
   - It holds `init`, equal to `assets/privops/init.sh`, with mode 0755,
     and `payload.sh`, equal to the payload bytes.
   - It holds the directories `dev`, `proc`, `sys`, `mnt` and
     `lib/modules`, and the entry `TRAILER!!!` last.
   - `disk-roles` is `ro\nraw\n` for two disks, and empty for none.
   - Every entry has uid 0 and gid 0.
2. **`TestInitramfsStagesModulesInModprobesOrder`.**
   - The fake `modprobe -S 6.1.0-test -n --show-depends hfsplus` prints
     `insmod /m/nls_base.ko \ninsmod /m/hfsplus.ko.gz \n`, and prints
     nothing for the other modules.
   - The fixture files `nls_base.ko` and `hfsplus.ko.gz` (really
     gzipped) sit under the modules dir.
   - `lib/modules/load-order` is `nls_base.ko\nhfsplus.ko\n`, and
     `lib/modules/hfsplus.ko` is decompressed.
   - A module named twice is staged once.
3. **`TestInitramfsFallsBackToAFileSearch`.** With no modprobe on the
   fake PATH, `nls_utf8.ko` is found under `ModulesDir/KVer/kernel/fs/`
   and staged.
4. **`TestAModuleNobodyHasIsAssumedBuiltIn`.** The log says
   `no virtio_blk module under … -- assuming it is built into the kernel`,
   and the build continues.
5. **`TestCompressedModulesUseTheirTools`.**
   - A `.xz` module is decompressed through the Runner, as
     `xz -dc <path>`, with stdout written into the staged file. Likewise
     a `.zst` module, as `zstd -dqc <path>`.
   - If either tool is missing from the fake PATH, the error says
     `<path> is xz-compressed and xz is not installed`.
6. **`TestRunDrives`.** For `Run(ctx, "/t.img", payload, []Disk{{"ro","/a"},{"raw","/b"}})`
   with those files present, the one QEMU call's argv is exactly:
   ```
   -enable-kvm -m 512 -nographic -no-reboot -kernel <kernel> -initrd <tmp>/initramfs.cpio.gz
   -append "console=ttyS0 loglevel=3 panic=1 mqg_modules=nls_base,nls_utf8,hfsplus,virtio,virtio_ring,virtio_pci,virtio_blk"
   -drive file=/t.img,format=raw,if=virtio
   -drive file=/a,format=raw,if=virtio,readonly=on
   -drive file=/b,format=raw,if=virtio
   ```
   Its Stdin is an empty reader, and its Stdout and Stderr are the same
   `*os.File`: the console file.
7. **`TestRunRefusesAnUnknownRoleAndAMissingImage`.**
   - A `Disk{"rw", …}` gives `privops: unknown disk role "rw"`.
   - A missing ro path gives `privops: no such image: <path>`.
   - Neither boots anything.
8. **`TestRunStreamsTheConsoleToAFile`.**
   - The fake writes the console through `c.Stdout`, which must be an
     `*os.File`: assert that.
   - `Run` returns those bytes.
9. **`TestRunSucceedsOnOKAndLogsThePayloadsLines`.**
   - The console holds kernel lines like `[    0.123] foo`, an ANSI
     escape, `MQG-PRIVOPS-MOUNTED /dev/vda1`, `payload says hi\r`, a
     blank line, and `MQG-PRIVOPS-OK rc=0`.
   - The log gets exactly `    payload says hi`.
10. **`TestRunFailures`** is a table, one row per console:
    - `MQG-PRIVOPS-OK rc=1` gives `the payload script reported a failure inside the microVM`;
    - no `MQG-PRIVOPS-OK` at all gives `privileged operations failed inside the microVM`, and the console's last 20 lines are in the log;
    - `MQG-PRIVOPS-SOURCE-MOUNT-FAILED 1 /dev/vdb` gives an error containing `a disk the microVM was given was not there, or held no mountable HFS+ volume`.
11. **`TestRunTimeout`.**
    - The fake blocks until its ctx is done, then returns `ctx.Err()`, as `proc.Exec` does when it kills the process.
    - With `Timeout: 50*time.Millisecond`, the error says `the microVM did not finish within 50ms` and suggests `--privops-timeout`.
    - A parent ctx that is cancelled rather than timed out returns `context.Canceled`, with no timeout wording.
12. **`TestMarkers`.** `Markers([]byte("A 1\r\nB x\nA 2\n"), "A")` is `[1 2]`.
13. **`TestTheMicroVMRunsAPayload`.**
    - Skip unless all three hold: `runtime.GOOS == "linux"`, a real
      `NewBackend(proc.Exec{}, "qemu-system-x86_64", t.Logf)` reports
      `Missing()` empty, and `/dev/kvm` is writable.
    - Make a 16 MiB HFS+ target, using `mkfs.hfsplus` on a temp file.
      Skip if it is absent.
    - Run the payload
      `echo "MQG-TEST-WROTE $($B sh -c 'echo hi > $MQG_MNT/hello; $B cat $MQG_MNT/hello')"`.
    - `Markers(console, "MQG-TEST-WROTE")` is `[hi]`.
    - This is the real boot. It takes about 5 s on the primary host.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/privops/ -run 'Initramfs|Run|Markers|MicroVM|Module' 2>&1 | head`
Expected: undefined.

- [ ] **Step 3: Implement**

`internal/privops/initramfs.go`:

```go
package privops

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// newc is a cpio "newc" archive being written: what the kernel unpacks as
// an initramfs. The host needs no cpio(1) for it.
type newc struct {
	buf bytes.Buffer
	ino uint32
}

func (w *newc) add(name string, mode uint32, data []byte) {
	w.ino++
	namez := name + "\x00"
	fmt.Fprintf(&w.buf, "070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X",
		w.ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(namez), 0)
	w.buf.WriteString(namez)
	w.pad()
	w.buf.Write(data)
	w.pad()
}

func (w *newc) pad() {
	for w.buf.Len()%4 != 0 {
		w.buf.WriteByte(0)
	}
}

const (
	modeDir  = 0o040755
	modeExec = 0o100755
	modeFile = 0o100644
)

// buildInitramfs is the gzip'd newc archive the guest boots: busybox,
// /init, the payload, the modules in load order, and the disk roles.
func (b Backend) buildInitramfs(ctx context.Context, payload []byte, roles []string) ([]byte, error) {
	bbPath, err := b.Runner.LookPath("busybox")
	if err != nil {
		return nil, fmt.Errorf("busybox: %w", err)
	}
	bb, err := os.ReadFile(bbPath)
	if err != nil {
		return nil, err
	}
	initScript, err := fs.ReadFile(vmguest.Files, "assets/privops/init.sh")
	if err != nil {
		return nil, err
	}
	mods, order, err := b.stageModules(ctx)
	if err != nil {
		return nil, err
	}
	w := &newc{}
	for _, d := range []string{"bin", "dev", "proc", "sys", "mnt", "lib", "lib/modules"} {
		w.add(d, modeDir, nil)
	}
	w.add("bin/busybox", modeExec, bb)
	for _, name := range order {
		w.add("lib/modules/"+name, modeFile, mods[name])
	}
	w.add("lib/modules/load-order", modeFile, []byte(joinLines(order)))
	w.add("disk-roles", modeFile, []byte(joinLines(roles)))
	w.add("init", modeExec, initScript)
	w.add("payload.sh", modeFile, payload)
	w.add("TRAILER!!!", 0, nil)

	var gz bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&gz, gzip.BestCompression)
	if _, err := zw.Write(w.buf.Bytes()); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return gz.Bytes(), nil
}

func joinLines(s []string) string {
	if len(s) == 0 {
		return ""
	}
	return strings.Join(s, "\n") + "\n"
}

// stageModules resolves each module, with its dependencies, the way the
// distribution's own modprobe would load it (modules.dep), falling back
// to a file search when there is no modprobe or it knows nothing; each is
// decompressed, because busybox insmod reads no compressed format and
// resolves no dependencies. A module found neither way is taken to be
// built in: legitimate and common.
func (b Backend) stageModules(ctx context.Context) (map[string][]byte, []string, error) {
	mods := map[string][]byte{}
	var order []string
	for _, m := range b.Modules {
		deps := b.modprobeDeps(ctx, m)
		if len(deps) == 0 {
			if p := b.findModule(m); p != "" {
				deps = []string{p}
			}
		}
		if len(deps) == 0 {
			b.logf("no %s module under %s -- assuming it is built into the kernel", m, filepath.Join(b.ModulesDir, b.KVer))
			continue
		}
		for _, src := range deps {
			base := filepath.Base(src)
			for _, ext := range []string{".zst", ".xz", ".gz"} {
				base = strings.TrimSuffix(base, ext)
			}
			if _, seen := mods[base]; seen {
				continue
			}
			data, err := b.readModule(ctx, src)
			if err != nil {
				return nil, nil, err
			}
			mods[base] = data
			order = append(order, base)
		}
	}
	return mods, order, nil
}

func (b Backend) modprobeDeps(ctx context.Context, m string) []string {
	if _, err := b.Runner.LookPath("modprobe"); err != nil {
		return nil
	}
	var out bytes.Buffer
	if err := b.Runner.Run(ctx, proc.Cmd{Name: "modprobe", Args: []string{"-S", b.KVer, "-n", "--show-depends", m}, Stdout: &out}); err != nil {
		return nil
	}
	var deps []string
	for _, line := range strings.Split(out.String(), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == "insmod" {
			deps = append(deps, f[1])
		}
	}
	return deps
}

func (b Backend) findModule(m string) string {
	var found []string
	root := filepath.Join(b.ModulesDir, b.KVer)
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		switch d.Name() {
		case m + ".ko", m + ".ko.zst", m + ".ko.xz", m + ".ko.gz":
			found = append(found, p)
		}
		return nil
	})
	sort.Strings(found)
	if len(found) == 0 {
		return ""
	}
	return found[0]
}

func (b Backend) readModule(ctx context.Context, src string) ([]byte, error) {
	switch {
	case strings.HasSuffix(src, ".gz"):
		f, err := os.Open(src)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		zr, err := gzip.NewReader(f)
		if err != nil {
			return nil, fmt.Errorf("cannot decompress %s: %w", src, err)
		}
		return io.ReadAll(zr)
	case strings.HasSuffix(src, ".xz"):
		return b.decompress(ctx, "xz", "xz", []string{"-dc", src}, src)
	case strings.HasSuffix(src, ".zst"):
		return b.decompress(ctx, "zstd", "zstd", []string{"-dqc", src}, src)
	}
	return os.ReadFile(src)
}

// decompress runs tool on a module compressed as format; the two are
// named separately because the message names both.
func (b Backend) decompress(ctx context.Context, format, tool string, args []string, src string) ([]byte, error) {
	if _, err := b.Runner.LookPath(tool); err != nil {
		return nil, fmt.Errorf("%s is %s-compressed and %s is not installed", src, format, tool)
	}
	var out bytes.Buffer
	if err := b.Runner.Run(ctx, proc.Cmd{Name: tool, Args: args, Stdout: &out}); err != nil {
		return nil, fmt.Errorf("cannot decompress %s: %w", src, err)
	}
	return out.Bytes(), nil
}
```

`internal/privops/run.go`:

```go
package privops

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

// A Disk is an extra image the microVM gets after the target: "ro" is
// mounted read-only as $MQG_SRC<n>, "raw" is handed over as a block
// device $MQG_RAW<n> and not mounted -- which is how a payload gives a
// file back to the host.
type Disk struct{ Role, Path string }

var (
	ansi       = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]`)
	kernelLine = regexp.MustCompile(`^\[[ 0-9.]+\]`)
)

// Run boots the microVM with target attached read-write as /dev/vda and
// the disks after it, runs payload as uid 0, and returns the console --
// the only channel out besides the disks. The console is streamed to a
// file, not captured through a pipe: -nographic hands QEMU stdin and
// stdout, and capturing them has produced zero bytes on a host where
// the same command printed normally.
func (b Backend) Run(ctx context.Context, target string, payload []byte, disks []Disk) ([]byte, error) {
	if m := b.Missing(); len(m) > 0 {
		for _, l := range m {
			b.logf("  missing: %s", l)
		}
		return nil, fmt.Errorf("the privops microVM cannot run on this host: %d requirement(s) above are unmet -- nothing here installs anything; see vmavs doctor", len(m))
	}
	if _, err := os.Stat(target); err != nil {
		return nil, fmt.Errorf("privops: no such image: %s", target)
	}
	var roles []string
	args := []string{}
	for _, d := range disks {
		switch d.Role {
		case "ro", "raw":
		default:
			return nil, fmt.Errorf("privops: unknown disk role %q", d.Role)
		}
		if _, err := os.Stat(d.Path); err != nil {
			return nil, fmt.Errorf("privops: no such image: %s", d.Path)
		}
		roles = append(roles, d.Role)
	}
	kernel, err := b.Kernel()
	if err != nil {
		return nil, err
	}
	if !b.KernelIsKeyed(kernel) {
		b.logf("warning: %s is not keyed to the running kernel (%s): if it is a different build, none of the modules staged from %s will load",
			kernel, b.KVer, filepath.Join(b.ModulesDir, b.KVer))
	}
	tmp, err := os.MkdirTemp("", "vmavs-privops-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	initrd, err := b.buildInitramfs(ctx, payload, roles)
	if err != nil {
		return nil, err
	}
	initrdPath := filepath.Join(tmp, "initramfs.cpio.gz")
	if err := os.WriteFile(initrdPath, initrd, 0o600); err != nil {
		return nil, err
	}
	args = append(args, "-enable-kvm", "-m", fmt.Sprint(b.MemMiB), "-nographic", "-no-reboot",
		"-kernel", kernel, "-initrd", initrdPath,
		"-append", "console=ttyS0 loglevel=3 panic=1 mqg_modules="+strings.Join(b.Modules, ","),
		"-drive", "file="+target+",format=raw,if=virtio")
	for _, d := range disks {
		spec := "file=" + d.Path + ",format=raw,if=virtio"
		if d.Role == "ro" {
			spec += ",readonly=on"
		}
		args = append(args, "-drive", spec)
	}
	consolePath := filepath.Join(tmp, "console.txt")
	cf, err := os.Create(consolePath)
	if err != nil {
		return nil, err
	}
	rctx, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()
	b.logf("running privileged operations in a QEMU microVM (no host root)")
	runErr := b.Runner.Run(rctx, proc.Cmd{Name: b.QEMU, Args: args, Stdin: bytes.NewReader(nil), Stdout: cf, Stderr: cf})
	cf.Close()
	console, _ := os.ReadFile(consolePath)

	if errors.Is(rctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
		b.logTail(console)
		return console, fmt.Errorf("the microVM did not finish within %s -- raise --privops-timeout if this host is slower, or see the console above if it hung", b.Timeout)
	}
	if ctx.Err() != nil {
		return console, ctx.Err()
	}
	b.logPayload(console)
	text := string(console)
	if strings.Contains(text, "MQG-PRIVOPS-SOURCE-MOUNT-FAILED") {
		return console, fmt.Errorf("a disk the microVM was given was not there, or held no mountable HFS+ volume -- the conversion that produced it is the suspect, not the target image, which was not written to")
	}
	if !strings.Contains(text, "MQG-PRIVOPS-OK") {
		b.logTail(console)
		if runErr != nil {
			return console, fmt.Errorf("privileged operations failed inside the microVM: %w", runErr)
		}
		return console, errors.New("privileged operations failed inside the microVM")
	}
	if !strings.Contains(text, "MQG-PRIVOPS-OK rc=0") {
		return console, errors.New("the payload script reported a failure inside the microVM")
	}
	b.logf("privileged operations completed and the image unmounted cleanly")
	return console, nil
}

func cleanLines(console []byte) []string {
	var out []string
	for _, l := range strings.Split(string(console), "\n") {
		l = strings.ReplaceAll(ansi.ReplaceAllString(l, ""), "\r", "")
		out = append(out, l)
	}
	return out
}

// logPayload logs what the payload printed: the only diagnostic when a
// build goes wrong. Kernel lines, the backend's own markers and blank
// lines are left out.
func (b Backend) logPayload(console []byte) {
	for _, l := range cleanLines(console) {
		if l == "" || kernelLine.MatchString(l) || strings.HasPrefix(l, "MQG-PRIVOPS-") {
			continue
		}
		b.logf("    %s", l)
	}
}

func (b Backend) logTail(console []byte) {
	lines := cleanLines(console)
	if len(lines) > 20 {
		lines = lines[len(lines)-20:]
	}
	for _, l := range lines {
		b.logf("  %s", l)
	}
}

// Markers is every value printed after "name " on the console.
func Markers(console []byte, name string) []string {
	var v []string
	for _, l := range strings.Split(string(console), "\n") {
		l = strings.TrimRight(l, "\r")
		if rest, ok := strings.CutPrefix(l, name+" "); ok {
			v = append(v, rest)
		}
	}
	return v
}
```

`TestRunDrives` asserts argv with `-initrd <tmp>/initramfs.cpio.gz`.
Assert the prefix and the suffix, since `<tmp>` is random.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/privops/ -v 2>&1 | grep -E '^(--- |FAIL|ok|    run_test)'`
Expected: PASS, and `TestTheMicroVMRunsAPayload` actually boots on this
host rather than skipping. Record its time.

- [ ] **Step 5: Commit**

```bash
git add internal/privops
git commit   # subject: "privops: the initramfs in Go and the microVM run, markers and all"
```

---

### Task 4: HFS+ images (`internal/media/hfs.go`)

**Files:**
- Create: `internal/media/hfs.go`, `internal/media/hfs_test.go`

**Interfaces:**
- Consumes: `diskimg.WriteGPT`, `diskimg.TypeAppleHFS`, `diskimg.DerivedGUID` and `proc.Runner`.
- Produces:
  - `CreateHFS(ctx, r proc.Runner, img string, mib int, volname string) error`, a bare volume, which is `hfs_create`;
  - `CreateHFSGPT(ctx, r proc.Runner, img string, mib int, volname string) error`, which is `hfs_create_gpt`;
  - `MarkClean(img string, start int64) (changed []string, err error)`, which is `hfs_mark_clean`.

- [ ] **Step 1: Write the failing tests**

1. **`TestCreateHFSGPTLaysOutOneAppleHFSPartition`.**
   - The fake `mkfs.hfsplus` writes `H+` at offset 1024 of the file it
     is given, and records the call.
   - The image is `(mib+2)` MiB.
   - `diskimg.ReadGPT` finds one partition:
     - type `TypeAppleHFS`;
     - LBA 2048 to `2048+mib*2048-1`;
     - named `OS X Base System`.
   - The partition's byte 1024 onward begins `H+`.
   - `mkfs.hfsplus` was called with `-v`, `OS X Base System` and a
     path ending `.hfs-tmp`, and that temp file is gone afterwards.
2. **`TestCreateHFSGPTRefusesAnExistingImage`.** An existing image is
   refused and left untouched, and mkfs is not run.
3. **`TestCreateHFSGPTLeavesNothingWhenMkfsFails`.** When the fake
   fails, the error names mkfs, and neither the image nor the temp file
   exists.
4. **`TestTheVolumeIsCopiedSparsely`.**
   - The fake mkfs writes 4 KiB at the start of its file and 4 KiB at
     the end, and leaves the rest a hole.
   - After `CreateHFSGPT`, the image's allocated size is far below its
     apparent size (`syscall.Stat_t.Blocks*512 < size/4`).
   - Skip on filesystems without holes: if a 64 MiB `Truncate` in
     `t.TempDir()` is not sparse, skip.
5. **`TestCreateHFSGPTMatchesTheShell`.** Run only on Linux with bash,
   sgdisk and `mkfs.hfsplus` present.
   - Build `hfs_create_gpt shell.img 40 "OS X Base System"`, and Go's
     image with a real Runner.
   - `sgdisk -i 1` on each gives the same `First sector`, `Last sector`
     and `Partition GUID code` (AF00, `Apple HFS/HFS+`) and the same
     `Partition name`.
   - The two files are the same size.
   - Both volumes' headers (partition start + 1024) carry `H+`, and the
     same block size and total blocks.
6. **`TestMarkCleanSetsTheBitInBothHeaders`.**
   - A synthetic volume: a 1 MiB file with an `H+` header at 1024
     holding block size 4096, total blocks 256 and attributes
     `0x00000800`, and the same at `length-1024`.
   - `MarkClean(img, 0)` makes both attribute words `0x00000100`, and
     reports two changes.
   - A second run reports both as already clean.
7. **`TestMarkCleanMatchesTheShell`.** Run only with bash and python3.
   - Apply `hfs_mark_clean` to one copy and `MarkClean` to another, for
     two fixtures: a bare volume, and one at offset 1 MiB inside a
     larger file.
   - The resulting files are byte-identical.
8. **`TestMarkCleanRefusesWhatIsNotHFSPlus`.**
   - With no signature, the error names the offset.
   - A volume claiming more bytes than the file holds gives
     `volume at <start> claims <n> bytes, which does not fit in <img>`.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/media/ 2>&1 | head`
Expected: the package does not exist.

- [ ] **Step 3: Implement `internal/media/hfs.go`**

```go
// Package media builds bootable Mavericks installer media from Apple's
// InstallESD.dmg without a Mac, root, or a host mount: the host makes the
// disk image and the raw conversions, and every read or write of an HFS+
// volume's contents happens as uid 0 inside the privops microVM. It is
// the Go form of media/build-installer-img.sh, media/content-digest.sh,
// lib/hfs.sh and verify-installer-img.sh's --check-sums.
package media

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"

	"github.com/Mavergreen/vm-guest/internal/diskimg"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// CreateHFS makes img a bare HFS+ volume of mib MiB: a sparse file,
// formatted by mkfs.hfsplus, which writes only metadata.
func CreateHFS(ctx context.Context, r proc.Runner, img string, mib int, volname string) error {
	f, err := os.OpenFile(img, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("image already exists: %s", img)
		}
		return err
	}
	err = f.Truncate(int64(mib) << 20)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = r.Run(ctx, proc.Cmd{Name: "mkfs.hfsplus", Args: []string{"-v", volname, img}})
		if err != nil {
			err = fmt.Errorf("mkfs.hfsplus failed on %s: %w", img, err)
		}
	}
	if err != nil {
		os.Remove(img)
	}
	return err
}

// CreateHFSGPT makes img a GPT disk with one Apple HFS+ partition at
// 1 MiB holding an HFS+ volume of mib MiB that fills it exactly -- the
// kernel reads the alternate volume header from the end of the block
// device, so a volume one MiB short of its partition does not mount.
// mkfs.hfsplus cannot write at an offset, so it formats a separate
// sparse file whose non-empty regions are then copied in.
func CreateHFSGPT(ctx context.Context, r proc.Runner, img string, mib int, volname string) (err error) {
	if _, err := os.Lstat(img); err == nil {
		return fmt.Errorf("image already exists: %s", img)
	}
	vol := img + ".hfs-tmp"
	os.Remove(vol) // our own temp name, left by an interrupted run
	if err := CreateHFS(ctx, r, vol, mib, volname); err != nil {
		return err
	}
	defer os.Remove(vol)

	out, err := os.OpenFile(img, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			os.Remove(img)
		}
	}()
	sectors := uint64(mib+2) * 2048
	if err := out.Truncate(int64(sectors) * diskimg.SectorSize); err != nil {
		return err
	}
	part := diskimg.Partition{
		Type: diskimg.TypeAppleHFS, GUID: diskimg.DerivedGUID("installer media hfs " + volname),
		Name: volname, FirstLBA: 2048, LastLBA: 2048 + uint64(mib)*2048 - 1,
	}
	if err := diskimg.WriteGPT(out, sectors, diskimg.DerivedGUID("installer media disk"), []diskimg.Partition{part}); err != nil {
		return err
	}
	if err := copySparse(out, 2048*diskimg.SectorSize, vol); err != nil {
		return fmt.Errorf("cannot copy the volume into %s: %w", img, err)
	}
	return out.Sync()
}

// copySparse writes src's non-zero 1 MiB blocks into dst at off; the
// rest stays a hole. mkfs.hfsplus writes about 21 MB of a 6.6 GB volume.
func copySparse(dst *os.File, off int64, src string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	buf := make([]byte, 1<<20)
	zero := make([]byte, 1<<20)
	for pos := int64(0); ; {
		n, rerr := io.ReadFull(in, buf)
		if n > 0 && !bytes.Equal(buf[:n], zero[:n]) {
			if _, err := dst.WriteAt(buf[:n], off+pos); err != nil {
				return err
			}
		}
		pos += int64(n)
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			return nil
		}
		if rerr != nil {
			return rerr
		}
	}
}

const (
	hfsUnmounted    = 0x00000100
	hfsInconsistent = 0x00000800
)

// MarkClean marks an HFS+ volume cleanly unmounted, in place, from the
// host: Linux's hfsplus mounts read-only, silently, a volume whose header
// does not say so -- the state of any media a QEMU guest has booted --
// and -o force does not help (lib/hfs.sh has the kernel source's reason).
// It sets kHFSVolumeUnmountedBit and clears kHFSVolumeInconsistentBit in
// the volume header and the alternate header. THIS IS NOT A FILESYSTEM
// CHECK: use it on a volume nothing was writing to.
func MarkClean(img string, start int64) ([]string, error) {
	f, err := os.OpenFile(img, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	var geo [8]byte
	if _, err := f.ReadAt(geo[:], start+1024+40); err != nil {
		return nil, fmt.Errorf("cannot read the volume header at %d: %w", start+1024, err)
	}
	length := int64(binary.BigEndian.Uint32(geo[0:4])) * int64(binary.BigEndian.Uint32(geo[4:8]))
	if length <= 0 || start+length > fi.Size() {
		return nil, fmt.Errorf("volume at %d claims %d bytes, which does not fit in %s", start, length, img)
	}
	var report []string
	for _, where := range []int64{start + 1024, start + length - 1024} {
		var head [8]byte
		if _, err := f.ReadAt(head[:], where); err != nil {
			return report, err
		}
		if sig := string(head[:2]); sig != "H+" && sig != "HX" {
			return report, fmt.Errorf("no HFS+ volume header at offset %d (found %q)", where, head[:2])
		}
		attrs := binary.BigEndian.Uint32(head[4:8])
		fixed := (attrs | hfsUnmounted) &^ hfsInconsistent
		if fixed == attrs {
			report = append(report, fmt.Sprintf("%d: already clean (0x%08x)", where, attrs))
			continue
		}
		var w [4]byte
		binary.BigEndian.PutUint32(w[:], fixed)
		if _, err := f.WriteAt(w[:], where+4); err != nil {
			return report, err
		}
		report = append(report, fmt.Sprintf("%d: attributes 0x%08x -> 0x%08x", where, attrs, fixed))
	}
	return report, f.Sync()
}
```

Note that `hfs_create_gpt`'s sgdisk writes random GUIDs, while Go
derives its GUIDs (phase 3's Ruling 6). The parity test compares
geometry, type and name, not GUIDs.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/media/ -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS, with both parity tests running here.

- [ ] **Step 5: Commit**

```bash
git add internal/media
git commit   # subject: "media: HFS+ disk images and mark-clean, as lib/hfs.sh makes them, without sgdisk or dd"
```

---

### Task 5: Apple's checksums, the required files, and the injectables (`internal/media`)

**Files:**
- Create: `internal/media/apple.go`, `internal/media/inject.go`, `internal/media/apple_test.go`, `internal/media/inject_test.go`

**Interfaces:**
- Consumes: `vmguest.Files` (`media/apple-packages.sha256`, `image/autoinstall/*`).
- Produces:
  - `RequiredFiles() []string`, the 19 paths.
  - `CheckAppleSums(sums []byte) (problems []string, err error)`.
  - `const FirstbootPkgName = "mqg-firstboot.pkg"`
  - `type Injectables struct{ Autoinstall bool; FirstbootPkg string; ExtraPkgs []string }`
  - `(Injectables) WriteTar(w io.Writer, log func(string, ...any)) error`
  - `AddToCollection(collection []byte, entry string) ([]byte, int, error)`, which returns the new bytes and the package count.
  - `AutoinstallFiles`, a table of source, destination and mode.

- [ ] **Step 1: Write the failing tests**

1. **`TestRequiredFilesMatchTheScript`.** Run only with bash. The output
   of `media/verify-installer-img.sh --required` equals `RequiredFiles()`,
   in order.
2. **`TestApplesPinnedSumsCoverThePackages`.**
   - Every non-comment line of the embedded `apple-packages.sha256` is
     64 lowercase hex characters, two spaces, and `./<name>`.
   - The names are exactly the 16 files of `RequiredFiles()` under
     `System/Installation/Packages/`.
3. **`TestCheckAppleSums`.**
   - The pinned values, given as `<sha>  <name>` without `./`, give no
     problems and a nil error.
   - One value changed and one line removed give exactly:
     ```
     <name1>: FAILED -- <got> is not what Apple shipped (<want>)
     <name2>: MISSING -- the media does not have it
     ```
     sorted, with a non-nil error.
4. **`TestCheckAppleSumsMatchesTheShell`.** Run only with bash, awk and
   sort. The same two fixture files go through
   `media/verify-installer-img.sh --check-sums FILE`. The shell prints
   its problems indented by four spaces on stderr; each one, with the
   indent removed, is one of Go's lines. The exit status is 0 or 1 to
   match Go.
5. **`TestAddToCollection`.**
   - The embedded collection plus
     `/System/Installation/Packages/mqg-firstboot.pkg` equals the
     original with `\t<string>/System/Installation/Packages/mqg-firstboot.pkg</string>\n`
     inserted before the first `</array>`, and the count is 3.
   - Adding it again returns the input unchanged, with the same count.
   - A collection with no `</array>` is refused.
   - A collection that no longer parses after the insert is refused:
     for example, one whose `<array>` is never closed before `</plist>`.
6. **`TestTheInjectablesTar`.**
   - `Injectables{Autoinstall: true, FirstbootPkg: p, ExtraPkgs: []string{a, b}}`
     writes a tar holding exactly these, and no directory entries:
     - `private/etc/rc.cdrom.local`, mode 0755, the embedded `autoinstall.sh`;
     - `System/Installation/Packages/Extras/minstallconfig.xml`, mode 0644;
     - `System/Installation/Packages/OSInstall.collection`, mode 0644, with the first-boot entry added;
     - `System/Installation/Packages/mqg-firstboot.pkg`, mode 0644, with p's bytes;
     - `System/Installation/Packages/<base a>` and `<base b>`, mode 0644.
   - Every entry has uid and gid 0 and a fixed mtime.
   - Without `FirstbootPkg`, the collection is the embedded bytes,
     unchanged.
   - With `Autoinstall: false`, the tar is empty: zero entries, and a
     valid end-of-archive.
7. **`TestTwoExtrasWithOneBasenameAreRefused`.** Two extras whose
   basename is the same would overwrite each other on the media, so the
   error names both.

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement**

`internal/media/apple.go`:

```go
package media

import (
	"fmt"
	"io/fs"
	"sort"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
)

// RequiredFiles is what an install cannot proceed without: the
// bootloader, the installer's disk image and its chunklist, and the
// sixteen files of Packages (verify-installer-img.sh's REQUIRED).
func RequiredFiles() []string {
	f := []string{
		"System/Library/CoreServices/boot.efi",
		"System/Installation/BaseSystem.dmg",
		"System/Installation/BaseSystem.chunklist",
	}
	for _, p := range []string{"OSInstall.mpkg", "OSInstall.pkg", "OSUpgrade.pkg", "AdditionalEssentials.pkg",
		"AdditionalSpeechVoices.pkg", "AsianLanguagesSupport.pkg", "BaseSystemBinaries.pkg",
		"BaseSystemResources.pkg", "BSD.pkg", "Essentials.pkg", "InstallableMachines.plist",
		"JavaEssentials.pkg", "JavaTools.pkg", "MediaFiles.pkg", "OxfordDictionaries.pkg", "X11redirect.pkg"} {
		f = append(f, "System/Installation/Packages/"+p)
	}
	return f
}

// parseSums reads "<sha256>  <name>" lines, skipping comments, with a
// leading ./ removed from each name.
func parseSums(b []byte) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		m[strings.TrimPrefix(f[1], "./")] = f[0]
	}
	return m
}

// CheckAppleSums holds checksums computed elsewhere -- in the microVM,
// which is what reads the media now that the host mounts nothing --
// against what Apple shipped, a constant (media/apple-packages.sha256),
// never against the source: a bad byte out of dmg2img would be copied
// faithfully and then verified as correct.
func CheckAppleSums(sums []byte) ([]string, error) {
	pinned, err := fs.ReadFile(vmguest.Files, "media/apple-packages.sha256")
	if err != nil {
		return nil, err
	}
	want, got := parseSums(pinned), parseSums(sums)
	var problems []string
	for name, w := range want {
		g, ok := got[name]
		switch {
		case !ok:
			problems = append(problems, name+": MISSING -- the media does not have it")
		case g != w:
			problems = append(problems, fmt.Sprintf("%s: FAILED -- %s is not what Apple shipped (%s)", name, g, w))
		}
	}
	sort.Strings(problems)
	if len(problems) > 0 {
		return problems, fmt.Errorf("%d of Apple's %d packages are not what Apple shipped", len(problems), len(want))
	}
	return nil, nil
}
```

The shell's `sort` follows the locale, and Go's `sort.Strings` is
bytewise. Apple's names are ASCII, and the parity test's two problem
lines differ at their first character, so the two agree. Keep the
parity test's names to ASCII.

`internal/media/inject.go`:

```go
package media

import (
	"archive/tar"
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	vmguest "github.com/Mavergreen/vm-guest"
)

// FirstbootPkgName is the first-boot payload's name on the media -- fixed,
// not taken from its source, so OSInstall.collection cannot drift from it.
const FirstbootPkgName = "mqg-firstboot.pkg"

// An AutoinstallFile is one of Apple's unattended-install hooks, which
// /etc/rc.install reads (image/autoinstall/): its source, where it goes
// on the media, and its mode -- rc.cdrom.local must be executable or
// rc.install skips it silently.
type AutoinstallFile struct {
	Source, Dest string
	Mode         int64
}

var AutoinstallFiles = []AutoinstallFile{
	{"autoinstall.sh", "private/etc/rc.cdrom.local", 0o755},
	{"minstallconfig.xml", "System/Installation/Packages/Extras/minstallconfig.xml", 0o644},
	{"OSInstall.collection", "System/Installation/Packages/OSInstall.collection", 0o644},
}

// Injectables is what a build adds to the media beyond Apple's files.
type Injectables struct {
	Autoinstall  bool
	FirstbootPkg string   // installed by the OS installer, listed in OSInstall.collection
	ExtraPkgs    []string // carried beside it, NOT listed: firstboot.sh installs them
}

var tarTime = time.Unix(0, 0)

// WriteTar writes the injectables as a tar of FILES ONLY, named for
// where they go on the media: a directory entry would set the mode of a
// directory Apple's media already has (it made five of them
// group-writable once). The guest untars it onto the volume before the
// ownership pass, which is what makes these root-owned.
func (in Injectables) WriteTar(w io.Writer, log func(string, ...any)) error {
	tw := tar.NewWriter(w)
	if !in.Autoinstall {
		return tw.Close()
	}
	add := func(name string, mode int64, data []byte) error {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(data)),
			ModTime: tarTime, Typeflag: tar.TypeReg, Format: tar.FormatPAX}); err != nil {
			return err
		}
		_, err := tw.Write(data)
		if log != nil {
			log("  %s (%o, %d bytes)", name, mode, len(data))
		}
		return err
	}
	for _, f := range AutoinstallFiles {
		data, err := fs.ReadFile(vmguest.Files, "image/autoinstall/"+f.Source)
		if err != nil {
			return err
		}
		if f.Source == "OSInstall.collection" && in.FirstbootPkg != "" {
			var n int
			if data, n, err = AddToCollection(data, "/System/Installation/Packages/"+FirstbootPkgName); err != nil {
				return err
			}
			if log != nil {
				log("OSInstall.collection now lists %d package(s)", n)
			}
		}
		if err := add(f.Dest, f.Mode, data); err != nil {
			return err
		}
	}
	pkgs := map[string]string{}
	if in.FirstbootPkg != "" {
		pkgs[FirstbootPkgName] = in.FirstbootPkg
	}
	for _, e := range in.ExtraPkgs {
		base := filepath.Base(e)
		if prev, dup := pkgs[base]; dup {
			return fmt.Errorf("%s and %s would both be System/Installation/Packages/%s on the media", prev, e, base)
		}
		pkgs[base] = e
	}
	var names []string
	for n := range pkgs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		data, err := os.ReadFile(pkgs[n])
		if err != nil {
			return err
		}
		if err := add("System/Installation/Packages/"+n, 0o644, data); err != nil {
			return err
		}
	}
	return tw.Close()
}

// AddToCollection inserts one package into OSInstall.collection as a
// line of text before </array> -- not a plist round-trip, which would drop
// the comment explaining why OSInstall.mpkg is listed twice -- and then
// parses the result, because an unparseable collection fails the install
// with a dialog and nothing written.
func AddToCollection(collection []byte, entry string) ([]byte, int, error) {
	line := "\t<string>" + entry + "</string>\n"
	text := string(collection)
	if !strings.Contains(text, line) {
		i := strings.Index(text, "</array>")
		if i < 0 {
			return nil, 0, errors.New("OSInstall.collection has no </array> to add the payload before")
		}
		text = text[:i] + line + text[i:]
	}
	pkgs, err := collectionEntries([]byte(text))
	if err != nil {
		return nil, 0, fmt.Errorf("OSInstall.collection does not parse after the edit: %w", err)
	}
	found := false
	for _, p := range pkgs {
		found = found || p == entry
	}
	if !found {
		return nil, 0, fmt.Errorf("%s is not in OSInstall.collection after editing", entry)
	}
	return []byte(text), len(pkgs), nil
}

// collectionEntries is the plist's top-level array of strings:
// <plist><array><string>...</string>...</array></plist>. A strict
// decoder, so an element left open or closed out of order is an error.
func collectionEntries(b []byte) ([]string, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	d.Strict = true
	var (
		stack    []string
		entries  []string
		cur      strings.Builder
		sawArray bool
	)
	for {
		tok, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			stack = append(stack, t.Name.Local)
			sawArray = sawArray || pathIs(stack, "plist", "array")
			cur.Reset()
		case xml.EndElement:
			if pathIs(stack, "plist", "array", "string") {
				entries = append(entries, cur.String())
			}
			stack = stack[:len(stack)-1]
		case xml.CharData:
			cur.Write(t)
		}
	}
	if len(stack) != 0 {
		return nil, fmt.Errorf("<%s> is never closed", stack[len(stack)-1])
	}
	if !sawArray {
		return nil, errors.New("no top-level <array>")
	}
	return entries, nil
}

func pathIs(stack []string, want ...string) bool {
	if len(stack) != len(want) {
		return false
	}
	for i := range want {
		if stack[i] != want[i] {
			return false
		}
	}
	return true
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/media/ -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS. Both parity tests run here.

- [ ] **Step 5: Commit**

```bash
git add internal/media
git commit   # subject: "media: Apple's pinned checksums, the files an install needs, and the injectables as a tar"
```

---

### Task 6: Building the media (`internal/media/build.go`)

**Files:**
- Create: `internal/media/build.go`, `internal/media/build_test.go`

**Interfaces:**
- Consumes: Tasks 1, 2 (`privops.Disk`), 4 and 5; `lock.Acquire`; `fetch.SHA256File`; `vmguest.Files`.
- Produces:
  - `const ReferencePartitionBytes = 6550020096`, `MarginMiB = 512`, `VolumeName = "OS X Base System"`
  - `BasePartMiB() int`, which is 6759.
  - `UpdatesExtraMiB(pkgs []string) (int, error)`, which is 0 for none.
  - ```go
    type MicroVM interface {
        Run(ctx context.Context, target string, payload []byte, disks []privops.Disk) ([]byte, error)
        Missing() []string
    }
    ```
    `privops.Backend` satisfies it, and tests fake it.
  - ```go
    type Options struct {
        Injectables                  // embedded
        ExtraSpaceMiB int
        Force, KeepWork bool
    }
    ```
  - `type Builder struct{ Paths config.Paths; Runner proc.Runner; VM MicroVM; PID int; Log func(string, ...any) }`
  - `(*Builder) Describe(w io.Writer, esd string, o Options)`
  - `(*Builder) Build(ctx, esd string, o Options) (string, error)`, which returns `Paths.InstallerMedia()`.

- [ ] **Step 1: Write the failing tests**

`internal/media/build_test.go`. A fake `MicroVM` recognises each payload
by comparing it with the embedded scripts, and answers as the real
guest would:
- **extract-basesystem:** writes N bytes of fixture data into the raw
  disk's file at offset 0, and prints
  `MQG-BASESYSTEM-BYTES N`, `MQG-BASESYSTEM-SHA256 <sha of those bytes>`
  and `MQG-PRIVOPS-OK rc=0`.
- **assemble:** prints `MQG-SUM-ESD <sha>  <name>` for every pinned
  package, using the pinned values, then OK.
- **fix-ownership:** OK.
- **verify-packages:** `MQG-SUM-MEDIA` lines, like assemble's, then OK.

The fake Runner handles `dmg2img -s -i X -o Y` by writing a few bytes to
Y, and `mkfs.hfsplus` as in Task 4. The ESD is a small fixture file.

1. **`TestBuildMakesTheMedia`.**
   - `Build` returns `<home>/build/installer-media.img`.
   - No `.building` file is left.
   - The sidecar is exactly three lines:
     ```
     # sha256 of installer-media.img as built at <RFC3339 UTC>
     # Mounting the image invalidates this: HFS+ records the mount
     # in its volume header, and a read-write mount rewrites it.
     <sha of the image>  installer-media.img
     ```
   - The work files are gone and `work/media` was removed.
   - The lock directory is gone.
2. **`TestPassOrderAndDisks`.** The four MicroVM calls are, in order:
   - extract, with target `…/installer-media.img.building`, disks
     `[ro work/media/esd.img, raw work/media/basesystem.dmg]`;
   - assemble, with `[ro basesystem.img, ro esd.img, raw inject.tar]`;
     the tar is present only with `Autoinstall`;
   - fix-ownership, with no disks;
   - verify-packages, with no disks.

   The assembly (with the injectables) happens before the ownership
   pass, and nothing is written after it.
3. **`TestDmg2imgRuns`.** Exactly two `dmg2img` calls:
   `-s -i <esd> -o work/media/esd.img`, then
   `-s -i work/media/basesystem.dmg -o work/media/basesystem.img`.
4. **`TestBaseSystemMustSurviveTheTrip`.**
   - The fake extract reports a sha that differs from the bytes it
     wrote.
   - The error says `BaseSystem.dmg did not survive the trip out of the microVM`.
   - No media is left, and no `.building` file.
5. **`TestAConversionThatIsNotApplesIsNamed`.**
   - The fake assemble reports one wrong ESD sum.
   - The error begins `the ESD does not contain what Apple shipped`.
   - The problem line is logged.
   - The verify pass never ran.
6. **`TestACopyThatIsNotApplesIsNamed`.** The fake verify reports one
   missing package. The error begins
   `the media does not contain what Apple shipped`, and no media is
   renamed into place.
7. **`TestBuildRefusesWithoutTheBackend`.** With `Missing()` non-empty,
   the error lists every missing line, and neither dmg2img nor mkfs
   runs.
8. **`TestBuildRefuses`** is a table:
   - no ESD: `no InstallESD.dmg at <path> -- run vmavs fetch esd`;
   - a first-boot package without the `xar!` magic: `is not a flat package (no xar magic)`;
   - an extra package that doesn't exist: `no such --extra-pkg`;
   - an existing media without `Force`: `exists; pass --force to replace it`, with the file untouched;
   - a negative `ExtraSpaceMiB`: refused.

   Each is refused before any Runner call, except the existing-media
   case, which comes after the lock.
9. **`TestForceReplacesTheMedia`.** An existing media and its sidecar
   are replaced by new ones.
10. **`TestAnotherBuilderIsRefused`.** A lock directory whose pid file
    names a live process gives an error naming that pid, and nothing
    runs.
11. **`TestKeepWorkKeepsTheConversions`.** With `KeepWork`,
    `work/media/esd.img` and the others remain.
12. **`TestNothingMounts`.** Across a whole build, no Runner call is
    named `mount`, `umount`, `losetup`, `udisksctl` or `sgdisk`.
13. **`TestThePartitionIsSizedFromTheReference`.**
    - `BasePartMiB()` is 6759.
    - The fake mkfs is given a file of `(6759+300) << 20` bytes when
      `ExtraSpaceMiB` is 300: check the Truncate size it sees.
    - `UpdatesExtraMiB([]string{a 1.5 MiB file, a 10-byte file})` is
      `ceil((1.5 MiB + 10) / 1 MiB) + 64`, which is 66.
14. **`TestDescribeTouchesNothing`.**
    - `Describe` on an empty home, with `Autoinstall`, a first-boot
      package and two extras, prints these lines:
      - `output              <home>/build/installer-media.img`;
      - `partition 1 type    AF00 (Apple HFS+)`;
      - `partition 1 size    6759 MiB = 7087325184 bytes`;
      - `disk size           6761 MiB = 7089422336 bytes`;
      - `volume name         OS X Base System`;
      - the three autoinstall destinations with their modes;
      - `System/Installation/Packages/mqg-firstboot.pkg`;
      - both extras' basenames.
    - The home is still empty afterwards.

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement `internal/media/build.go`**

Write `Build` to the step list in Facts. Keep the shell's comments'
reasons in the Go doc comments, shortened. The points that differ from a
line-by-line port:
- **The work area.** Work files live in `Paths.MediaWork()`:
  `esd.img`, `basesystem.dmg`, `basesystem.img`, `inject.tar` and
  `console.txt`. Remove any stale ones first: they are ours, and a stale
  one silently becoming the media costs an hour.
- **The lock** is `lock.Acquire(Paths.InstallerMedia()+".lock", b.PID)`.
  Log a takeover as `taking over a stale lock left by pid <n>`, or
  `… by an unknown pid`, and release it with `defer`.
- **Order of checks.** The ESD, the package magic and the space are
  checked before the lock. The existing media is checked after it, as in
  the shell.
- **The `.building` file.** The image is created as
  `InstallerMedia()+".building"`, with a stale one removed first. It is
  renamed over the media only after the verify pass. The sidecar is
  staged as a temp file beside it, then the image is renamed, then the
  sidecar. On any error the `.building` file is removed.
- **Pass 1's raw disk.** `basesystem.dmg` is made sparse, as large as
  `esd.img` (`Truncate`), before pass 1. After the pass it is truncated
  to `MQG-BASESYSTEM-BYTES`, and `fetch.SHA256File` must equal
  `MQG-BASESYSTEM-SHA256`.
- **Marker values** come from `privops.Markers(console, name)`. A
  missing or non-numeric byte count is
  `the microVM did not report a BaseSystem.dmg size`.
- **The checksum lines** for `CheckAppleSums` are the `MQG-SUM-ESD` and
  `MQG-SUM-MEDIA` markers, joined with newlines. Log each problem line,
  indented four spaces, then return the shell's error:
  - ESD: `the ESD does not contain what Apple shipped. The suspects are dmg2img and the Linux hfsplus read of its output, in that order -- not the media, whose copy of them has not been checked yet, and not media/apple-packages.sha256, whose values were read from two images that share no code`.
  - Media: `the media does not contain what Apple shipped. This is the fault that a finished copy, and a read-back through the same cache, both fail to report. Re-run with --force`.
- **The payloads** are `fs.ReadFile(vmguest.Files, "media/privops/<name>.sh")`.
- **The log lines** follow the shell's:
  - `converting InstallESD.dmg to raw (about 5 GB)`;
  - `bringing BaseSystem.dmg out of the ESD (microVM pass 1 of 4)`;
  - `assembling the media inside the microVM (pass 2 of 4)`;
  - `restoring root ownership (microVM pass 3 of 4)`;
  - `reading the finished media back in a microVM of its own (pass 4 of 4)`;
  - `built <out> in <duration>`;
  - `size <n> bytes, sha256 <sha>`.

`Describe` prints the shell's `--describe` text, with Go's paths:
- `output` is `InstallerMedia()`;
- `source` is the ESD path given;
- `work area` is `MediaWork()`.

Keep its layout and wording. The shell's sentence about the margin
names `MQG_MEDIA_MARGIN_MIB` nowhere, so it needs no change.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/media/ -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/media
git commit   # subject: "media: build the installer media in four microVM passes, checked against Apple, renamed into place only when it is right"
```

---

### Task 7: The content digest (`internal/media/digest.go`)

**Files:**
- Create: `internal/media/digest.go`, `internal/media/digest_test.go`

**Interfaces:**
- Produces:
  - `type Digest struct{ SHA256 string; Files, Bytes int64 }`
  - `(Digest) String() string`, which gives
    `<sha>  <files> files  <bytes> bytes  0 unreadable`.
  - `(*Builder) ContentDigest(ctx, img string, listing io.Writer) (Digest, error)`.
    A nil `listing` means the listing is not wanted.

- [ ] **Step 1: Write the failing tests**

The fake MicroVM for the `content-digest.sh` payload writes a fixture
listing (three lines) into the raw disk, `disks[1].Path`, at offset 0,
and prints:
- `MQG-DIGEST-FILES 3`
- `-HASHED 3`
- `-BYTES 1234`
- `-SIZE <len>`
- `-SHA256 <sha of listing>`
- OK

The tests:
1. **`TestDigest`.**
   - The result's `String()` is `<sha of listing>  3 files  1234 bytes  0 unreadable`.
   - `listing` receives the three lines exactly.
   - The target was a fresh 32 MiB scratch volume named `MQG DIGEST`:
     check the fake mkfs call's `-v`.
   - The disks were `[ro <img>, raw <listing file>]`.
   - The temp directory is gone afterwards.
2. **`TestDigestRefusesWhatIsNotWholeAndRight`** is a table:
   - `FILES 3` but `HASHED 2` gives an error saying the volume is
     unreadable in places.
   - A non-numeric count gives
     `the microVM did not report a usable count`.
   - A listing sha that differs from the host's read gives
     `the listing did not survive the trip out of the microVM`.
3. **`TestDigestNeedsAnImage`.** A missing image is refused before the
   microVM runs.

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement**

Port `media/content-digest.sh`'s host side:
1. Make a temp directory.
2. Create the scratch volume `CreateHFS(…, 32, "MQG DIGEST")`.
3. Create a sparse 256 MiB listing file.
4. Run the embedded `media/privops/content-digest.sh` payload with
   `[ro img, raw listing]`.
5. Read the five markers, taking the first of each, and validate them.
6. Truncate the listing to SIZE and check its sha256.
7. Copy it to `listing` if one was given.
8. Return the `Digest`.

The doc comment keeps the shell's two reasons:
- the listing goes out on a raw disk, because the console is about
  4 MB at one character at a time;
- a mismatched count is refused, not digested.

- [ ] **Step 4: Run the tests**

- [ ] **Step 5: Commit**

```bash
git add internal/media
git commit   # subject: "media: the content digest, read by the microVM and checked on the way out"
```

---

### Task 8: `vmavs media`, the doctor row, and the docs

**Files:**
- Create: `internal/cli/media.go`, `internal/cli/media_test.go`
- Modify: `internal/cli/cli.go` (the table), `internal/cli/doctor.go`, `internal/doctor/doctor.go`, their tests
- Modify: `README.md`, and the spec: §2, §3, §5

**Interfaces:**
- Produces:
  - The subcommand
    `vmavs media [--autoinstall] [--firstboot-pkg PATH] [--extra-pkg PATH]... [--extra-space-mib N] [--force] [--keep-work] [--describe] [--privops-timeout DURATION]`.
  - The action `vmavs media digest [--list] IMAGE`.
  - A `media` readiness row in doctor.

- [ ] **Step 1: Write the failing tests**

`internal/cli/media_test.go`. `cmdMedia` reaches its builder through a
variable, as `firmware` does, so tests can record calls:

```go
type mediaBuilder interface {
	Build(ctx context.Context, esd string, o media.Options) (string, error)
	Describe(w io.Writer, esd string, o media.Options)
	ContentDigest(ctx context.Context, img string, listing io.Writer) (media.Digest, error)
}

var newMediaBuilder = func(b *media.Builder) mediaBuilder { return b }
```

1. **`TestMediaBuildsWithTheFlagsItWasGiven`.** Run
   `vmavs media --firstboot-pkg P --extra-pkg A --extra-pkg B --extra-space-mib 70 --force`.
   The recorded `Build` got:
   - the ESD path from the fetch, served by an httptest osrecovery
     fixture or adopted from a fixture legacy home, whichever phase 2's
     cli tests already set up. Reuse theirs.
   - `Options{Injectables{Autoinstall: true, FirstbootPkg: P, ExtraPkgs: [A B]}, 70, true, false}`.

   Stdout is the returned path, and the exit code is 0.
2. **`TestMediaFlagsAndTargetsInAnyOrder`.** It uses `parseInterleaved`:
   `vmavs media --force digest --list img` is refused, and so is
   `vmavs media digest img --force`. `digest` takes only `--list`. The
   error is a usage error, exit 2.
3. **`TestMediaDescribeFetchesNothing`.** `vmavs media --describe` calls
   `Describe` with the path the ESD will have, and makes no HTTP request
   and no `Build` call.
4. **`TestMediaDigest`.**
   - `vmavs media digest img` prints `Digest.String()` and a newline.
   - With `--list`, the listing comes first.
   - A missing image exits 1.
5. **`TestMediaRefusesBadArguments`.** Each exits 2:
   - `--extra-space-mib -1`;
   - `--extra-space-mib x`;
   - `--privops-timeout 0`;
   - an unknown action (`vmavs media foo`).
6. **`TestMediaPrivopsTimeout`.** `--privops-timeout 30m` reaches the
   Backend's `Timeout`: capture the `*media.Builder` in the stub.

`internal/doctor/doctor_test.go`:

7. **`TestDoctorMediaRow`.**
   - The `media` row lists missing `dmg2img`, `mkfs.hfsplus`, and each
     `privops.Backend.Missing()` line.
   - `Host` gains `Privops func() []string`, which is the backend's
     `Missing`. When it is nil, nothing is checked.
   - The row is ready when everything is present.
   - The verdict is unchanged: GO still depends only on `run`.

- [ ] **Step 2: Run them and watch them fail**

- [ ] **Step 3: Implement**

`internal/cli/media.go`:
- **The help text** explains:
  - what the media is;
  - the four passes;
  - that nothing mounts;
  - that it checks against Apple's pinned checksums;
  - the flags, with the shell's `--extra-pkg` explanation of why extras
    are not in the collection;
  - the `digest` action;
  - that the ESD is fetched and verified first (`vmavs fetch esd`),
    adopting the shell tree's download.
- **Parsing:** `parseInterleaved`. Its first non-flag argument, if any,
  must be `digest`.
- **The build:**
  1. Get the ESD path with `fetch.Getter.InstallESD`, using the same
     adoption candidates as `cmdFetch`'s `esd` case. Reuse its code; do
     not duplicate it.
  2. Build `privops.NewBackend(runner(e), config.QEMU(e.Getenv), logf)`,
     and set `Timeout` from the flag.
  3. Build `media.Builder{Paths, Runner, VM: backend, PID: pid(e), Log}`.
     `pid(e)` is the same helper `run` uses for its state file's pid.
  4. Call `Build`.
- **`--describe`** derives the ESD's cache path without fetching. That
  is `Paths.CacheFile(<the registry's apple-installesd-10.9.5 sha>, "InstallESD.dmg")`,
  or whatever phase 2 named it; read `fetch.InstallESD` for the real
  filename.

`internal/doctor/doctor.go`: add the `media` row after `firmware`.
`internal/cli/doctor.go` fills `Host.Privops` from the real backend.

`README.md`, "The Go vmavs (in progress)":
- Add `vmavs media` with one paragraph, and `vmavs media digest`.
- Say what it needs:
  - `dmg2img` and `mkfs.hfsplus`;
  - `qemu-system-x86_64` with KVM;
  - a static `busybox`;
  - a readable kernel.
- Say that it needs no `cpio`, no `sgdisk`, and no mount.

The spec:
- **§2's command block:** `vmavs media` with its flags, and `vmavs media digest`.
- **§3's "External tools that remain":**
  - `mkfs.hfsplus` and `dmg2img` stay.
  - Add a static `busybox` and a readable host kernel and modules, which
    the privops microVM boots. Add `modprobe`, `xz` and `zstd`, used
    only when present or needed.
  - The `7z` line becomes: only for the Mac-reference comparison in
    `media/verify-installer-img.sh`, which stays a second-tier shell
    tool (Ruling 6).
  - `cpio` is no longer needed.
- **§5's state block:** `build/` gains `installer-media.img`, and
  `work/` gains `media/`.

Grep the spec for `media` and `privops` so every line agrees. Leave §9
alone: Task 9 marks it.

- [ ] **Step 4: Run everything**

```bash
go vet ./... && go test -race -count=1 ./... && gofmt -l . && \
go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./... && \
for t in linux/amd64 darwin/amd64 darwin/arm64 netbsd/amd64; do GOOS=${t%/*} GOARCH=${t#*/} go build -o /dev/null ./cmd/vmavs || echo FAIL $t; done && \
./bin/run-tests.sh >/tmp/suite.log 2>&1; echo "shell $?"; bin/ingredient-fingerprint.sh | tail -1
```

- [ ] **Step 5: Commit**

```bash
git add internal/cli internal/doctor README.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md
git commit   # subject: "vmavs media: installer media from one command, and doctor says what the microVM needs"
```

---

### Task 9: Measure it, and say so

**Files:**
- Modify: `NOTES.md` (append only), and the spec's §9 phase-4 row.

This task builds real installer media twice, once with the shell and
once with Go, in two temp homes under `/tmp`. Record `date -u +%FT%TZ`
at each step.
- **Network:** all HTTP goes to a dead proxy. The ESD and the OpenSSH
  packages are adopted.
- **The shell tree's home is only read.** The first-boot package comes
  from `~/.local/share/mavericks-qemu-guest/payload/mqg-firstboot.pkg`,
  read-only.
- **Space:** each build needs about 20 GB of `/tmp`. Check `df` first.

- [ ] **Step 1: Build and set up**

```bash
go build -o out/vmavs ./cmd/vmavs
export DEAD='env -u NO_PROXY -u no_proxy HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9'
X=$(mktemp -d /tmp/vp4g.XXXXXX); Y=$(mktemp -d /tmp/vp4s.XXXXXX)
L=$HOME/.local/share/mavericks-qemu-guest
$DEAD VMAVS_HOME=$X ./out/vmavs fetch esd openssh     # adopted (copied: /tmp is another btrfs subvolume)
```

- [ ] **Step 2: The shell tree's media, as the reference**

```bash
mkdir -p $Y/media && ln $X/cache/*/InstallESD.dmg $Y/media/InstallESD.dmg
date -u +%FT%TZ
time $DEAD MQG_IMAGE_DIR=$Y ./media/build-installer-img.sh --autoinstall \
    --firstboot-pkg $L/payload/mqg-firstboot.pkg \
    --extra-pkg "$(ls $X/cache/*/OpenSSH-[0-9]*.pkg)" \
    --extra-pkg "$(ls $X/cache/*/OpenSSH-System-Replace-*.pkg)" > $Y/shell-build.log 2>&1
```

- [ ] **Step 3: Go's media**

```bash
date -u +%FT%TZ
time $DEAD VMAVS_HOME=$X ./out/vmavs media --firstboot-pkg $L/payload/mqg-firstboot.pkg \
    --extra-pkg "$(ls $X/cache/*/OpenSSH-[0-9]*.pkg)" \
    --extra-pkg "$(ls $X/cache/*/OpenSSH-System-Replace-*.pkg)" > $X/go-out.txt 2> $X/go-build.log
```

- [ ] **Step 4: Compare**

1. Digest both images with both implementations:
   ```bash
   ./out/vmavs media digest --list $Y/media/installer-linux.img > $X/shell-go.list
   ./out/vmavs media digest --list $X/build/installer-media.img > $X/go-go.list
   ./media/content-digest.sh --list $Y/media/installer-linux.img > $X/shell-sh.list
   ./media/content-digest.sh --list $X/build/installer-media.img > $X/go-sh.list
   ```
   Expected (REASONED): the same listing for both images, byte for byte,
   and the same digest line from both tools. Both builds run the same
   guest scripts over the same ESD, and the injected files are the same
   bytes.

   Any difference is a finding. Record the diff exactly.
2. Run
   `./media/verify-installer-img.sh --built $X/build/installer-media.img --reference $L/media/InstallMavericks.iso`.
   It reads both images read-only. Record its "required files" and
   "missing" sections next to the same run for the shell's media.
3. Record the times of both builds and both media's sizes, plus each
   pass's time from the logs.

- [ ] **Step 5: Clean up.** Remove `$X` and `$Y`, which this task
  created, including the temp homes' caches.

- [ ] **Step 6: NOTES.md and the spec**

Append a dated entry:
`## <date> — P8 — vmavs media builds the installer media, and it matches the shell tree's`.
It carries the commands and results of Steps 1–4, labelled MEASURED,
and the parity tests of Tasks 2–5 and what each compared.

Record what was not measured:
- an install from the Go-built media (phase 5);
- another host.

In the spec's §9, mark phase 4 delivered, with a pointer. First quote
the phase-4 row (`media`, privops) and check each item against what
shipped.

- [ ] **Step 7: Run everything; commit**

```bash
go test -race ./... && ./bin/run-tests.sh >/tmp/suite.log 2>&1; echo "shell $?"; bats tests/release.bats; bin/ingredient-fingerprint.sh | tail -1
git add NOTES.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md
git commit   # subject: "NOTES: vmavs media builds installer media with the shell tree's contents"
```

---

## Self-review

**Spec coverage** (spec §9, phase 4: `media`, privops; spec §3's `media/`,
`assets/privops/`):

| Requirement | Covered by |
|---|---|
| installer media assembly | Tasks 4, 5, 6 |
| the privops microVM driver | Tasks 2, 3 |
| the microVM's scripts embedded | Task 1 |
| `vmavs media` | Task 8 |
| locks (§5) | Task 1 |
| doctor reports the tools (§3) | Task 8 |
| parity with the shell tree, differences named (§7) | Tasks 2–5, 9 |
| carrying the bats knowledge (§7) | the mapping table above |
| measurement | Task 9 |

**Out of phase:**
- The media stage's freshness, the manifest's `mediacontent` and
  `smbios` rows, and marking the media clean before an install:
  phase 5. `MarkClean` and `ContentDigest` are ready for it.
- `verify-installer-img.sh`'s reference comparison and
  `privops-selftest.sh`: second-tier (Ruling 6).

**Types:**
- `privops.Backend`, `privops.Disk` and `privops.Markers` come from
  Tasks 2–3 and are used by Tasks 6–8.
- `media.MicroVM` is satisfied by `privops.Backend`. Compile-check it
  with `var _ media.MicroVM = privops.Backend{}` in a cli test.
- `media.Injectables` comes from Task 5 and is embedded in
  `media.Options` in Task 6.
- `lock.Acquire` comes from Task 1 and is used by Task 6.
- `config.Paths.InstallerMedia` and `MediaWork` come from Task 1 and are
  used by Tasks 6–8.
