# `vmavs` in Go: one integrated binary

Date: 2026-09-24
Status: design approved in conversation, pending review of this document
Decision record: `docs/decisions/0013-vmavs-is-a-go-program.md`

## 1. Why

The shipping plan (`2026-09-22-shipping-vmavs.md`) delivered `vmavs` as a
dispatcher over about thirty shell scripts. It works, and every piece
behind it is tested, but a stranger meets its seams at once:

- usage lines name `build-image.sh` and `vm/run.sh`;
- flags differ from script to script;
- nothing is shared across subcommands;
- the product's shape follows the scripts' shape. `run` boots development
  profiles, not the image `vmavs image` built, because that is what
  `vm/run.sh` did.

The user asked for an integrated, well-factored, consistent tool, in one
file. While restructuring, the language was reconsidered.

Go is chosen over shell, and over C, for reasons that are specific to this
app:

- **This session's worst bugs were shell hazards.** The release gate failed
  open three ways: SIGPIPE under `pipefail`, git's C-quoted names, and
  swallowed `cat-file` errors. `emit` exited 0 with a wrong template when a
  `die` inside process substitution vanished. Go's explicit errors remove
  that class.
- **One static binary, with its data embedded (`go:embed`), is the most
  literal form of "one file".**
- **The standard library replaces most host tools:** `net/http` with Go's
  own TLS (modern TLS even on 10.9), `crypto/sha256`, `archive/zip` and
  `archive/tar`, `x/crypto/ssh`, and GPT/FAT writers. That serves P9's goal
  of shrinking the host tool list (36 → about 7) independently of the build
  VM.
- **It cross-compiles** to Linux, macOS and NetBSD.
- **10.9 is covered.** The family's Go toolchain (`Mavergreen/golang`,
  1.26.8-mavericks.6) builds for 10.9. Tailscale and the Docker tools
  already ship through it.
- **C would carry this work badly.** It would need libcurl or OpenSSL (10.9's
  system TLS is dated), libarchive, libssh2 and a hand-rolled
  process-supervision layer. Each is a dependency to find on three
  operating systems, or a memory-safety risk in code that parses downloaded
  bytes and disk images.

## 2. Command surface

```
vmavs doctor                          can this host do it, per subcommand
vmavs fetch    [esd|openssh|updates] [--updates …] [--probe]   fetch pinned inputs (default: all of them)
vmavs firmware                        OpenCore + OVMF + the EFI image, from pinned source
vmavs media                           installer media
vmavs install                         target disk + unattended install
vmavs image    [--describe] [--freshness] [--stage a,b,…]   the whole chain
vmavs run      [--image NAME] [--keep]                      boot a built image
vmavs ssh      [--ssh-port N] [-- command…]                 a shell in the running guest
vmavs emit     packer                                       Packer template for the machine `run` boots
vmavs version | help
```

Changes from the shell `vmavs`:

- `boot-stack` is renamed `firmware`.
- `clone` is dropped: `run` makes its own throwaway overlay.
- `freshness` becomes `image --freshness`.
- `emit packer` no longer reads `.args` profiles.
- `triangulate`, `golden`, `compare` and `staleness` stay outside `vmavs`
  (§9).

**Conventions, the same for every subcommand:**

- **Help.** `-h`/`--help` comes from one mechanism, and each help text
  lives beside its command.
- **Exit codes.** 0 for success, 1 for failure, 2 for a usage error.
  `vmavs ssh -- CMD` exits with the remote command's own status.
- **Signals.** SIGINT, SIGTERM and SIGHUP (unless SIGHUP was already
  ignored when `vmavs` started) cancel the command in progress. For
  `run` that is the way to stop the VM: QEMU gets SIGTERM, the run
  directory is removed (unless `--keep`), and `vmavs` exits 0 -- it did
  what was asked. `ssh` closes the session and exits 130 (128+SIGINT,
  what a shell reports for a Ctrl-C) whichever of the three it was, with
  no error line.
- **Logging.** Log lines read `vmavs <cmd>: …` on stderr; stdout carries
  only a command's output (`version`, `--describe`, `emit` without
  `--out`).
- **Machine options.** One set, parsed once and accepted by `install`,
  `image`, `run` and `emit`: `--accel`, `--cpu`, `--memory`, `--smp`,
  `--nic`, `--ssh-port`, and `--image NAME` where it applies. Defaults live
  in `internal/config` and nowhere else. `ssh` names the port it connects
  to `--ssh-port` as well, so one port has one flag name everywhere.
- **Environment.** Only a few variables:
  - `VMAVS_HOME`, the state root;
  - `VMAVS_QEMU`, the QEMU binary;
  - `VMAVS_SSH_KEY`.

  The `MQG_*` names are not carried over.

## 3. Repository layout

```
go.mod                github.com/Mavergreen/vm-guest, go 1.26
cmd/vmavs/main.go     argv → cli.Run, exit code; nothing else
internal/
  cli/        subcommand table, shared flag parsing, help text, exit codes, logging
  config/     every default; VMAVS_HOME and the path layout (§5); machine options
  proc/       the one interface to external commands (Runner), with a
              recording fake for tests; timeouts via context
  pins/       sources.tsv parsing, fetch + sha256 verification, the download cache
  fetch/      esd, openssh, updates, kexts, edk2, opencorepkg
  firmware/   OpenCore and OVMF builds (orchestrate make/gcc/nasm/iasl),
              compiler and ccache checks, EFI image assembly
  diskimg/    GPT and FAT32 writers (replace sgdisk and mtools)
  media/      installer media assembly; the privops microVM driver
  payload/    the first-boot flat .pkg, including a xar writer (replaces mkflatpkg.py)
  machine/    THE machine definition (§4)
  manifest/   built-image manifests: parse, find, hardware, SSH facts
  vm/         run directories: overlay, NVRAM, state
  guest/      SSH client (x/crypto/ssh), screenshots over the QEMU monitor
  pipeline/   stages, input-hash freshness, manifest, ingredient fingerprint, locks
  emit/       Packer HCL from machine.Spec via hashicorp/hcl/v2/hclwrite
  doctor/     host checks and per-subcommand readiness
assets/       embedded with go:embed
  firmware/   config.plist, patches/
  guest/      firstboot.sh, postinstall, autoinstall/, the launchd plist
  privops/    the microVM's scripts
  pins/       sources.tsv, openssh version, apple-packages.sha256
```

`assets/` holds data and scripts that run somewhere other than the host,
inside the guest or the microVM. They stay files in the repository, so
they are reviewed and diffed as files, and they are compiled into the
binary. Renovate's managers and CI's pin checks point at their new paths.

Until phase 6, `embed.go` embeds these files from their current paths
(`assets/pins/sources.tsv`, `components/openssh/version`,
`boot/config/config.plist`, `media/apple-packages.sha256`,
`image/payload/firstboot.sh`, `image/payload/postinstall`,
`image/payload/com.mqg.firstboot.plist`), not from `assets/` as shown
above. The move to `assets/` happens together with the shell tree's
removal, because the shell tree, Renovate's `managerFilePatterns`, CI's
`verify-changed-sources.sh` and the path-keyed ingredient fingerprints all
read them at their current paths today; moving them sooner would change
every stage digest of every built image.

**Dependencies:**

- the standard library;
- `golang.org/x/crypto`, for SSH;
- `golang.org/x/term`, for the interactive shell's raw mode;
- `github.com/hashicorp/hcl/v2`, for `hclwrite` (MPL-2.0).

Nothing from Packer core (BUSL-1.1). There is no CLI framework: `flag`
plus a small subcommand table is enough.

**External tools that remain:**

- `qemu-system-x86_64` and `qemu-img`;
- the EDK II toolchain (`make`, a C compiler, `nasm`, `iasl`, `python3` for
  EDK II's own build scripts);
- `mkfs.hfsplus` and `dmg2img`, until HFS+ and DMG reading are
  reconsidered;
- `7z`, only for media verification.

`doctor` reports exactly this list, derived from the code that calls
these tools.

## 4. One machine

`machine.Spec` holds everything QEMU needs:

- accelerator, machine type, CPU, memory and SMP;
- NIC model and forwarded SSH port;
- the OVMF code image and this VM's own NVRAM file;
- the OpenCore image;
- the target disk;
- optional installer media.

`Spec.QEMUArgs()` renders the command line from today's
`image/build-image.sh` `qemu_args()`, the most complete of the three
copies in the shell tree. That includes `snapshot=on` on the OpenCore and
installer drives: writes to those must not persist.

| Constructor | Target disk | Installer | Used by |
|---|---|---|---|
| `machine.ForInstall` | a new qcow2 | attached | the `install` stage |
| `machine.ForVerify` | the built image | — | the `verify` stage |
| `machine.ForRun` | an overlay backed by the built image | — | `vmavs run` |

`emit packer` renders the same `Spec` as HCL with `hclwrite`:

- Packer's first-class fields (`machine_type`, `cpu_model`, `memory`,
  `cpus`, `disk_size`, `host_port_min`/`max`, `output_directory`,
  `vm_name`) take what they can;
- everything else goes into `qemuargs`, drives included, because qemuargs
  `-drive` replaces Packer's defaults;
- both plugins are declared in `required_plugins`.

These are the findings `packer validate` confirmed on 2026-09-24.

## 5. `run`, and state on disk

**`vmavs run [--image NAME] [--keep]`:**

1. Choose the image: `NAME`, or the image whose manifest was written most
   recently.
2. Create `run/<name>-<random>/` (`os.MkdirTemp`, mode 0700 -- not
   `<name>-<pid>`: a recycled pid would otherwise reuse, and silently
   truncate, another run's directory), holding, first, its locked state
   file (below), then a qcow2 overlay backed by the image and this VM's
   own copy of the NVRAM template.
3. Boot `machine.ForRun`. QEMU runs in the foreground, so Ctrl-C stops the
   VM.
4. Remove the run directory on exit, unless `--keep`.

SSH forwards on `127.0.0.1` only, on the port `vmavs ssh` defaults to
(2222): unbound, the guest's sshd (Apple's OpenSSH 6.2, with no other
access control) would be reachable from the network.

**`vmavs ssh`** uses `x/crypto/ssh`, not the `ssh` binary:

- it connects as `mavsuser` to `127.0.0.1:<port>`;
- it uses the key `vmavs image` authorized: `VMAVS_SSH_KEY`, else the
  search order today's `lib/sshkey.sh` defines;
- it ignores host keys, because every overlay has fresh ones.

For an image built with the stock OpenSSH 6.2 (`--no-openssh`), it enables
the legacy algorithms that version needs. Today's `ssh_opts()` in
`build-image.sh` records which ones.

**State**, all under `VMAVS_HOME` (default `~/.local/share/vmavs`):

```
images/   <name>.qcow2 and <name>.manifest — read-only once built
build/    firmware outputs, the OpenCore/EDK II trees, kexts, ccache
cache/    downloaded inputs, keyed by sha256
work/     per-build scratch: stage input-hash records, logs, monitor sockets
run/      per-run overlays and NVRAM — removed on exit
keys/     the generated SSH key pair
```

Every directory under `VMAVS_HOME` comes from `config.Paths`; no other
code places one there. The package that owns a directory names the files
inside it (`vm` a run directory's state, overlay, NVRAM and monitor
socket).

If `~/.local/share/mavericks-qemu-guest` exists and `VMAVS_HOME` does not,
`vmavs` says so and prints the `mv` that moves it. It moves nothing itself.

**Images built by the shell pipeline, phases 1–5.** The shell tree already
uses this layout for `images/`, `build/firmware/` and `keys/`. It differs
in one path: the OpenCore image lives at `work/opencore-p3.img` rather than
`build/opencore.img`. Until phase 6, `config.Paths` also looks at the old
location. So phase 1's `vmavs run` boots images the shell pipeline built,
and `run` and `ssh` can be measured before the Go pipeline exists. The
fallback is deleted with the shell tree.

**Locks.** A build takes a lock on its work directory. The lock is a
directory holding a pid, which is portable to 10.9, and a stale holder's
lock can be taken over, as the media lock does today.

A run has its own kind of lock: `run/<name>-<random>/state` (a
`key<TAB>value` file naming the image, the forwarded port, the pid, and
whether `--keep` was given) is held with an exclusive `flock` for as
long as the run is alive. `vmavs run` takes it blocking: the only thing
that can contend for a brand-new file's lock is another `vmavs`'s
momentary probe (below), and a non-blocking attempt would fail the run
for losing that race. `vmavs ssh` and a reaper (below)
tell a live run from a dead one by whether that lock is still held, not
by whether its recorded pid is running: a pid can be recycled, and
checking for one (`kill(pid, 0)`) cannot tell "no such process" apart
from "a different process now has it". The state file is created, locked,
and only then written to (in that order), so a concurrent reader never
sees a state file that exists but is not yet lockable, and all of that
happens before anything else goes into the run directory, so every run
directory `vmavs` made has a state file from its first slow step on.
Once QEMU is running, the run passes it the locked file as an inherited
descriptor, so the lock survives `vmavs run` itself being killed
outright (a `SIGKILL` it has no chance to release the lock for) for as
long as QEMU keeps running. That is REASONED from `flock(2)`'s
semantics: the unit test checks only that the (fake) QEMU command is
handed the file, and no real `vmavs run` has been killed to see it. For the same reason `vmavs run` never
unlocks the file explicitly: the lock belongs to the open file
description QEMU shares, so `LOCK_UN` would release QEMU's hold too; it
only closes its own descriptor. A `VMAVS_HOME` on NFS may not give
`flock` these semantics (depending on the client, it is emulated with
POSIX locks, or local to one machine), so liveness there is not
guaranteed; REASONED, not tried.

There is no separate reaper process. `vmavs run` and `vmavs ssh` each
remove every dead run directory that is not `--keep` before doing
anything else, and log what they removed. A directory counts as a dead
run only when its state file could be locked (no one holds it), parses,
and says it was not `--keep`. Anything else under `run/` is left alone:
a directory with no state file (`vmavs` did not make it), a state file
that does not parse, or one whose lock could not even be probed (that
error says nothing about whether the run is alive). `VMAVS_HOME=/` is
refused outright, since its `run/` would be the system's `/run`.

## 6. How the pipeline runs

`image` runs these stages in order, and `--stage a,b` selects some of
them:

`esd opencore ovmf efi openssh payload media target install verify manifest`

Each stage records a hash of its inputs, is skipped when they are
unchanged, and reports why it ran or was skipped (`--freshness`). The
behaviour matches today's `stage_record`/`stage_is_fresh`. The per-stage
subcommands (`fetch`, `firmware`, `media`, `install`) are named groups of
these stages. The manifest keeps today's fields, in `MANIFEST_FIELDS`
order, so existing manifests stay comparable.

**External processes** run through `proc.Runner` with a `context`
deadline. A VM stage supervises QEMU and the SSH wait concurrently, and
cleanup is `defer`, not traps.

## 7. Testing

- **Unit tests per package** (`go test ./...`). Everything external goes
  through `proc.Runner`, temp dirs and `httptest`, so no test needs QEMU,
  KVM, packer or Apple's bytes.
- **Golden files for generated artifacts:**
  - QEMU command lines per `Spec` role;
  - Packer HCL;
  - the flat `.pkg` layout;
  - GPT/FAT images;
  - manifests.

  These are byte-for-byte where the output is deterministic, structural
  where it is not.
- **Parity tests while the shell tree exists.** Where both implementations
  produce the same artifact (QEMU args for a given configuration, the flat
  `.pkg`, the EFI image, manifest fields), a test compares them, so "same
  behaviour" is measured rather than assumed. Where they deliberately
  differ, the test names the difference.
- **Carrying the bats knowledge over.** Before a shell file is deleted, its
  bats tests are read for behaviour worth keeping, and each such behaviour
  becomes a Go test. Many encode hard-won findings: numeric N comparison,
  C-quoted paths, SIGPIPE, empty-index cannot-verify, nested `@include`.
  The mapping is recorded in the phase's plan.

## 8. CI

- **The `go` job:**
  - `go vet`, `staticcheck` and `go test -race ./...` on Linux;
  - cross-builds for `darwin/amd64`, `darwin/arm64` and `netbsd/amd64`.
- **`packer-validate`** validates the Go `vmavs emit packer` template for
  every NIC it can install with and, until phase 6, the shell emitter's
  template for every profile: the shell emitter is still the shipped
  `emit packer`, and its templates say CI re-validates them on each push.
- **The shell jobs** run until phase 6, then go.
- **`bin/no-apple-bytes.sh`** stays as repository tooling guarding
  releases. Porting it is a separate decision.

## 9. Phases

The port is too large for one implementation plan. Each phase gets its own
plan, and ends with the suite green and the shell reference still working.

| Phase | Delivers |
|---|---|
| **1** | module skeleton, `cli`, `config`, `run`, `machine`, `vmavs run`, `vmavs ssh`, `emit packer`, `doctor`, `version`; the `go` CI job — delivered 2026-09-25 (NOTES.md, "P8 — the Go vmavs boots a built image and answers SSH") |
| **2** | `pins`, `fetch`, `payload` (xar writer) — delivered 2026-09-25 (NOTES.md, "P8 — vmavs fetch and the Go payload") |
| **3** | `firmware`, `diskimg` |
| **4** | `media`, privops |
| **5** | `pipeline`: `install`, `verify`, manifest, freshness, `vmavs image` |
| **6** | re-measurement on a KVM host; delete the shell tree and its tests; docs |

**What does not port.** The second-tier tools (`triangulate`, `golden`,
`compare`, `staleness`) stay in shell, working against the shell reference,
until phase 6. After phase 6 the user decides, for each one, whether it
earns a place: in `vmavs`, in a separate `vmavs-lab` binary built from the
same `internal/` packages, or nowhere. The `vm/profiles/*.args` development
profiles go with them.

## 10. Re-measurement: the gate on phase 6

The shell tree is not deleted until all of the following have run on a
KVM host, with the result appended to NOTES.md:

- `vmavs image` completes;
- `vmavs run` boots the result;
- `vmavs ssh -- sw_vers` answers.

Every claim the README or spec labels MEASURED is either re-measured
against the Go binary or relabelled.

## 11. Docs in this effort

- README, `vmavs help`.
- The spec's phase table, where P8's exit is met by phase 1's `run`.
- INGREDIENTS.md: the version-scheme deviation scopes to `cmd/vmavs` and
  `internal/`; declared-state paths move with `assets/pins/`.
- ADR 0013.

Rewriting NOTES.md, older ADRs, specs and plans to the new names is a
separate history pass, after this lands and the user likes it.

## 12. Out of scope

- P5 (interactive performance), P6 (the Actions runner), P9 (the build
  VM). This port overlaps P9's dependency goal but does not adopt P9's
  design.
- Release packaging: Phase C of the shipping plan, still unscheduled.
- Guest-side changes: `assets/guest/` moves as-is.
- Porting `bin/no-apple-bytes.sh` and the other repository tooling.
