# vmavs in Go, Phase 3: firmware and disk images

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- `vmavs firmware [opencore|ovmf|efi ...]` builds, from pinned source,
  everything the guest boots before the kernel: OpenCore's five `.efi`
  files, OVMF's three `.fd` files, and the 192 MiB OpenCore EFI image.
- The image is written by Go's own GPT and FAT32 writers
  (`internal/diskimg`), with no `sgdisk` or mtools.
- `vmavs fetch firmware` fetches the firmware's pinned sources through
  phase 2's verified cache. It adopts the shell tree's existing
  downloads.
- Phase 1's `vmavs run` boots an existing image on the firmware Go
  built. Task 13 measures that.

**Architecture:**
- **`internal/diskimg`** knows two file formats and nothing about
  OpenCore:
  - a GUID partition table writer and reader;
  - a FAT32 writer that builds the whole filesystem in memory and
    writes it in one pass;
  - a FAT32 reader, used by tests and the parity checks.

  Its output is deterministic: GUIDs are derived from a seed, the
  serial number is fixed, and every timestamp is 1980-01-01.
- **`internal/firmware`** is the build.
  - `pins.go` holds the pinned commits and names that
    `boot/build-opencore.sh`, `build-ovmf.sh`, `fetch-kexts.sh` and
    `build-efi-image.sh` hold today.
  - `compiler.go`, `ccache.go` and `smbios.go` port `lib/compiler.sh`,
    `lib/ccache.sh` and `lib/smbios.sh`.
  - `unpack.go` replaces `tar` and `unzip`.
  - `opencore.go` and `ovmf.go` orchestrate upstream's own build tools
    (`build_oc.tool`, EDK II's `build`) through `proc.Runner`.
  - `efi.go` assembles the EFI image with `diskimg`.
- **`internal/fetch`** gains `Getter.Pinned`, a verified fetch by
  registry name. `cli` uses it to fetch the firmware's inputs before
  `firmware` builds them offline.
- **`internal/cli`**:
  - gains the `vmavs firmware` subcommand;
  - gains a `firmware` target for `vmavs fetch`;
  - gains a `firmware` row in `vmavs doctor`.

**Tech Stack:**
- Go 1.26 standard library: `archive/tar`, `archive/zip`,
  `compress/gzip`, `hash/crc32`, `crypto/sha256`, `unicode/utf16`,
  `encoding/binary`.
- No new modules.
- External tools, all run through `proc.Runner`: `bash`, `make`, `gcc`,
  `git`, `python3`, `nasm`, `iasl` and `zip`. Upstream's build scripts
  need them.

**Spec:** `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`:
- §2: the commands and conventions;
- §3: layout, and the external tools that remain;
- §5: state under `VMAVS_HOME`;
- §7: golden files, parity tests, and carrying the bats knowledge over;
- §9: phase 3.

Also `docs/decisions/0004` (firmware reproducibility per toolchain),
`docs/decisions/0010` (SMBIOS) and `docs/decisions/0013` (Go).

## Global Constraints

- `go.mod` stays `go 1.26.0`. Use plain `go` commands; never set
  `GOFLAGS`. Add no module dependency.
- **The shell tree must keep working unchanged.**
  - Don't edit shell files, `lib/`, `boot/` (scripts, `config/`,
    `patches/`), `NOTES.md` history, `assets/pins/sources.tsv`,
    `components/`, `image/` or `media/`.
  - `./bin/run-tests.sh` exits 0 (check the code directly:
    `./bin/run-tests.sh >FILE 2>&1; echo $?`).
  - `bin/ingredient-fingerprint.sh` prints
    `a864536bf4402c760eb1b284a7b0f64f5f691485b3971a0f1cd7797554aa1d82`
    before and after.
- **Commit no third-party bytes.** Never commit Apple's, OpenCore's,
  EDK II's or acidanthera's bytes.
  - Test fixtures are synthetic: fake `.efi` files, fake kext bundles,
    and tarballs and zips that tests generate.
  - No test uses the network: use `httptest`.
  - No test runs a real EDK II build: use `proc.Fake`.
  - Only Task 13 runs the real build. Its inputs come from adoption,
    and all HTTP goes to a dead proxy.
- **Packages have fixed jobs.**
  - Flags and argv live only in `internal/cli`.
  - `internal/config` places every top-level directory under
    `VMAVS_HOME`, plus the files it already names. The package that
    owns a directory names what goes inside it: `firmware` owns
    `build/`'s other contents.
  - External programs run through `proc.Runner`.
  - `internal/diskimg` knows nothing about OpenCore.
- **Conventions are spec §2's:** exit codes 0/1/2, signals, `vmavs <cmd>:`
  logging on stderr, and stdout carrying only output.
- **Every claim is MEASURED, INHERITED or REASONED, and says which.**
  - A measurement records `date -u +%FT%TZ` when it is taken.
  - A task that changes the source of a MEASURED claim greps for every
    claim that depends on it and updates them in the same task.
  - A task that declares a phase exit met quotes the exit criterion and
    checks each clause.
- **Deletion: only delete what you can prove you created.**
  - `firmware` removes `build/OpenCorePkg-<ver>/UDK` only when its
    `.mqg-prepared` marker is missing or names a different commit. That
    is exactly when `build-opencore.sh` removes it.
  - It also removes temp files and directories it made itself.
  - Nothing else is removed.
- **Tests that exec external tools skip cleanly when a tool is absent**
  (`exec.LookPath`): `bash`, `sgdisk`, `mformat`, `mcopy`, `mdir`,
  `minfo`, `fsck.fat`, `truncate`, `sha256sum`, `git`, `python3`.
  - A parity test that runs a shell script using GNU-only options
    (`find -printf`, `stat -c`, `du -sb`) also skips unless
    `runtime.GOOS == "linux"`.
  - The `go-macos` CI job runs everything else.
- `gofmt -l` prints nothing, and `go vet ./...`, `go test -race ./...`
  and `go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` are
  clean.
- The build succeeds for linux/amd64, darwin/amd64, darwin/arm64 and
  netbsd/amd64.
- Never write to `~/.local/share/mavericks-qemu-guest`. Adoption only
  reads it and hard-links from it, as in phase 2. Task 13 says exactly
  what it touches.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QX6srqxQqri25igdYHqmNo
  ```

## Rulings this plan makes (the spec is amended in Task 12)

1. **`git`, `zip` and `bash` join spec §3's list of external tools.**
   Upstream needs them:
   - `build_oc.tool`/`efibuild.sh` insist on `git` and `zip`
     (`build-opencore.sh`'s own comment);
   - EDK II's `edksetup.sh` is a bash script.

   Patches are applied with `git apply`, as the shell tree does. The
   `tar`, `unzip`, `curl`, `sgdisk` and mtools uses are gone from the
   Go path.
2. **Environment knobs become flags.** Spec §2 carries over no `MQG_*`
   variable:
   - `MQG_SMBIOS` becomes `vmavs firmware --smbios MODEL`;
   - `MQG_CCACHE=1` becomes `--ccache`;
   - `MQG_COMPILER` becomes `--compiler 'NAME VERSION'`.

   `GCC_BIN` is EDK II's own variable, not ours. It is still honoured,
   read through `Env.Getenv`.
3. **`vmavs fetch` gains a `firmware` target.** A fetch with no target
   includes it: spec §2 says fetch with no argument gets "all of" the
   pinned inputs. `vmavs firmware` fetches whatever of its inputs is
   missing, so it also works on its own.
4. **The Go-built EFI image goes to `build/opencore.img`.** That is
   `config.Paths.OpenCoreImage()`'s preferred location (spec §5).
   - Its sidecar `build/opencore.img.sha256` holds the bare hex and a
     newline, as the shell's does.
   - The shell tree's `work/opencore-p3.img` is never written.
5. **The FAT32 geometry follows mformat's choices:** 32 reserved
   sectors, 2 FATs, media `0xF8`, FSInfo at sector 1, backup boot
   sector at 6.
   - Sectors per cluster is the largest of 8, 4, 2, 1 that leaves at
     least 65,525 clusters.
   - The FAT size is the smallest that holds every cluster.
   - MEASURED against mtools 4.0.43 for 40–2048 MiB (below). The parity
     test holds the two equal.

   Deliberate differences from mformat, each named in the parity test:
   - the OEM name (`MSWIN4.1`, not `MTOO4043`);
   - hidden sectors (the partition's start LBA, as the FAT
     specification says, not 0);
   - the serial number (fixed, not random);
   - timestamps (1980-01-01, not now);
   - no boot-code stub;
   - short-name tails.
6. **GPT GUIDs are derived, not random.** Each is a SHA-256 of
   `"vmavs diskimg " + seed`, shaped as a version-4 GUID, so the same
   inputs give the same image. The EFI image becomes byte-for-byte
   reproducible, where the shell's never was: sgdisk's GUIDs and
   mtools' timestamps are random or current.
7. **A Go-built firmware tree is interchangeable with a shell-built
   one.** Go uses the same `build/` layout:
   - `OpenCorePkg-1.0.7/UDK`, with its `.mqg-prepared` marker;
   - `artifacts/`, `firmware/`, `kexts/` and `config/`.

   So a `VMAVS_HOME` that is the shell tree's home builds
   incrementally, whichever tree built it first. Task 13 therefore
   never points `VMAVS_HOME` at the shell tree's home.
8. **Build output goes to log files, not the terminal.**
   - `build_oc.tool`'s output goes to `build/opencore-build.log`.
   - EDK II's `build` output for OVMF goes to `UDK/ovmf-build.log`, as
     in the shell.
   - On failure the error names the log and its last 20 lines are
     printed to stderr.
   - Only a command's output belongs on stdout (spec §2); the shell
     printed `build_oc.tool`'s output there.

## Facts this plan relies on

MEASURED on 2026-09-25, by reading the files named or running the
commands shown, unless marked otherwise.

- **`boot/build-opencore.sh`.**
  - Version and commits:
    - `OC_VERSION=1.0.7`;
    - `OCBUILD_COMMIT=e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a`;
    - `AUDK_COMMIT=0672a009e9ca85753d240324d761341adf0291b3`.
  - Build settings: `ARCHS=X64`, `TOOLCHAINS=GCC`, `TARGETS=RELEASE`,
    `OC_STD=gnu17`, `OC_NO_WERROR=-Wno-error`.
  - `OC_BUILD_OPTIONS` is `-std=gnu17<TAB>-Wno-error`.
    `efibuild.sh` splits `BUILD_ARGUMENTS` on spaces and commas, so the
    tab keeps the pair together as one argument. `--build-options`
    prints it with the tab turned into a space.
  - `--show-pins` prints `ocbuild-efibuild<TAB><commit>`, then
    `audk-src<TAB><commit>`, then each submodule source once, in list
    order.
  - The submodules, each `source:commit:path under UDK`. The same
    `audk-brotli` tarball goes to two paths:
    ```
    audk-openssl:aea7aaf2abb04789f5868cbabec406ea43aa84bf:CryptoPkg/Library/OpensslLib/openssl
    audk-brotli:e230f474b87134e8c6c85b630084c612057f253e:BaseTools/Source/C/BrotliCompress/brotli
    audk-brotli:e230f474b87134e8c6c85b630084c612057f253e:MdeModulePkg/Library/BrotliCustomDecompressLib/brotli
    audk-mbedtls:8c89224991adff88d53cd380f42a2baa36f91454:CryptoPkg/Library/MbedTlsLib/mbedtls
    audk-oniguruma:4ef89209a239c1aea328cf13c05a2807e5c146d1:MdeModulePkg/Universal/RegularExpressionDxe/oniguruma
    audk-libfdt:cfff805481bdea27f900c32698171286542b8d3c:MdePkg/Library/BaseFdtLib/libfdt
    audk-mipisyst:370b5944c046bab043dd8b133727b2135af7747a:MdePkg/Library/MipiSysTLib/mipisyst
    audk-jansson:e9ebfa7e77a6bee77df44e096b100e7131044059:RedfishPkg/Library/JsonLib/jansson
    audk-libspdm:98ef964e1e9a0c39c7efb67143d3a13a819432e0:SecurityPkg/DeviceSecurity/SpdmLib/libspdm
    audk-cmocka:1cc9cde3448cdd2e000886a26acf1caac2db7cf1:UnitTestFrameworkPkg/Library/CmockaLib/cmocka
    audk-googletest:86add13493e5c881d7e4ba77fb91c1f57752b3a4:UnitTestFrameworkPkg/Library/GoogleTestLib/googletest
    audk-subhook:83d4e1ebef3588fae48b69a7352cc21801cb70bc:UnitTestFrameworkPkg/Library/SubhookLib/subhook
    ```
  - The artifacts, built name to shipped name, in `--list-artifacts`
    order:
    - `OpenCore.efi` → `OpenCore.efi`
    - `Bootstrap.efi` → `BOOTx64.efi`
    - `OpenRuntime.efi` → `OpenRuntime.efi`
    - `OpenPartitionDxe.efi` → `OpenPartitionDxe.efi`
    - `OpenHfsPlus.efi` → `OpenHfsPlus.efi`

    `artifacts/SHA256SUMS` is `sha256sum` output in that shipped order:
    `<hex>  <name>` per line.
  - **Checks before building:** each input's registry URL contains its
    commit; its checksum is pinned; its file verifies.
  - **Patch 0001.** If `build_oc.tool` still contains
    `raw.githubusercontent.com`, it applies
    `git -C SRC apply -p1 boot/patches/0001-build_oc-source-pinned-efibuild.patch`,
    then dies if the string is still there.
  - **Assembling the UDK tree,** done when
    `UDK/.mqg-prepared` is absent or holds anything other than the
    audk commit:
    1. `rm -rf UDK`.
    2. Untar audk with `--strip-components=1`.
    3. `rm -rf UDK/OpenCorePkg`.
    4. Untar each submodule, with `--strip-components=1`, into a fresh
       `UDK/<path>`.
    5. For each `SRC/Patches/*` in glob order, apply
       `git -C UDK apply --ignore-whitespace <patch>`.
    6. Touch `patches.ready`, `submodules.ready` and `UDK.ready`.
    7. Write `<commit>\n` to `.mqg-prepared`.
  - **The build:** in `SRC`, run `./build_oc.tool` with this
    environment:
    ```
    ARCHS=X64 TOOLCHAINS=GCC TARGETS=RELEASE OFFLINE_MODE=1 EFIBUILD_SH=<efibuild.sh> BUILD_ARGUMENTS="-D OCPKG_BUILD_OPTIONS=-std=gnu17<TAB>-Wno-error"
    ```
    The outputs land in
    `UDK/Build/OpenCorePkg/RELEASE_GCC/X64`.
  - **Afterwards:**
    - the first `GNUmakefile` under that directory, in sorted order,
      must contain both `-std=gnu17` and `-Wno-error`;
    - `SRC/Utilities/ocvalidate/ocvalidate` is logged if it is
      executable, and warned about if not.
  - `--compiler` prints `<gcc --version line 1> (<gcc -dumpmachine>) -std=gnu17`,
    or `gcc not found`, where the compiler is `${GCC_BIN}gcc`.
- **`boot/build-ovmf.sh`.**
  - It builds `OvmfPkg/OvmfPkgX64.dsc` for X64, GCC, RELEASE.
    `--show-build` prints those four, tab-separated.
  - It needs these first:
    - `UDK/.mqg-prepared` equal to the audk commit;
    - `UDK/BaseTools/Source/C/bin/GenFv` executable.
  - **Two guarded patches,** each applied with
    `git -C UDK apply -p1 <patch>` unless the dsc already has its
    string, and checked afterwards:
    - `0002-ovmf-pin-the-c-dialect.patch` is guarded by `std=gnu17` in
      the dsc;
    - `0003-firmware-drop-werror.patch` is guarded by `Wno-error`.
  - **The build:** in a subshell in UDK:
    `set +u; . ./edksetup.sh >/dev/null; build -a X64 -b RELEASE -t GCC -p OvmfPkg/OvmfPkgX64.dsc > ovmf-build.log 2>&1`.
  - **Outputs:** it copies `OVMF_CODE.fd`, `OVMF_VARS.fd` and
    `OVMF.fd` from `UDK/Build/OvmfX64/RELEASE_GCC/FV` to
    `build/firmware/`, and writes `SHA256SUMS` in that order.
- **`boot/fetch-kexts.sh`.**
  - The kexts are `lilu-release:Lilu` and
    `virtualsmc-release:VirtualSMC`.
  - The bundle is the first `find -name <K>.kext -type d -prune | sort`
    match in the unzipped release. It must hold
    `Contents/Info.plist` and `Contents/MacOS/<K>`.
  - The release zips on this host hold `Lilu.kext/…` at the top level
    and `Kexts/VirtualSMC.kext/…`, plus `.kext.dSYM` directories, whose
    names do not match `-name <K>.kext`.
- **`boot/build-efi-image.sh` and `lib/efi.sh`.**
  - The image is 192 MiB (`IMAGE_MIB=192`).
  - `sgdisk --clear --new=1:2048:0 --typecode=1:EF00 --change-name=1:EFI`
    gives partition 1 from sector 2048 to 393182, the last usable LBA
    of 393216 sectors.
  - `mformat -F` puts FAT32, labelled `EFI`, on exactly that partition
    (`-T` is its sector count).
  - It makes these directories, in this order:
    `EFI`, `EFI/BOOT`, `EFI/OC`, `EFI/OC/Drivers`, `EFI/OC/Kexts`,
    `EFI/OC/ACPI`, `EFI/OC/Tools`, `EFI/OC/Resources`.
  - Then these files:
    - `BOOTx64.efi` → `EFI/BOOT/`;
    - `OpenCore.efi` → `EFI/OC/`;
    - `OpenRuntime`, `OpenPartitionDxe` and `OpenHfsPlus` `.efi` →
      `EFI/OC/Drivers/`;
    - the config → `EFI/OC/config.plist`;
    - each kext bundle's tree → `EFI/OC/Kexts/<K>.kext`, directories
      first, in sorted order.
  - `--list-contents` prints
    `BOOTx64.efi OpenCore.efi OpenRuntime.efi OpenPartitionDxe.efi OpenHfsPlus.efi Lilu.kext VirtualSMC.kext config.plist`,
    one per line.
  - `efi_fits MIB BYTES` is true if and only if
    `BYTES*2 <= (MIB-1)*1048576 - 4*1048576`.
  - Before writing, it verifies `artifacts/SHA256SUMS`
    (`sha256sum -c`).
  - The sidecar `<img>.sha256` is the bare hex and a newline.
- **mformat's FAT32 geometry on a GPT partition starting at LBA 2048.**
  MEASURED 2026-09-25 with `lib/efi.sh` against mtools 4.0.43 and GPT
  fdisk 1.0.10:

  | image MiB | fs sectors | sectors/cluster | FAT sectors | reserved |
  |---|---|---|---|---|
  | 40 | 79839 | 1 | 614 | 32 |
  | 48 | 96223 | 1 | 740 | 32 |
  | 64 | 128991 | 1 | 993 | 32 |
  | 100 | 202719 | 2 | 786 | 32 |
  | 192 | 391135 | 4 | 761 | 32 |
  | 300 | 612319 | 8 | 597 | 32 |
  | 512 | 1046495 | 8 | 1020 | 32 |
  | 1024 | 2095071 | 8 | 2042 | 32 |
  | 2048 | 4192223 | 8 | 4086 | 32 |

  Every one has 2 FATs, root cluster 2, FSInfo at 1, backup boot at 6,
  media `0xf8`, sectors/track 63 and hidden 0. The serial number is
  random. Heads are 16 up to about 504 MiB and more above that (32 at
  512 MiB; corrected 2026-09-25 by the Task 7-8 implementer's
  measurement). The 192 MiB EFI image has 16.
- **`lib/smbios.sh`.**
  - The default is `iMac14,2`.
  - Well-formed means non-empty, only `[A-Za-z0-9,._-]`, and at most 64
    characters.
  - `smbios_plist_set` is an awk edit. It replaces the text between
    `<string>` and `</string>` on the first `<string>` line after the
    one `<key>SystemProductName</key>`, and keeps that line's leading
    whitespace. It refuses when the key count is not exactly 1.
  - The `MQG_SMBIOS_MODELS` table has two rows, `iMac14,2 VERIFIED` and
    `MacPro5,1 PANICKED`. Their evidence text is long and must be
    carried verbatim; the parity test compares it.
- **`lib/compiler.sh`.** Floor 13, ceiling 16, family gcc, verified at
  `13.3.0, 14.2.0 and 16.2.1`. The verdict sentences and the parsing
  rules are in Task 5.
- **`lib/ccache.sh`.** Off by default. The verdicts are USED, MISSING
  and OFF, with the sentences in Task 5. The shims are
  `#!/bin/sh\nexec <ccache> <real gcc> "$@"\n`, mode 0755, in
  `build/ccache-bin`, with `CCACHE_DIR=build/ccache`.
- **The upstream tarballs.**
  - GitHub archives start with a `pax_global_header` entry.
  - The audk tarball holds 9,821 files, 2,059 directories and one
    symlink,
    `audk-<commit>/EmulatorPkg/Unix/Host/X11IncludeHack -> /opt/X11/include`,
    which is absolute. It has no hard links.
- **The shell tree's firmware downloads on this host** are in
  `$HOME/.local/share/mavericks-qemu-guest/build/<URL basename>`: for
  example `1.0.7.tar.gz`, `efibuild.sh`, `<commit>.tar.gz`,
  `Lilu-1.7.2-RELEASE.zip` and `VirtualSMC-1.3.7-RELEASE.zip`.
- **Host tools on the primary host:** gcc 13.3.0 (Ubuntu), nasm, iasl,
  python3, git, zip, make, sgdisk, mtools and fsck.fat are present;
  ccache is absent.

## File structure

| Path | Responsibility |
|---|---|
| `embed.go`, `embed_test.go` | also embed `boot/patches/*.patch` |
| `internal/proc/proc.go` | `Cmd.Env` |
| `internal/diskimg/guid.go`, `gpt.go`, `gpt_test.go` | GUIDs, the GPT writer and reader |
| `internal/diskimg/fat.go`, `fatname.go`, `fatread.go`, `fat_test.go`, `parity_test.go` | FAT32 geometry, writer, 8.3/LFN names, reader; parity with sgdisk and mtools |
| `internal/firmware/pins.go`, `pins_test.go` | the pinned build inputs and names; parity with the scripts' `--show-*`/`--list-*` |
| `internal/firmware/compiler.go`, `ccache.go`, `toolchain_test.go` | the compiler range and ccache, with parity with the libraries |
| `internal/firmware/smbios.go`, `smbios_test.go` | SMBIOS well-formedness, the table, the plist edit |
| `internal/firmware/unpack.go`, `unpack_test.go` | safe tar.gz and kext-zip extraction |
| `internal/firmware/builder.go` | `Builder`, `Inputs`, shared helpers (logs, atomic copies, SHA256SUMS) |
| `internal/firmware/opencore.go`, `opencore_test.go` | the OpenCore build |
| `internal/firmware/ovmf.go`, `ovmf_test.go` | the OVMF build |
| `internal/firmware/efi.go`, `kexts.go`, `efi_test.go` | the kexts and the EFI image; parity with `build-efi-image.sh` |
| `internal/fetch/pinned.go`, `pinned_test.go` | `Getter.Pinned` |
| `internal/config/config.go` | `Paths.OpenCoreImageOut` |
| `internal/cli/firmware.go`, `firmware_test.go`, `fetch.go`, `cli.go` | `vmavs firmware`; `vmavs fetch firmware`; `Env.Environ` |
| `internal/doctor/doctor.go` | the `firmware` row; `Host.Header` |
| `README.md`, spec | commands, tools, phase status |

## Carrying the bats knowledge over (spec §7)

Each behaviour a bats test pins, and the Go test that keeps it. "Stays"
means the behaviour belongs to a shell file that phase 3 does not
replace; it moves when that file does.

| bats test | Go test (task) |
|---|---|
| efi: GPT image with one ESP; refuses to clobber; ESP offset | `TestGPTRoundTrip`, `TestGPTMatchesSgdisk` (7) and `TestEFIImageLayout` (11) for the ESP and its offset. Go does not refuse an existing image: it replaces it atomically (written beside it, renamed over it once whole), so it never clobbers one half-way -- `TestEFIImageLeavesThePreviousImageWhenItFails` (final fix wave), `TestEFIImageLeavesNoTempWhenTheSidecarCannotBeWritten` (11) |
| efi: files readable back out; nested dirs; bundle copied as tree | `TestFATRoundTrip`, `TestFATNestedDirectoriesAndLongDirectories`, `TestEFIImageLayout` (8, 11) |
| efi: missing source fails loudly | `TestEFIImageNamesTheMissingPiece` (11) |
| efi: filesystem stays inside its partition | `TestFATStaysInsideItsPartition` (8) |
| efi: efi_fits demands headroom | `TestFitsDemandsHeadroomLikeEfiFits` (11) |
| boot_scripts: fetch-opencorepkg refuses unpinned; reports tag | `TestCheckPinsRefusesUnpinned`, `TestPinsMatchTheScripts` (2) |
| boot_scripts: build-opencore fails when tree absent / names fetch | `TestOpenCoreNamesTheMissingInput` (9) |
| boot_scripts: lists artifacts; pins commits; sources.tsv names commit; no mutable branch | `TestPinsMatchTheScripts`, `TestCheckPinsRefusesAURLWithoutItsCommit`, `TestEveryPinIsAnImmutableURL` (2) |
| boot_scripts: fetch-edk2 takes its list from the build's pins | `TestSourceNamesAreThePins` (2) |
| boot_scripts: build_oc.tool patch applied and checked | `TestOpenCorePatchesBuildOCToolAndChecksIt` (9) |
| boot_scripts: C dialect; -Wno-error; one tab-separated argument; both flags asserted | `TestOpenCoreBuildEnvironment`, `TestOpenCoreRefusesFlagsThatDidNotArrive` (9) |
| boot_scripts: OVMF patches added and checked; X64 RELEASE GCC; tree/commit from OpenCore; absent tree; wrong commit; BaseTools | `TestOVMF*` (10) |
| boot_scripts: fetch-kexts unpacks with binary; names missing binary; no bundle; layout for the image | `TestExtractKext*`, `TestKexts*` (4, 11) |
| boot_scripts: build-efi-image lists contents; names missing artifacts / kext piece; refuses SHA256SUMS mismatch; layout | `TestEFIImage*` (11) |
| boot_scripts: make-nvram.sh (7 tests) | stays: per-run NVRAM is phase 1's `vm` package; the build-time copy is phase 5's |
| boot_scripts: prereqs.sh (package names per manager, busybox, headers) | the firmware part is `TestDoctorFirmwareRow` (12); the package-name table and media tools stay until phase 4/6 |
| ccache (12 tests) | `TestCcacheIsOffByDefault`, `TestCcacheVerdictMatchesTheLibrary`, `TestTheShimWrapsTheRealCompilerByAbsolutePath` (5), `TestOpenCoreWithCcache`, `TestOpenCoreCcachePathHasNoEmptyElement` (9); "not a stage input" is phase 5's |
| compiler (33 tests) | `TestRangeVerdictMatchesTheLibrary`, `TestParseCompilerMatchesTheLibrary`, `TestTheDeclaredRangeIsGcc13Through16`, `TestStatusNamesWhatItCouldNotRead`, `TestTheOverrideReplacesDetectionAndIsRecorded`, `TestCompilerLine`, `TestCheckRefusesBelowTheFloorAndWarnsAbove` (5), parity-checked against `lib/compiler.sh` |
| smbios (17 tests) | `TestTheTableIsTheLibrarysWordForWord`, `TestTheDefaultIsWhatConfigPlistShips`, `TestVerdictsAndManifestLinesMatchTheLibrary`, `TestWellformedness`, `TestSetProductNameMatchesTheLibraryByteForByte`, `TestSettingTheModelAlreadyThereChangesNoByte`, `TestProductNameAndSetProductNameMirrorAWKWhenACommentPrecedesTheStringTag`, `TestSetProductNameRefusesWhenKeyAndValueShareALine`, `TestSetProductNameRefusesWhatItCannotDoSafely`, `TestCheckNeverFails` (6), parity-checked against `lib/smbios.sh` |
| vendor: source_field / fetch_source URL rules | phase 2's `pins` and `fetch.Filename`; `TestPinnedAdoptsFromTheShellTreesBuildDirectory` (3) |
| config_plist (6 tests) | stays: `boot/config/config.plist` is unchanged, and the bats tests keep checking it |

---

### Task 1: Plumbing: `Cmd.Env`, the embedded patches, `Env.Environ`, `OpenCoreImageOut`

**Files:**
- Modify: `internal/proc/proc.go`, `internal/proc/proc_test.go`
- Modify: `embed.go`, `embed_test.go`
- Modify: `internal/cli/cli.go`, `cmd/vmavs/main.go`
- Modify: `internal/config/config.go`, `internal/config/config_test.go`

**Interfaces:**
- Produces:
  - `proc.Cmd.Env []string`. nil inherits vmavs's environment;
    otherwise it is exactly the child's environment, as in `exec.Cmd.Env`.
  - `vmguest.Files` also holds `boot/patches/*.patch`.
  - `cli.Env.Environ func() []string`. nil means `os.Environ`.
  - `config.Paths.OpenCoreImageOut() string`, which is always
    `build/opencore.img`. It is where `firmware` writes.
    `OpenCoreImage()` stays the read path, with its fallback.

- [ ] **Step 1: Write the failing tests**

Append to `internal/proc/proc_test.go`:

```go
func TestExecPassesTheEnvironmentItIsGiven(t *testing.T) {
	var out strings.Builder
	err := Exec{}.Run(context.Background(), Cmd{
		Name: "sh", Args: []string{"-c", `printf %s "$VMAVS_PROC_TEST"`},
		Env:  []string{"VMAVS_PROC_TEST=a\tb", "PATH=/usr/bin:/bin"},
		Stdout: &out,
	})
	if err != nil || out.String() != "a\tb" {
		t.Fatalf("out %q, err %v", out.String(), err)
	}
}
```

In `embed_test.go`, the list gains the three patch files:

```go
		"boot/patches/0001-build_oc-source-pinned-efibuild.patch",
		"boot/patches/0002-ovmf-pin-the-c-dialect.patch",
		"boot/patches/0003-firmware-drop-werror.patch",
```

Also add a test that every file matching `boot/patches/*.patch` on disk
is embedded, so a new patch cannot be forgotten:

```go
func TestEveryPatchOnDiskIsEmbedded(t *testing.T) {
	disk, err := filepath.Glob("boot/patches/*.patch")
	if err != nil || len(disk) == 0 {
		t.Fatalf("glob: %v %v", disk, err)
	}
	for _, p := range disk {
		if _, err := fs.ReadFile(Files, p); err != nil {
			t.Errorf("%s is on disk but not embedded", p)
		}
	}
}
```

Append to `internal/config/config_test.go`:

```go
func TestOpenCoreImageOutIgnoresTheShellTreesPath(t *testing.T) {
	home := t.TempDir()
	p := Paths{Home: home}
	if err := os.MkdirAll(p.Work(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p.Work(), "opencore-p3.img"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := p.OpenCoreImageOut(); got != filepath.Join(home, "build", "opencore.img") {
		t.Fatalf("got %s", got)
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/proc/ ./internal/config/ . 2>&1 | tail -20`
Expected: compile errors (`unknown field Env`, `OpenCoreImageOut undefined`),
and the patches not embedded.

- [ ] **Step 3: Implement**

`internal/proc/proc.go`:
- Add to `Cmd`, after `ExtraFiles`:

  ```go
	// Env is the child's whole environment, as exec.Cmd.Env: nil means
	// vmavs's own. The firmware builds use it to hand upstream's
	// build scripts their settings (ARCHS, BUILD_ARGUMENTS, ...).
	Env []string
  ```

- In `Exec.Run`, add `cmd.Env = c.Env`.

`embed.go`: append ` boot/patches/*.patch` to the `//go:embed` line.
Extend the doc comment with one sentence: the firmware build applies
the patches from the binary, not from the checkout.

`internal/cli/cli.go`:
- Add to `Env`, after `Getenv`:

  ```go
	// Environ is the environment children inherit (the firmware builds
	// add to it). nil means os.Environ.
	Environ func() []string
  ```

- Add a helper next to `runner`:

  ```go
// environ is e.Environ(), or os.Environ().
func environ(e *Env) []string {
	if e.Environ != nil {
		return e.Environ()
	}
	return os.Environ()
}
  ```

`cmd/vmavs/main.go`: set `Environ: os.Environ` beside `Getenv`.

`internal/config/config.go`, after `OpenCoreImage`:

```go
// OpenCoreImageOut is where vmavs writes the OpenCore EFI image it
// builds: always build/opencore.img, never the shell tree's
// work/opencore-p3.img, which OpenCoreImage still falls back to for
// reading.
func (p Paths) OpenCoreImageOut() string { return filepath.Join(p.Build(), "opencore.img") }
```

Make `OpenCoreImage` use `p.OpenCoreImageOut()` for its `cur`, so the
path is written once.

- [ ] **Step 4: Run the tests**

Run: `go test -race ./internal/proc/ ./internal/config/ ./internal/cli/ . && go vet ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/proc embed.go embed_test.go internal/cli/cli.go cmd/vmavs/main.go internal/config
git commit   # subject: "proc, config, embed: a child's environment, the patches in the binary, where the EFI image goes"
```

---

### Task 2: `internal/firmware`: the pinned build inputs

**Files:**
- Create: `internal/firmware/pins.go`, `internal/firmware/pins_test.go`

**Interfaces:**
- Consumes: `pins.Registry` (`Lookup` refuses TOFU and empty checksums).
- Produces, all in package `firmware`:
  - Constants: `OCVersion`, `OCBuildCommit`, `AudkCommit`, `Arch`,
    `Toolchain`, `Target`, `CStd`, `NoWerror`, `OVMFDsc`, `EFIImageMiB`.
  - Types and tables:
    - `type Submodule struct{ Source, Commit, Path string }` and
      `var Submodules []Submodule`;
    - `type Artifact struct{ Built, Ship string }` and
      `var Artifacts []Artifact`;
    - `var OVMFFiles []string`;
    - `type Kext struct{ Source, Name string }` and `var Kexts []Kext`;
    - `var EFIDrivers []string`;
    - `type Pin struct{ Source, Commit string }`.
  - Functions:
    - `BuildOptions() string`: `-std=gnu17<TAB>-Wno-error`.
    - `OpenCorePins() []Pin`: `--show-pins` order, each source once.
    - `OpenCoreSources() []string`: the pins' sources, then
      `opencorepkg-src`.
    - `KextSources() []string`.
    - `SourceNames() []string`: `OpenCoreSources()` then
      `KextSources()`.
    - `CheckPins(reg *pins.Registry) error`.
    - `ShipNames() []string`: the shipped artifact names, in
      `--list-artifacts` order.

- [ ] **Step 1: Write the failing tests**

`internal/firmware/pins_test.go`:

```go
package firmware

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// repo is the repository root, for the parity tests that run the shell
// tree's scripts.
func repo(t *testing.T) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..")
}

// script runs one of the shell tree's scripts with args and returns its
// stdout, skipping when bash is absent.
func script(t *testing.T, path string, args ...string) string {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	cmd := exec.Command("bash", append([]string{filepath.Join(repo(t), path)}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s %v: %v", path, args, err)
	}
	return string(out)
}

func lines(s string) []string { return strings.Split(strings.TrimRight(s, "\n"), "\n") }

func TestPinsMatchTheScripts(t *testing.T) {
	var pinLines []string
	for _, p := range OpenCorePins() {
		pinLines = append(pinLines, p.Source+"\t"+p.Commit)
	}
	checks := []struct {
		name string
		got  []string
		want string
	}{
		{"--show-pins", pinLines, script(t, "boot/build-opencore.sh", "--show-pins")},
		{"--list-artifacts", ShipNames(), script(t, "boot/build-opencore.sh", "--list-artifacts")},
		{"--udk-commit", []string{AudkCommit}, script(t, "boot/build-opencore.sh", "--udk-commit")},
		{"--build-options", []string{strings.ReplaceAll(BuildOptions(), "\t", " ")}, script(t, "boot/build-opencore.sh", "--build-options")},
		{"ovmf --list-artifacts", OVMFFiles, script(t, "boot/build-ovmf.sh", "--list-artifacts")},
		{"ovmf --show-build", []string{OVMFDsc + "\t" + Arch + "\t" + Toolchain + "\t" + Target}, script(t, "boot/build-ovmf.sh", "--show-build")},
		{"fetch-kexts --list", kextNames(), script(t, "boot/fetch-kexts.sh", "--list")},
		{"fetch-opencorepkg --show-version", []string{"OpenCorePkg " + OCVersion}, script(t, "boot/fetch-opencorepkg.sh", "--show-version")},
		{"build-efi-image --list-contents", efiContents(), script(t, "boot/build-efi-image.sh", "--list-contents")},
		{"fetch-edk2 --list-sources", pinSources(), script(t, "boot/fetch-edk2.sh", "--list-sources")},
	}
	for _, c := range checks {
		if strings.Join(c.got, "\n") != strings.Join(lines(c.want), "\n") {
			t.Errorf("%s:\n go:    %q\n shell: %q", c.name, c.got, lines(c.want))
		}
	}
}

func kextNames() (n []string) {
	for _, k := range Kexts {
		n = append(n, k.Name)
	}
	return n
}

func pinSources() (n []string) {
	for _, p := range OpenCorePins() {
		n = append(n, p.Source)
	}
	return n
}

// efiContents is what build-efi-image.sh --list-contents prints: the
// artifacts in image order, the kext bundles, then the config.
func efiContents() []string {
	c := append([]string{"BOOTx64.efi", "OpenCore.efi"}, EFIDrivers...)
	for _, k := range Kexts {
		c = append(c, k.Name+".kext")
	}
	return append(c, "config.plist")
}

func TestEFIImageSizeMatchesTheScript(t *testing.T) {
	src, err := os.ReadFile(filepath.Join(repo(t), "boot/build-efi-image.sh"))
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("\nIMAGE_MIB=%d\n", EFIImageMiB)
	if !strings.Contains(string(src), want) {
		t.Fatalf("boot/build-efi-image.sh does not say %q", strings.TrimSpace(want))
	}
}

func TestSourceNamesAreThePins(t *testing.T) {
	want := append(pinSources(), "opencorepkg-src")
	if strings.Join(OpenCoreSources(), " ") != strings.Join(want, " ") {
		t.Fatalf("OpenCoreSources = %v", OpenCoreSources())
	}
	all := append(append([]string{}, OpenCoreSources()...), KextSources()...)
	if strings.Join(SourceNames(), " ") != strings.Join(all, " ") {
		t.Fatalf("SourceNames = %v", SourceNames())
	}
}

func TestEveryPinIsInTheEmbeddedRegistryWithItsCommit(t *testing.T) {
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	if err := CheckPins(reg); err != nil {
		t.Fatal(err)
	}
}

func TestCheckPinsRefusesAURLWithoutItsCommit(t *testing.T) {
	reg := registryWith(t, "audk-src", "https://example.test/archive/0000.tar.gz", strings.Repeat("a", 64))
	err := CheckPins(reg)
	if err == nil || !strings.Contains(err.Error(), "audk-src") || !strings.Contains(err.Error(), AudkCommit) {
		t.Fatalf("err = %v", err)
	}
}

func TestCheckPinsRefusesUnpinned(t *testing.T) {
	reg := registryWith(t, "audk-src", "https://example.test/archive/"+AudkCommit+".tar.gz", "TOFU")
	if err := CheckPins(reg); err == nil || !strings.Contains(err.Error(), "audk-src") {
		t.Fatalf("err = %v", err)
	}
}

func TestEveryPinIsAnImmutableURL(t *testing.T) {
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range SourceNames() {
		s, err := reg.Lookup(n)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{"refs/heads", "/master/", "/main/"} {
			if strings.Contains(s.URL, bad) {
				t.Errorf("%s fetches from a mutable branch: %s", n, s.URL)
			}
		}
	}
}

// registryWith is the embedded registry with one row replaced, so a test
// can break exactly one pin.
func registryWith(t *testing.T, name, url, sha string) *pins.Registry {
	t.Helper()
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	b.WriteString(name + "\t" + url + "\t" + sha + "\n") // first match wins
	for _, r := range reg.Rows() {
		b.WriteString(r.Name + "\t" + r.URL + "\t" + r.SHA256 + "\n")
	}
	out, err := pins.Parse(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return out
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ 2>&1 | head`
Expected: the package does not compile (`undefined: OpenCorePins`, …).

- [ ] **Step 3: Implement `internal/firmware/pins.go`**

```go
// Package firmware builds, from pinned source, what the guest boots before
// its kernel: OpenCore (build_oc.tool), OVMF (EDK II's build) and the
// OpenCore EFI image. It is the Go form of boot/build-opencore.sh,
// boot/build-ovmf.sh, boot/fetch-kexts.sh and boot/build-efi-image.sh,
// and while the shell tree exists its parity tests hold the two equal.
//
// firmware owns build/ under VMAVS_HOME, except the files config.Paths
// already names there (firmware/OVMF_*.fd and opencore.img). The layout
// is the shell tree's, so either implementation can build incrementally
// on a tree the other made.
package firmware

import (
	"fmt"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// The pinned build. These are what "reproducible" means for the firmware
// (docs/decisions/0004): the same sources, translated by the same
// compiler, in the same build directory, give the same bytes.
const (
	OCVersion     = "1.0.7"
	OCBuildCommit = "e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a"
	AudkCommit    = "0672a009e9ca85753d240324d761341adf0291b3"

	Arch      = "X64"     // a 64-bit guest; IA32 would double the build for nothing
	Toolchain = "GCC"     // CLANGPDB needs clang, which the hosts do not have
	Target    = "RELEASE" // DEBUG logs on every boot and is slower

	// CStd is the C dialect every firmware file is compiled in. EDK II
	// sets none, and GCC 15 defaults to gnu23, where OpenCorePkg 1.0.7's
	// libDER does not compile (build-opencore.sh has the whole story).
	CStd = "gnu17"
	// NoWerror stops upstream's -Werror turning a newer compiler's new
	// warnings into build failures in code we do not own. The warnings
	// are still printed.
	NoWerror = "-Wno-error"

	OVMFDsc = "OvmfPkg/OvmfPkgX64.dsc"

	// EFIImageMiB is the OpenCore EFI image's size; Fits checks the
	// payload against it before anything is written.
	EFIImageMiB = 192
)

// A Submodule is one of audk's git submodules, which a GitHub archive
// tarball leaves out: the registry source that holds it, the commit its
// URL must name, and where it goes under the UDK tree.
type Submodule struct{ Source, Commit, Path string }

// Submodules is every submodule audk's gitlinks name, not just the ones
// compiled: build.py validates every [Includes] path of every .dec it
// parses. audk-brotli appears twice, at one commit.
var Submodules = []Submodule{
	{"audk-openssl", "aea7aaf2abb04789f5868cbabec406ea43aa84bf", "CryptoPkg/Library/OpensslLib/openssl"},
	{"audk-brotli", "e230f474b87134e8c6c85b630084c612057f253e", "BaseTools/Source/C/BrotliCompress/brotli"},
	{"audk-brotli", "e230f474b87134e8c6c85b630084c612057f253e", "MdeModulePkg/Library/BrotliCustomDecompressLib/brotli"},
	{"audk-mbedtls", "8c89224991adff88d53cd380f42a2baa36f91454", "CryptoPkg/Library/MbedTlsLib/mbedtls"},
	{"audk-oniguruma", "4ef89209a239c1aea328cf13c05a2807e5c146d1", "MdeModulePkg/Universal/RegularExpressionDxe/oniguruma"},
	{"audk-libfdt", "cfff805481bdea27f900c32698171286542b8d3c", "MdePkg/Library/BaseFdtLib/libfdt"},
	{"audk-mipisyst", "370b5944c046bab043dd8b133727b2135af7747a", "MdePkg/Library/MipiSysTLib/mipisyst"},
	{"audk-jansson", "e9ebfa7e77a6bee77df44e096b100e7131044059", "RedfishPkg/Library/JsonLib/jansson"},
	{"audk-libspdm", "98ef964e1e9a0c39c7efb67143d3a13a819432e0", "SecurityPkg/DeviceSecurity/SpdmLib/libspdm"},
	{"audk-cmocka", "1cc9cde3448cdd2e000886a26acf1caac2db7cf1", "UnitTestFrameworkPkg/Library/CmockaLib/cmocka"},
	{"audk-googletest", "86add13493e5c881d7e4ba77fb91c1f57752b3a4", "UnitTestFrameworkPkg/Library/GoogleTestLib/googletest"},
	{"audk-subhook", "83d4e1ebef3588fae48b69a7352cc21801cb70bc", "UnitTestFrameworkPkg/Library/SubhookLib/subhook"},
}

// An Artifact is a file build_oc.tool produces and the name it ships
// under. Bootstrap.efi becomes the fallback boot path's BOOTx64.efi.
type Artifact struct{ Built, Ship string }

// Artifacts is what the OpenCore build ships, in the order its
// SHA256SUMS lists them.
var Artifacts = []Artifact{
	{"OpenCore.efi", "OpenCore.efi"},
	{"Bootstrap.efi", "BOOTx64.efi"},
	{"OpenRuntime.efi", "OpenRuntime.efi"},
	{"OpenPartitionDxe.efi", "OpenPartitionDxe.efi"},
	{"OpenHfsPlus.efi", "OpenHfsPlus.efi"},
}

// OVMFFiles is what the OVMF build ships: the pflash pair and the
// combined image, all three from one build.
var OVMFFiles = []string{"OVMF_CODE.fd", "OVMF_VARS.fd", "OVMF.fd"}

// A Kext is a release binary OpenCore injects: its registry source and
// its bundle name (also the name of the Mach-O inside it).
type Kext struct{ Source, Name string }

// Kexts is in load order: VirtualSMC depends on Lilu, and config.plist
// lists them the same way.
var Kexts = []Kext{{"lilu-release", "Lilu"}, {"virtualsmc-release", "VirtualSMC"}}

// EFIDrivers is what goes in EFI/OC/Drivers, in image order.
var EFIDrivers = []string{"OpenRuntime.efi", "OpenPartitionDxe.efi", "OpenHfsPlus.efi"}

// A Pin is one registry source the OpenCore build needs and the commit
// its URL must name.
type Pin struct{ Source, Commit string }

// BuildOptions is the value of OCPKG_BUILD_OPTIONS: the dialect and
// -Wno-error as ONE build macro. The separator is a tab because
// efibuild.sh splits BUILD_ARGUMENTS on spaces and commas; build.py turns
// the tab back into a space in the generated makefiles.
func BuildOptions() string { return "-std=" + CStd + "\t" + NoWerror }

// OpenCorePins is every pinned EDK II input, each source once, in the
// order boot/build-opencore.sh --show-pins prints them.
func OpenCorePins() []Pin {
	ps := []Pin{{"ocbuild-efibuild", OCBuildCommit}, {"audk-src", AudkCommit}}
	seen := map[string]bool{}
	for _, s := range Submodules {
		if !seen[s.Source] {
			seen[s.Source] = true
			ps = append(ps, Pin{s.Source, s.Commit})
		}
	}
	return ps
}

// OpenCoreSources is every registry source the OpenCore build reads.
func OpenCoreSources() []string {
	var n []string
	for _, p := range OpenCorePins() {
		n = append(n, p.Source)
	}
	return append(n, "opencorepkg-src")
}

// KextSources is every registry source the EFI image's kexts come from.
func KextSources() []string {
	var n []string
	for _, k := range Kexts {
		n = append(n, k.Source)
	}
	return n
}

// SourceNames is every registry source the firmware needs.
func SourceNames() []string { return append(OpenCoreSources(), KextSources()...) }

// ShipNames is Artifacts' shipped names, in SHA256SUMS order.
func ShipNames() []string {
	var n []string
	for _, a := range Artifacts {
		n = append(n, a.Ship)
	}
	return n
}

// CheckPins checks every source the firmware reads: the registry has it
// pinned to a real checksum (Lookup refuses TOFU), and, for a source
// pinned to a commit, its URL names that commit -- the registry holds the
// URLs and this file holds the commits, and the two must not drift.
func CheckPins(reg *pins.Registry) error {
	for _, n := range SourceNames() {
		if _, err := reg.Lookup(n); err != nil {
			return err
		}
	}
	for _, p := range OpenCorePins() {
		s, _ := reg.Lookup(p.Source)
		if !strings.Contains(s.URL, p.Commit) {
			return fmt.Errorf("%s in the registry does not name commit %s: %s", p.Source, p.Commit, s.URL)
		}
	}
	return nil
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -v 2>&1 | tail -20`
Expected: PASS. Every parity row runs here, because bash is present.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware
git commit   # subject: "firmware: the pinned build inputs, held equal to the shell scripts' own lists"
```

---

### Task 3: `Getter.Pinned` and `vmavs fetch firmware`

**Files:**
- Create: `internal/fetch/pinned.go`, `internal/fetch/pinned_test.go`
- Modify: `internal/config/config.go` (`Paths.ShellBuild`)
- Modify: `internal/cli/fetch.go`, `internal/cli/fetch_test.go`
- Modify: `README.md` (the Go section's `fetch` line)

**Interfaces:**
- Consumes:
  - `firmware.SourceNames()`, from Task 2;
  - `Getter.Get` and `Filename`, from phase 2;
  - `adoptCandidates(p, legacyBase, pathFn)` in `cli/fetch.go`.
- Produces:
  - `(*fetch.Getter).Pinned(ctx context.Context, reg *pins.Registry, name string, adoptDirs []string) (string, error)`.
  - `config.Paths.ShellBuild() string`, which is `build/`. The shell
    tree keeps its firmware downloads there. This is one of the
    shell-layout adoption paths phase 6 deletes.
  - `vmavs fetch firmware`. With no target, fetch gets esd, openssh,
    updates and firmware, in that order.

- [ ] **Step 1: Write the failing tests**

`internal/fetch/pinned_test.go`. It uses an `httptest` server and a
registry built from strings.

Before writing the helpers, read `get_test.go`'s existing ones
(`newGetter`, a server that counts requests). Reuse them rather than
adding new ones. The tests:

1. `TestPinnedDownloadsVerifiesAndCaches`.
   - The registry row is `x<TAB><srv>/dir/x.tar.gz<TAB><sha of body>`.
   - `Pinned` returns `Paths.CacheFile(sha, "x.tar.gz")`, holding the
     body.
   - A second call makes no request.
2. `TestPinnedAdoptsFromTheShellTreesBuildDirectory`.
   - The body is already at `<adoptDir>/x.tar.gz`, and the server fails
     every request.
   - `Pinned` succeeds, the server saw 0 requests, and the adopted file
     has the same inode (`os.SameFile`) when the temp dir supports
     links.
3. `TestPinnedRefusesAnUnpinnedSource`. With `TOFU` as the checksum,
   the error names the source and says "pinned". There is no request.
4. `TestPinnedRefusesAURLWithNoFilename`.
   - `https://example.test` fails with `Filename`'s message.
   - `https://example.test/dir/` fails too.
5. `TestPinnedKeepsAQueryStringInTheFilename`. The URL
   `<srv>/f.zip?v=2` caches as `f.zip?v=2`. That is `fetch_source`'s
   behaviour (vendor.bats).

   `validateFilename` refuses a `/`, but `?` is allowed. Check that it
   is. If it is not, record the difference in the test's name and
   comment, and do not change `validateFilename`.
6. `TestPinnedSkipsEmptyAdoptDirs`. An adoptDirs entry of `""` is
   ignored, not turned into `./x.tar.gz`.

In `internal/cli/fetch_test.go`, add:

1. `TestFetchFirmwareFetchesEverySource`.
   - Use a test registry: `firmware.SourceNames()`, each pointing at an
     httptest server path, with the checksums of distinct bodies.
   - `vmavs fetch firmware` prints one cache path per source, in
     `SourceNames()` order, and exits 0.
2. `TestFetchWithNoTargetIncludesFirmware`. The same setup, plus
   phase 2's esd/openssh/updates fixtures (reuse the existing helpers
   that set up those servers). Stdout ends with the firmware paths.
3. `TestFetchFirmwareAdoptsFromTheLegacyBuildDirectory`.
   - The bodies sit in `<HOME>/.local/share/mavericks-qemu-guest/build/`.
   - The server refuses everything.
   - Exit 0, with every path adopted.
4. `TestFetchRejectsUnknownTargetsStill`. `vmavs fetch firmwar`
   exits 2.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/fetch/ ./internal/cli/ 2>&1 | head -20`
Expected: `Pinned undefined`, and an unknown target `firmware`.

- [ ] **Step 3: Implement**

`internal/fetch/pinned.go`:

```go
package fetch

import (
	"context"
	"path/filepath"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// Pinned fetches the registry's source name into the cache and returns
// its path: the Go form of lib/vendor.sh's fetch_source, for inputs
// that are neither Apple's nor the guest's OpenSSH -- the firmware's
// tarballs, efibuild.sh and the kext releases. The file is named by its
// URL's last path element, as fetch_source names it, and a verified copy
// of that name in any of adoptDirs (the shell tree's build/ directory)
// is adopted instead of downloaded. The returned path is read-only, as
// every path Get returns is.
func (g *Getter) Pinned(ctx context.Context, reg *pins.Registry, name string, adoptDirs []string) (string, error) {
	src, err := reg.Lookup(name)
	if err != nil {
		return "", err
	}
	filename, err := Filename(src.URL)
	if err != nil {
		return "", err
	}
	var adopt []string
	for _, d := range adoptDirs {
		if d != "" {
			adopt = append(adopt, filepath.Join(d, filename))
		}
	}
	return g.Get(ctx, Item{Name: name, URL: src.URL, SHA256: src.SHA256, Filename: filename, Adopt: adopt})
}
```

`internal/config/config.go`, beside `ShellUpdates`:

```go
// ShellBuild is where the shell tree keeps its firmware downloads (and
// builds): build/. Adoption looks there for the firmware's sources.
func (p Paths) ShellBuild() string { return p.Build() }
```

`internal/cli/fetch.go`:
- `fetchOrder` becomes `esd, openssh, updates, firmware`.
- The help text names the `firmware` target:

  ```
  (esd), the guest's OpenSSH release (openssh), Apple's post-10.9.5
  updates (updates), and the firmware's pinned sources -- OpenCorePkg,
  ocbuild's efibuild.sh, EDK II (audk) and its submodules, and the
  Lilu and VirtualSMC kext releases (firmware). With no target, all
  four.
  ```

  The adoption paragraph adds `build/` to the list of places it adopts
  from.
- In the target loop, add:

  ```go
		case "firmware":
			for _, n := range firmware.SourceNames() {
				path, err := g.Pinned(ctx, reg, n, adoptCandidates(p, legacyBase, config.Paths.ShellBuild))
				if err != nil {
					return err
				}
				fmt.Fprintln(e.Stdout, path)
			}
  ```

  `adoptCandidates` already takes a `func(config.Paths) string`. Check
  its signature and use it as it is.
- `fetchTargets` accepts `firmware`.

`README.md`, in "The Go vmavs (in progress)": the `vmavs fetch` line
names the `firmware` target and says the shell tree's `build/`
downloads are adopted too. `grep -n "vmavs fetch" README.md` finds
every line that has to agree.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/fetch/ ./internal/cli/ && go vet ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/fetch internal/config internal/cli README.md
git commit   # subject: "vmavs fetch firmware: the firmware's sources through the verified cache"
```

---

### Task 4: Unpacking without `tar` or `unzip` (`firmware/unpack.go`)

**Files:**
- Create: `internal/firmware/unpack.go`, `internal/firmware/unpack_test.go`

**Interfaces:**
- Produces:
  - `untarGz(ctx context.Context, archive, dest string, strip int) error`
  - `extractKext(ctx context.Context, archive, name, dest string) error`
  - `mkdirsNoFollow(root, dir string) error`

  Everything is unexported. Tasks 9 and 11 are the only callers.

- [ ] **Step 1: Write the failing tests**

`internal/firmware/unpack_test.go` starts with the fixture builders.
Every archive a test reads is made here, so no third-party bytes are
committed:

```go
package firmware

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// entry is one member of a test archive. A name ending in "/" is a
// directory; link names a symlink's (or, with hard, a hard link's) target.
type entry struct {
	name, body, link string
	mode             int64
	hard             bool
	typ              byte // overrides the type when non-zero (a device, say)
}

// makeTarGz writes a GitHub-archive-shaped tarball: a pax global header
// first, then the entries.
func makeTarGz(t *testing.T, dir string, entries ...entry) string {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(tw.WriteHeader(&tar.Header{Typeflag: tar.TypeXGlobalHeader, Name: "pax_global_header",
		PAXRecords: map[string]string{"comment": "0672a009e9ca85753d240324d761341adf0291b3"}}))
	for _, e := range entries {
		h := &tar.Header{Name: e.name, Mode: 0o644, ModTime: time.Unix(1700000000, 0)}
		if e.mode != 0 {
			h.Mode = e.mode
		}
		switch {
		case e.typ != 0:
			h.Typeflag = e.typ
		case strings.HasSuffix(e.name, "/"):
			h.Typeflag, h.Mode = tar.TypeDir, 0o755
		case e.link != "" && e.hard:
			h.Typeflag, h.Linkname = tar.TypeLink, e.link
		case e.link != "":
			h.Typeflag, h.Linkname = tar.TypeSymlink, e.link
		default:
			h.Typeflag, h.Size = tar.TypeReg, int64(len(e.body))
		}
		must(tw.WriteHeader(h))
		if h.Typeflag == tar.TypeReg {
			_, err := tw.Write([]byte(e.body))
			must(err)
		}
	}
	must(tw.Close())
	must(zw.Close())
	p := filepath.Join(dir, "fixture.tar.gz")
	must(os.WriteFile(p, buf.Bytes(), 0o644))
	return p
}

// makeZip writes a zip with the given entries; a name ending in "/" is a
// directory entry; mode 0 means 0644 (0755 for a directory).
func makeZip(t *testing.T, dir, name string, entries ...entry) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, e := range entries {
		h := &zip.FileHeader{Name: e.name, Method: zip.Deflate}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(e.name, "/") {
			mode = os.ModeDir | 0o755
		}
		if e.mode != 0 {
			mode = os.FileMode(e.mode)
		}
		if e.link != "" {
			mode = os.ModeSymlink | 0o777
		}
		h.SetMode(mode)
		w, err := zw.CreateHeader(h)
		if err != nil {
			t.Fatal(err)
		}
		body := e.body
		if e.link != "" {
			body = e.link
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestUntarStripsTheTopDirectory(t *testing.T) {
	dir := t.TempDir()
	a := makeTarGz(t, dir,
		entry{name: "top/"},
		entry{name: "top/a.txt", body: "a"},
		entry{name: "top/sub/"},
		entry{name: "top/sub/run.sh", body: "#!/bin/sh\n", mode: 0o755},
	)
	dest := filepath.Join(dir, "out")
	if err := untarGz(context.Background(), a, dest, 1); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "a.txt")); string(b) != "a" {
		t.Fatalf("a.txt = %q", b)
	}
	fi, err := os.Stat(filepath.Join(dest, "sub", "run.sh"))
	if err != nil || fi.Mode().Perm()&0o100 == 0 {
		t.Fatalf("run.sh lost its execute bit: %v %v", fi, err)
	}
	if _, err := os.Stat(filepath.Join(dest, "top")); err == nil {
		t.Fatal("the top directory was not stripped")
	}
}
```

Add these tests. Each one writes its archive with `makeTarGz` or
`makeZip`:

1. **`TestUntarRefusesClimbingOut`.**
   - `top/../../evil` fails; the error says `..`.
   - `dest` does not exist afterwards, and neither does `evil` in
     `dir`'s parent.
   - `dir` holds no `.out.unpack-*` temp directory: glob for it.
2. **`TestUntarRefusesAbsoluteNames`.** `/etc/evil` fails.
3. **`TestUntarNeverWritesThroughASymlink`.**
   - A second temp dir `outside` is made.
   - The entries are `top/link` → `outside` (a symlink), then
     `top/link/x` with a body.
   - The call fails with "symlink".
   - `outside` is still empty.
4. **`TestUntarKeepsAnAbsoluteSymlinkAsASymlink`.**
   - The entry is `top/X11IncludeHack` → `/opt/X11/include`.
   - `os.Readlink` returns exactly that.
   - This is the audk case (Facts).
5. **`TestUntarMakesHardLinksToWhatItExtracted`.**
   - `top/f` has a body; `top/g` is a hard link to `top/f`.
   - `os.SameFile` holds for the two.
   - A hard link to `top/missing` fails.
6. **`TestUntarRefusesDevices`.** An entry of type `tar.TypeChar` fails
   and names the entry.
7. **`TestUntarRefusesAnExistingDest`.** `dest` already exists as an
   empty directory: the call fails, and `dest` is untouched.
8. **`TestUntarStopsWhenCancelled`.** An already-cancelled context
   returns `context.Canceled`, and nothing is left behind.
9. **`TestUntarWithoutStripKeepsTheTopDirectory`.** With `strip` 0,
   `dest/top/a.txt` exists.
10. **`TestExtractKextFindsTheBundleWhereverItIs`.**
    - The zip holds `Kexts/VirtualSMC.kext/Contents/Info.plist`,
      `Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC` (mode 0755),
      `dSYM/VirtualSMC.kext.dSYM/Contents/Info.plist` and
      `Tools/smcread`.
    - `extractKext(…, "VirtualSMC", dest)` gives `dest/Contents/Info.plist`
      and `dest/Contents/MacOS/VirtualSMC`, which is executable.
    - Nothing from `dSYM` or `Tools` is extracted.
11. **`TestExtractKextTakesTheFirstBundleAndItsNestedContents`.**
    - The zip holds `b/Lilu.kext/Contents/Info.plist` and
      `a/Lilu.kext/Contents/PlugIns/Lilu.kext/Contents/Info.plist`.
    - The chosen bundle is `a/Lilu.kext`, which sorts first. It keeps
      its nested `PlugIns/Lilu.kext/…` as content.
12. **`TestExtractKextFindsATopLevelBundleWithoutDirectoryEntries`.**
    Only the file entries `Lilu.kext/Contents/Info.plist` and
    `Lilu.kext/Contents/MacOS/Lilu` are there: it works.
13. **`TestExtractKextSaysSoWhenThereIsNoBundle`.** The error is exactly
    `<archive> contains no Lilu.kext`.
14. **`TestExtractKextRefusesSymlinksAndClimbingNames`.**
    - The entry `Lilu.kext/Contents/x` is a symlink: the call fails and
      names it.
    - `Lilu.kext/../../evil` fails too.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ -run 'Untar|ExtractKext' 2>&1 | head`
Expected: `undefined: untarGz`, `undefined: extractKext`.

- [ ] **Step 3: Implement `internal/firmware/unpack.go`**

```go
package firmware

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// untarGz extracts a gzip'd tar into dest, which must not exist, dropping
// the first strip components of every name -- `tar -xzf archive
// --strip-components=strip`, which is how the shell tree unpacks the
// pinned tarballs. It is built in a temp directory beside dest and
// renamed into place, so dest is either absent or complete.
//
// An archive's names are its author's choice, so: a name that is absolute
// or climbs out with ".." is refused; nothing is ever written through a
// symlink (every directory on the way to an entry is checked with Lstat,
// and files are created O_EXCL); a hard link must name a regular file
// this archive already put inside dest; devices and FIFOs are refused.
// Symlinks are created as they are, as tar creates them -- audk's tarball
// carries one absolute symlink, which the build never follows. File modes
// keep their permission bits (execute matters: build_oc.tool) and file
// times are the archive's, as tar sets them.
func untarGz(ctx context.Context, archive, dest string, strip int) (err error) {
	if _, err := os.Lstat(dest); err == nil {
		return fmt.Errorf("cannot unpack %s: %s already exists", archive, dest)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	parent := filepath.Dir(dest)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(parent, "."+filepath.Base(dest)+".unpack-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(tmp)
		}
	}()

	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("%s: %w", archive, err)
	}
	tr := tar.NewReader(zr)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("%s: %w", archive, err)
		}
		if h.Typeflag == tar.TypeXGlobalHeader {
			continue // GitHub's pax_global_header: the commit id, not a file
		}
		rel, ok, err := stripName(h.Name, strip)
		if err != nil {
			return fmt.Errorf("%s: %w", archive, err)
		}
		if !ok {
			continue
		}
		target := filepath.Join(tmp, filepath.FromSlash(rel))
		if err := mkdirsNoFollow(tmp, filepath.Dir(target)); err != nil {
			return fmt.Errorf("%s: %s: %w", archive, h.Name, err)
		}
		switch h.Typeflag {
		case tar.TypeDir:
			err = mkdirsNoFollow(tmp, target)
		case tar.TypeReg:
			err = writeNew(target, tr, os.FileMode(h.Mode).Perm(), h.ModTime)
		case tar.TypeSymlink:
			err = os.Symlink(h.Linkname, target)
		case tar.TypeLink:
			err = hardLink(tmp, h.Linkname, strip, target)
		default:
			err = fmt.Errorf("unsupported entry type %q", h.Typeflag)
		}
		if err != nil {
			return fmt.Errorf("%s: %s: %w", archive, h.Name, err)
		}
	}
	return os.Rename(tmp, dest)
}

// stripName cleans an archive member's name and drops its first strip
// components. ok is false when nothing is left: the entry is one of the
// directories being stripped.
func stripName(name string, strip int) (string, bool, error) {
	if strings.HasPrefix(name, "/") {
		return "", false, fmt.Errorf("%s: an absolute name", name)
	}
	var parts []string
	for _, p := range strings.Split(name, "/") {
		switch p {
		case "", ".":
		case "..":
			return "", false, fmt.Errorf("%s: climbs out with ..", name)
		default:
			parts = append(parts, p)
		}
	}
	if len(parts) <= strip {
		return "", false, nil
	}
	return path.Join(parts[strip:]...), true, nil
}

// mkdirsNoFollow makes dir, and any missing parent between root and it,
// refusing to pass through anything that is not a real directory -- in
// particular a symlink an earlier archive entry created.
func mkdirsNoFollow(root, dir string) error {
	rel, err := filepath.Rel(root, dir)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("%s is outside %s", dir, root)
	}
	if rel == "." {
		return nil
	}
	cur := root
	for _, p := range strings.Split(rel, string(filepath.Separator)) {
		cur = filepath.Join(cur, p)
		fi, err := os.Lstat(cur)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := os.Mkdir(cur, 0o755); err != nil {
				return err
			}
		case err != nil:
			return err
		case !fi.IsDir():
			return fmt.Errorf("%s is not a directory (a symlink?); refusing to write through it", cur)
		}
	}
	return nil
}

// writeNew creates path, which must not exist, from r.
func writeNew(path string, r io.Reader, perm os.FileMode, mtime time.Time) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if mtime.IsZero() {
		return nil
	}
	return os.Chtimes(path, mtime, mtime)
}

// hardLink makes target a hard link to the archive member linkname, which
// must be a regular file already extracted under root, reached without
// passing through a symlink.
func hardLink(root, linkname string, strip int, target string) error {
	rel, ok, err := stripName(linkname, strip)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("hard link to %s, which is stripped away", linkname)
	}
	src := filepath.Join(root, filepath.FromSlash(rel))
	if err := mkdirsNoFollow(root, filepath.Dir(src)); err != nil {
		return err
	}
	fi, err := os.Lstat(src)
	if err != nil {
		return fmt.Errorf("hard link to %s: %w", linkname, err)
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("hard link to %s, which is not a regular file", linkname)
	}
	return os.Link(src, target)
}

// extractKext copies the bundle name.kext out of a release zip into dest,
// which must not exist. The releases disagree on where the bundle sits --
// Lilu's is at the top, VirtualSMC's under Kexts/ -- so it is searched for
// the way boot/fetch-kexts.sh does with `find -name X.kext -type d -prune
// | sort | head -n 1`: every directory named name.kext that is not inside
// another one, and the lexically first of those. A zip may list only
// files, so a directory is recognised by having something below it.
func extractKext(ctx context.Context, archive, name, dest string) (err error) {
	want := name + ".kext"
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return fmt.Errorf("cannot unpack %s: %w", archive, err)
	}
	defer zr.Close()

	roots := map[string]bool{}
	for _, f := range zr.File {
		parts := strings.Split(strings.TrimSuffix(f.Name, "/"), "/")
		for i, p := range parts {
			if p != want {
				continue
			}
			if i < len(parts)-1 || strings.HasSuffix(f.Name, "/") {
				roots[strings.Join(parts[:i+1], "/")] = true
			}
			break // -prune: nothing below the first match is a candidate
		}
	}
	if len(roots) == 0 {
		return fmt.Errorf("%s contains no %s", archive, want)
	}
	var cands []string
	for r := range roots {
		cands = append(cands, r)
	}
	sort.Strings(cands)
	root := cands[0]

	if _, err := os.Lstat(dest); err == nil {
		return fmt.Errorf("cannot unpack %s: %s already exists", archive, dest)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(dest), "."+filepath.Base(dest)+".unpack-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(tmp)
		}
	}()
	for _, f := range zr.File {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := strings.TrimSuffix(f.Name, "/")
		if n != root && !strings.HasPrefix(n, root+"/") {
			continue
		}
		rel, ok, err := stripName(strings.TrimPrefix(strings.TrimPrefix(n, root), "/"), 0)
		if err != nil {
			return fmt.Errorf("%s: %w", archive, err)
		}
		if !ok {
			continue // the bundle directory itself
		}
		target := filepath.Join(tmp, filepath.FromSlash(rel))
		if err := mkdirsNoFollow(tmp, filepath.Dir(target)); err != nil {
			return fmt.Errorf("%s: %s: %w", archive, f.Name, err)
		}
		mode := f.Mode()
		switch {
		case mode.IsDir():
			err = mkdirsNoFollow(tmp, target)
		case mode.IsRegular():
			err = extractZipFile(f, target)
		default:
			err = fmt.Errorf("refusing a %v entry", mode.Type())
		}
		if err != nil {
			return fmt.Errorf("%s: %s: %w", archive, f.Name, err)
		}
	}
	return os.Rename(tmp, dest)
}

func extractZipFile(f *zip.File, target string) error {
	r, err := f.Open()
	if err != nil {
		return err
	}
	defer r.Close()
	perm := os.FileMode(0o644)
	if f.Mode().Perm()&0o111 != 0 {
		perm = 0o755
	}
	return writeNew(target, r, perm, f.Modified)
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -run 'Untar|ExtractKext' -v 2>&1 | tail -25 && go vet ./internal/firmware/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware/unpack.go internal/firmware/unpack_test.go
git commit   # subject: "firmware: unpack the pinned tarballs and kext zips without tar or unzip, and never through a symlink"
```

---

### Task 5: The compiler range and ccache (`firmware/compiler.go`, `ccache.go`)

**Files:**
- Create: `internal/firmware/compiler.go`, `internal/firmware/ccache.go`, `internal/firmware/toolchain_test.go`

**Interfaces:**
- Consumes: `proc.Runner`, `proc.Cmd` (with `Stdout`).
- Produces:
  - Constants: `CCFamily = "gcc"`, `CCFloor = 13`, `CCCeiling = 16`,
    `CCVerified = "13.3.0"`, `CCVerifiedList = "13.3.0, 14.2.0 and 16.2.1"`.
  - Pure functions:
    - `RangeText() string`
    - `ParseCompiler(banner string) (family, version string)`
    - `RangeVerdict(family, version string) (verdict, detail string)`,
      where verdict is `INSIDE`, `BELOW`, `ABOVE` or `UNKNOWN`
  - `type Toolchain struct{ Runner proc.Runner; GCCBin, Override string }`,
    with these methods:
    - `(Toolchain) GCC() string`: `GCCBin + "gcc"`
    - `(Toolchain) Status(ctx) (verdict, detail string)`
    - `(Toolchain) RangeLine(ctx) string`
    - `(Toolchain) CompilerLine(ctx) string`
    - `(Toolchain) Check(ctx, logf func(string, ...any)) error`
  - ccache:
    - `CcacheVerdict(wanted bool, path string) (verdict, detail string)`,
      where verdict is `USED`, `MISSING` or `OFF`
    - `CcacheLine(verdict, detail string) string`
    - `writeCcacheShims(dir, ccache string, lookPath func(string) (string, error)) error`

  Phase 5's manifest will record `CompilerLine`, `RangeLine`, the
  ccache line and `BuildOptions`, as `build-image.sh` records
  `--compiler`, `--compiler-range`, `--ccache` and `--build-options`
  today.

- [ ] **Step 1: Write the failing tests**

`internal/firmware/toolchain_test.go`:

```go
package firmware

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

// shellLib runs a lib/*.sh function under bash and returns its stdout.
func shellLib(t *testing.T, libs []string, call string) string {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	src := ". lib/common.sh"
	for _, l := range libs {
		src += "; . lib/" + l
	}
	cmd := exec.Command("bash", "-c", src+"; "+call)
	cmd.Dir = repo(t)
	cmd.Env = append(os.Environ(), "MQG_COMPILER=", "MQG_CCACHE=", "MQG_CCACHE_BIN=")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s: %v", call, err)
	}
	return string(out)
}

func TestRangeVerdictMatchesTheLibrary(t *testing.T) {
	cases := [][2]string{
		{"gcc", "12.4.0"}, {"gcc", "13.0.0"}, {"gcc", "13.3.0"}, {"gcc", "15.1.1"},
		{"gcc", "16.2.1"}, {"gcc", "17.0.0"}, {"gcc", "x.y"}, {"clang", "17.0.0"},
		{"clang", ""}, {"unknown", ""},
	}
	for _, c := range cases {
		v, d := RangeVerdict(c[0], c[1])
		want := shellLib(t, []string{"compiler.sh"}, "compiler_range_verdict '"+c[0]+"' '"+c[1]+"'")
		if got := v + "\t" + d + "\n"; got != want {
			t.Errorf("%v:\n go:    %q\n shell: %q", c, got, want)
		}
	}
}

func TestParseCompilerMatchesTheLibrary(t *testing.T) {
	banners := []string{
		"gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0",
		"gcc (GCC) 15.1.1 20250425",
		"cc (GCC) 14.2.0",
		"x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0",
		"Apple clang version 17.0.0 (clang-1700.0.13)",
		"clang version 18.1.3",
		"gcc 13.3.0",
		"tcc version 0.9.27",
		"",
	}
	for _, b := range banners {
		fam, ver := ParseCompiler(b)
		want := shellLib(t, []string{"compiler.sh"}, "compiler_parse '"+b+"'")
		if got := fam + "\t" + ver + "\t" + b + "\n"; got != want {
			t.Errorf("%q:\n go:    %q\n shell: %q", b, got, want)
		}
	}
}

func TestTheDeclaredRangeIsGcc13Through16(t *testing.T) {
	if RangeText() != "gcc 13 through 16, verified at gcc 13.3.0, 14.2.0 and 16.2.1" {
		t.Fatal(RangeText())
	}
	if got := shellLib(t, []string{"compiler.sh"}, "compiler_range_text; echo"); got != RangeText()+"\n" {
		t.Fatalf("shell says %q", got)
	}
}

// gccFake answers `gcc --version` and `gcc -dumpmachine` as banner and
// target, and knows gcc is on PATH unless banner is "".
func gccFake(banner, target string) *proc.Fake {
	f := &proc.Fake{Paths: map[string]string{}}
	if banner != "" {
		f.Paths["gcc"] = "/usr/bin/gcc"
	}
	f.Handle = func(c proc.Cmd) error {
		if c.Name == "gcc" && len(c.Args) == 1 && c.Stdout != nil {
			switch c.Args[0] {
			case "--version":
				c.Stdout.Write([]byte(banner + "\nCopyright (C) 2023\n"))
			case "-dumpmachine":
				c.Stdout.Write([]byte(target + "\n"))
			}
		}
		return nil
	}
	return f
}

func TestStatusNamesWhatItCouldNotRead(t *testing.T) {
	ctx := context.Background()
	v, d := Toolchain{Runner: gccFake("tcc version 0.9.27", "x")}.Status(ctx)
	if v != "UNKNOWN" || !strings.HasSuffix(d, `; it said "tcc version 0.9.27"`) {
		t.Fatalf("%s %s", v, d)
	}
	v, d = Toolchain{Runner: gccFake("", "")}.Status(ctx)
	if v != "UNKNOWN" || !strings.HasSuffix(d, "; gcc is not on PATH or did not answer --version") {
		t.Fatalf("%s %s", v, d)
	}
}

func TestTheOverrideReplacesDetectionAndIsRecorded(t *testing.T) {
	tc := Toolchain{Runner: gccFake("gcc (GCC) 12.1.0", "x"), Override: "gcc 15.1.0"}
	if v, _ := tc.Status(context.Background()); v != "INSIDE" {
		t.Fatalf("verdict %s", v)
	}
	line := tc.RangeLine(context.Background())
	if !strings.HasPrefix(line, "INSIDE -- gcc 15.1.0 is inside") ||
		!strings.HasSuffix(line, " [--compiler override in effect: gcc 15.1.0]") {
		t.Fatal(line)
	}
	// The override moves nothing else: the compiler line is the real one.
	if cl := tc.CompilerLine(context.Background()); !strings.HasPrefix(cl, "gcc (GCC) 12.1.0 (x) -std=gnu17") {
		t.Fatal(cl)
	}
}

func TestCompilerLine(t *testing.T) {
	ctx := context.Background()
	tc := Toolchain{Runner: gccFake("gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0", "x86_64-linux-gnu")}
	if got := tc.CompilerLine(ctx); got != "gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 (x86_64-linux-gnu) -std=gnu17" {
		t.Fatal(got)
	}
	if got := (Toolchain{Runner: gccFake("", "")}).CompilerLine(ctx); got != "gcc not found" {
		t.Fatal(got)
	}
	if got := (Toolchain{Runner: gccFake("", ""), GCCBin: "x86_64-elf-"}).GCC(); got != "x86_64-elf-gcc" {
		t.Fatal(got)
	}
}

func TestCheckRefusesBelowTheFloorAndWarnsAbove(t *testing.T) {
	ctx := context.Background()
	var log bytes.Buffer
	logf := func(f string, a ...any) { log.WriteString(fmt.Sprintf(f, a...) + "\n") }

	err := Toolchain{Runner: gccFake("gcc (GCC) 12.2.0", "x")}.Check(ctx, logf)
	if err == nil || !strings.Contains(err.Error(), "below the floor") {
		t.Fatalf("below: %v", err)
	}
	if !strings.Contains(log.String(), "NOT tested") || !strings.Contains(log.String(), "--compiler") {
		t.Fatalf("below log: %s", log.String())
	}

	log.Reset()
	if err := (Toolchain{Runner: gccFake("gcc (GCC) 17.1.0", "x")}).Check(ctx, logf); err != nil {
		t.Fatalf("above must proceed: %v", err)
	}
	if !strings.Contains(log.String(), "above the ceiling") || !strings.Contains(log.String(), "not proof") {
		t.Fatalf("above log: %s", log.String())
	}

	log.Reset()
	if err := (Toolchain{Runner: gccFake("tcc version 0.9.27", "x")}).Check(ctx, logf); err != nil {
		t.Fatalf("unknown must proceed: %v", err)
	}
	if !strings.Contains(log.String(), "--compiler") {
		t.Fatalf("unknown log: %s", log.String())
	}
}

func TestCcacheIsOffByDefault(t *testing.T) {
	if CcacheDefault {
		t.Fatal("ccache must stay off until someone measures it (lib/ccache.sh)")
	}
	if got := shellLib(t, []string{"ccache.sh"}, `printf '%s\n' "$MQG_CCACHE_DEFAULT"`); got != "0\n" {
		t.Fatalf("shell default %q", got)
	}
}

// The verdicts are the library's, word for word, except where the shell
// names its environment variable and Go names its flag.
func TestCcacheVerdictMatchesTheLibrary(t *testing.T) {
	flagForVar := strings.NewReplacer(
		"MQG_CCACHE=1 but ccache", "--ccache was given but ccache",
		"set MQG_CCACHE=1.", "pass --ccache.",
	)
	for _, c := range []struct {
		wanted bool
		path   string
	}{{true, "/usr/bin/ccache"}, {true, ""}, {false, "/usr/bin/ccache"}, {false, ""}} {
		w := "0"
		if c.wanted {
			w = "1"
		}
		v, d := CcacheVerdict(c.wanted, c.path)
		want := flagForVar.Replace(shellLib(t, []string{"ccache.sh"}, "ccache_verdict "+w+" '"+c.path+"'"))
		if got := v + "\t" + d + "\n"; got != want {
			t.Errorf("%v:\n go:    %q\n shell: %q", c, got, want)
		}
	}
	if CcacheLine("USED", "/usr/bin/ccache") != "used (/usr/bin/ccache)" ||
		CcacheLine("OFF", "ccache is not installed; every file is compiled") != "not used -- ccache is not installed; every file is compiled" {
		t.Fatal("CcacheLine")
	}
}

func TestTheShimWrapsTheRealCompilerByAbsolutePath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip()
	}
	dir := filepath.Join(t.TempDir(), "ccache-bin")
	look := func(n string) (string, error) {
		if n == "gcc" {
			return "/usr/bin/gcc", nil
		}
		return "", exec.ErrNotFound
	}
	if err := writeCcacheShims(dir, "/usr/bin/ccache", look); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "gcc"))
	if err != nil || string(b) != "#!/bin/sh\nexec /usr/bin/ccache /usr/bin/gcc \"$@\"\n" {
		t.Fatalf("%q %v", b, err)
	}
	if fi, _ := os.Stat(filepath.Join(dir, "gcc")); fi.Mode().Perm() != 0o755 {
		t.Fatalf("mode %v", fi.Mode())
	}
	if _, err := os.Stat(filepath.Join(dir, "g++")); err == nil {
		t.Fatal("no g++ on PATH, so no g++ shim")
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ -run 'Range|Parse|Status|Override|CompilerLine|Check|Ccache|Shim' 2>&1 | head`
Expected: undefined symbols.

- [ ] **Step 3: Implement**

`internal/firmware/compiler.go`. Read `lib/compiler.sh` in full first:
its header is the argument behind every sentence below, and the Go
doc comments should keep that argument in shortened form.

```go
package firmware

import (
	"bytes"
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

// The compiler range: a claim about which compilers this project has a
// reason to believe in, not a pin (docs/decisions/0004). lib/compiler.sh
// records what each row rests on; the constants are held equal to it by
// TestTheDeclaredRangeIsGcc13Through16.
const (
	CCFamily       = "gcc"
	CCFloor        = 13
	CCCeiling      = 16
	CCVerified     = "13.3.0"
	CCVerifiedList = "13.3.0, 14.2.0 and 16.2.1"
)

// RangeText is the declared range as one phrase.
func RangeText() string {
	return fmt.Sprintf("%s %d through %d, verified at %s %s", CCFamily, CCFloor, CCCeiling, CCFamily, CCVerifiedList)
}

var versionField = regexp.MustCompile(`^[0-9]+(\.[0-9]+)*$`)

// versionToken is the banner's first field that is a bare dotted number.
func versionToken(banner string) string {
	for _, f := range strings.Fields(banner) {
		if versionField.MatchString(f) {
			return f
		}
	}
	return ""
}

// ParseCompiler reads a `cc --version` first line. clang is checked
// first: on macOS `gcc` IS clang, and parsing its banner as GCC would
// judge a clang version against a GCC range.
func ParseCompiler(banner string) (family, version string) {
	if strings.Contains(banner, "clang") || strings.Contains(banner, "LLVM") {
		return "clang", versionToken(banner)
	}
	first, _, _ := strings.Cut(banner, " ")
	switch {
	case first == "gcc", first == "cc", first == "c99", first == "g++",
		strings.HasSuffix(first, "-gcc"), strings.HasSuffix(first, "-g++"):
		if v := versionToken(banner); v != "" {
			return "gcc", v
		}
	}
	return "unknown", ""
}

// RangeVerdict judges a compiler against the range. Pure, so every branch
// is testable on a host with one compiler.
func RangeVerdict(family, version string) (verdict, detail string) {
	switch family {
	case CCFamily:
	case "clang":
		v := version
		if v == "" {
			v = "(no version)"
		}
		return "UNKNOWN", fmt.Sprintf("clang %s: this project builds with TOOLCHAINS=GCC and has never built with clang, so the declared range (%s) does not cover it", v, RangeText())
	default:
		return "UNKNOWN", fmt.Sprintf("not a recognised %s: the range (%s) has nothing to say about it", CCFamily, RangeText())
	}
	majorText, _, _ := strings.Cut(version, ".")
	major, err := strconv.Atoi(majorText)
	if err != nil || strings.Trim(majorText, "0123456789") != "" {
		return "UNKNOWN", `cannot read a major version out of "` + version + `"`
	}
	switch {
	case major < CCFloor:
		return "BELOW", fmt.Sprintf("%s %s is below the floor of this project's supported range, %s", family, version, RangeText())
	case major > CCCeiling:
		return "ABOVE", fmt.Sprintf("%s %s is above the ceiling of this project's supported range, %s", family, version, RangeText())
	}
	return "INSIDE", fmt.Sprintf("%s %s is inside this project's supported range, %s", family, version, RangeText())
}

// Toolchain is the host compiler EDK II will run: DEF(GCC_X64_PREFIX)gcc,
// where GCC_X64_PREFIX is ENV(GCC_BIN) -- usually empty, so plain gcc.
// Override is --compiler: "NAME VERSION" to believe instead of asking the
// compiler. It moves nothing else; CompilerLine still reports the real
// compiler, so a manifest shows the two disagreeing.
type Toolchain struct {
	Runner   proc.Runner
	GCCBin   string
	Override string
}

// GCC is the compiler's command name.
func (tc Toolchain) GCC() string { return tc.GCCBin + "gcc" }

// output is the first line cmd prints, or "" if it cannot be run.
func (tc Toolchain) output(ctx context.Context, args ...string) string {
	if _, err := tc.Runner.LookPath(tc.GCC()); err != nil {
		return ""
	}
	var out bytes.Buffer
	if err := tc.Runner.Run(ctx, proc.Cmd{Name: tc.GCC(), Args: args, Stdout: &out}); err != nil {
		return ""
	}
	line, _, _ := strings.Cut(out.String(), "\n")
	return strings.TrimSpace(line)
}

// Status is this host's compiler against the range. An UNKNOWN names
// what it could not read: a banner it cannot parse, or no compiler.
func (tc Toolchain) Status(ctx context.Context) (verdict, detail string) {
	banner := tc.Override
	if banner == "" {
		banner = tc.output(ctx, "--version")
	}
	verdict, detail = RangeVerdict(ParseCompiler(banner))
	if verdict == "UNKNOWN" {
		if banner != "" {
			detail += `; it said "` + banner + `"`
		} else {
			detail += "; " + tc.GCC() + " is not on PATH or did not answer --version"
		}
	}
	return verdict, detail
}
```

```go
// RangeLine is one line for the manifest: what the range said about the
// compiler when the image was built, which the range cannot answer later
// because it moves as evidence arrives.
func (tc Toolchain) RangeLine(ctx context.Context) string {
	v, d := tc.Status(ctx)
	line := v + " -- " + d
	if tc.Override != "" {
		line += " [--compiler override in effect: " + tc.Override + "]"
	}
	return line
}

// CompilerLine is the compiler EDK II will actually run, as one line
// (build-opencore.sh --compiler): never influenced by Override.
func (tc Toolchain) CompilerLine(ctx context.Context) string {
	ver := tc.output(ctx, "--version")
	if ver == "" {
		if _, err := tc.Runner.LookPath(tc.GCC()); err != nil {
			return tc.GCC() + " not found"
		}
		ver = "unknown"
	}
	target := tc.output(ctx, "-dumpmachine")
	if target == "" {
		target = "unknown-target"
	}
	return fmt.Sprintf("%s (%s) -std=%s", ver, target, CStd)
}

// Check is the gate the builds call before anything expensive. Only a
// compiler below the floor stops it; above the ceiling and "cannot tell"
// warn and carry on (lib/compiler.sh explains why each).
func (tc Toolchain) Check(ctx context.Context, logf func(string, ...any)) error {
	v, d := tc.Status(ctx)
	if tc.Override != "" {
		logf("warning: --compiler is set: treating this host's compiler as %q", tc.Override)
	}
	switch v {
	case "INSIDE":
		logf("compiler: %s", d)
	case "ABOVE":
		logf("warning: compiler: %s", d)
		for _, l := range []string{
			"this is untested territory, not known-bad: building anyway.",
			"A new compiler's new warnings no longer stop the firmware build (upstream's",
			"-Werror is not inherited -- decisions/0004). They are still printed, and up",
			"here they are worth reading. Up here the failure mode is usually not an error:",
			"OvmfPkg compiled clean under C23 and produced different firmware bytes. So a",
			"green build is not proof you got the artifacts decisions/0004 describes:",
			"compare its checksums. Either answer is worth reporting -- that is how the",
			"ceiling moves.",
		} {
			logf("warning: %s", l)
		}
	case "UNKNOWN":
		logf("warning: compiler: %s", d)
		logf("warning: proceeding with the range unchecked. If you know what this compiler is, say so: --compiler '<name> <version>'.")
	case "BELOW":
		logf("warning: compiler: %s", d)
		for _, l := range []string{
			"This project has NOT tested it. That is not the same as knowing it fails:",
			"nobody has ever tried. Its code generation would be a different artifact",
			"than the checksums in docs/decisions/0004 describe.",
			fmt.Sprintf("To build anyway, say what to believe: --compiler '%s %s'.", CCFamily, CCVerified),
			"The manifest still records the real compiler, so the two lines will disagree",
			"where anyone can see them.",
		} {
			logf("warning: %s", l)
		}
		return fmt.Errorf("unsupported compiler -- %s", d)
	}
	return nil
}
```

`internal/firmware/ccache.go`:

```go
package firmware

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// CcacheDefault is off: docs/decisions/0004 claims the firmware is
// reproducible, and nobody has yet shown that a ccache build produces the
// same eight checksums as a cold one. lib/ccache.sh records what WAS
// measured (the PATH-shim seam changes nothing) and what would move this.
const CcacheDefault = false

// CcacheVerdict judges whether ccache will be used. Pure.
//
//	USED     asked for, and present.
//	MISSING  asked for, and not installed: warn and build anyway.
//	OFF      not asked for; the detail says whether it is even here.
func CcacheVerdict(wanted bool, path string) (verdict, detail string) {
	switch {
	case wanted && path != "":
		return "USED", path
	case wanted:
		return "MISSING", "--ccache was given but ccache is not installed; compiling everything"
	case path != "":
		return "OFF", fmt.Sprintf("ccache is installed at %s but not used: pass --ccache. The default is off because nobody has yet shown that a ccache build produces the same eight checksums as a cold one -- see lib/ccache.sh", path)
	}
	return "OFF", "ccache is not installed; every file is compiled"
}

// CcacheLine is one line for the manifest and the build log.
func CcacheLine(verdict, detail string) string {
	if verdict == "USED" {
		return "used (" + detail + ")"
	}
	return "not used -- " + detail
}

// writeCcacheShims writes gcc and g++ wrappers into dir that run ccache
// on the real compiler, found by absolute path before dir is on PATH --
// a wrapper that said `exec ccache gcc` would find itself. A PATH shim
// rather than GCC_BIN: GCC_X64_PREFIX is glued onto ld, objcopy and ar
// too, and pointing it at two wrappers would hide the rest of binutils.
// A compiler that is not installed gets no wrapper.
func writeCcacheShims(dir, ccache string, lookPath func(string) (string, error)) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("cannot create the ccache shim directory %s: %w", dir, err)
	}
	for _, tool := range []string{"gcc", "g++"} {
		real, err := lookPath(tool)
		if err != nil || strings.HasPrefix(real, dir+string(filepath.Separator)) {
			continue
		}
		body := fmt.Sprintf("#!/bin/sh\nexec %s %s \"$@\"\n", ccache, real)
		p := filepath.Join(dir, tool)
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			return err
		}
		if err := os.Chmod(p, 0o755); err != nil { // WriteFile's mode is masked by umask
			return err
		}
	}
	return nil
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -v 2>&1 | grep -E '^(=== RUN|--- FAIL|FAIL|ok|PASS)' | tail -30`
Expected: PASS. The two parity tests run against `lib/compiler.sh` and
`lib/ccache.sh` here.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware/compiler.go internal/firmware/ccache.go internal/firmware/toolchain_test.go
git commit   # subject: "firmware: the compiler range and ccache, word for word with lib/compiler.sh and lib/ccache.sh"
```

---

### Task 6: SMBIOS (`firmware/smbios.go`)

**Files:**
- Create: `internal/firmware/smbios.go`, `internal/firmware/smbios_test.go`

**Interfaces:**
- Produces:
  - `DefaultSMBIOS = "iMac14,2"`
  - `SMBIOSWellformed(model string) bool`
  - `type SMBIOSModel struct{ Model, Status, Evidence string }` and
    `var SMBIOSModels []SMBIOSModel`
  - `SMBIOSStatusText(status string) string`
  - `SMBIOSVerdict(model string) (status, detail string)`
  - `SMBIOSManifest(model string) string`
  - `SMBIOSCheck(model string, logf func(string, ...any))`, which never
    fails
  - `ProductName(plist []byte) string`
  - `SetProductName(plist []byte, model string) ([]byte, error)`

- [ ] **Step 1: Write the failing tests**

`internal/firmware/smbios_test.go`:

```go
package firmware

import (
	"io/fs"
	"os/exec"
	"strings"
	"testing"

	vmguest "github.com/Mavergreen/vm-guest"
)

func config(t *testing.T) []byte {
	t.Helper()
	b, err := fs.ReadFile(vmguest.Files, "boot/config/config.plist")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTheTableIsTheLibrarysWordForWord(t *testing.T) {
	var got strings.Builder
	for _, m := range SMBIOSModels {
		got.WriteString(m.Model + "\t" + m.Status + "\t" + m.Evidence + "\n")
	}
	if want := shellLib(t, []string{"smbios.sh"}, "smbios_models"); got.String() != want {
		t.Fatalf("go:\n%s\nshell:\n%s", got.String(), want)
	}
}

func TestTheDefaultIsWhatConfigPlistShips(t *testing.T) {
	if DefaultSMBIOS != "iMac14,2" || ProductName(config(t)) != DefaultSMBIOS {
		t.Fatalf("default %s, config.plist %s", DefaultSMBIOS, ProductName(config(t)))
	}
}

func TestVerdictsAndManifestLinesMatchTheLibrary(t *testing.T) {
	for _, m := range []string{"iMac14,2", "MacPro5,1", "Macmini6,2"} {
		s, d := SMBIOSVerdict(m)
		if want := shellLib(t, []string{"smbios.sh"}, "smbios_verdict '"+m+"'"); s+"\t"+d+"\n" != want {
			t.Errorf("verdict %s:\n go:    %q\n shell: %q", m, s+"\t"+d, want)
		}
		if want := shellLib(t, []string{"smbios.sh"}, "smbios_manifest '"+m+"'"); SMBIOSManifest(m)+"\n" != want {
			t.Errorf("manifest %s differs", m)
		}
	}
	for _, st := range []string{"VERIFIED", "BOOTED", "PANICKED", "NOT-TESTED", "UNLISTED", "WEIRD"} {
		if want := shellLib(t, []string{"smbios.sh"}, "smbios_status_text '"+st+"'"); SMBIOSStatusText(st) != want {
			t.Errorf("status text %s differs", st)
		}
	}
}

func TestWellformedness(t *testing.T) {
	for m, ok := range map[string]bool{
		"iMac14,2": true, "MacPro5,1": true, "My_Model-1.0": true,
		"": false, "iMac<14>": false, "a b": false, "a&b": false, `a"b`: false, "a\nb": false,
		strings.Repeat("a", 64): true, strings.Repeat("a", 65): false,
	} {
		if SMBIOSWellformed(m) != ok {
			t.Errorf("%q: want %v", m, ok)
		}
	}
}

func TestSetProductNameMatchesTheLibraryByteForByte(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	for _, m := range []string{"MacPro5,1", "iMac14,2"} {
		got, err := SetProductName(config(t), m)
		if err != nil {
			t.Fatal(err)
		}
		want := shellLib(t, []string{"smbios.sh"}, "smbios_plist_set boot/config/config.plist '"+m+"'")
		if string(got) != want {
			t.Errorf("%s: the edit differs from smbios_plist_set", m)
		}
	}
	if same, _ := SetProductName(config(t), DefaultSMBIOS); string(same) != string(config(t)) {
		t.Fatal("setting the model already there must not change a byte")
	}
}

func TestSetProductNameRefusesWhatItCannotDoSafely(t *testing.T) {
	if _, err := SetProductName(config(t), "a<b"); err == nil {
		t.Fatal("a malformed model must be refused")
	}
	two := strings.Replace(string(config(t)), "<key>SystemProductName</key>",
		"<key>SystemProductName</key>\n<string>x</string>\n<key>SystemProductName</key>", 1)
	if _, err := SetProductName([]byte(two), "MacPro5,1"); err == nil || !strings.Contains(err.Error(), "2 SystemProductName keys") {
		t.Fatalf("err = %v", err)
	}
	if _, err := SetProductName([]byte("<plist></plist>\n"), "MacPro5,1"); err == nil || !strings.Contains(err.Error(), "0 SystemProductName keys") {
		t.Fatalf("err = %v", err)
	}
}

func TestCheckNeverFails(t *testing.T) {
	var log strings.Builder
	logf := func(f string, a ...any) { log.WriteString(f + "\n") }
	for _, m := range []string{"iMac14,2", "MacPro5,1", "Macmini6,2"} {
		SMBIOSCheck(m, logf) // no error to return: the table is guidance
	}
	if !strings.Contains(log.String(), "warning") {
		t.Fatal("an unlisted or panicked model must warn")
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ -run 'Table|Default|Verdicts|Wellformed|ProductName|NeverFails' 2>&1 | head`
Expected: undefined symbols.

- [ ] **Step 3: Implement `internal/firmware/smbios.go`**

Read `lib/smbios.sh` in full first. Port it with these rules:

- `SMBIOSModels` holds the two rows of `MQG_SMBIOS_MODELS`, in order.
  Copy each Evidence string **verbatim** from `lib/smbios.sh`:
  everything after the second tab on its row, to the end of the line.
  Use Go raw strings only where a row has no backquote; otherwise use
  an interpreted string with `\"` escapes.
  `TestTheTableIsTheLibrarysWordForWord` catches a single wrong byte.
- `SMBIOSStatusText` has the five sentences of `smbios_status_text`,
  and `unknown status "<s>"` for anything else. The shell prints them
  with no trailing newline, so the Go strings have none either.
- `SMBIOSVerdict(model)`:
  - For a listed model it returns `(status, statusText + " -- " + evidence)`.
  - Otherwise it returns `("UNLISTED", statusText("UNLISTED") + ` -- "` + model + `" is not in this project's tested-options table; the default is iMac14,2 (docs/decisions/0010)`)`.
- `SMBIOSManifest` is `status + " -- " + detail`.
- `SMBIOSCheck` ports `smbios_check`'s messages:
  - it logs the detail;
  - it adds the warning lines per status, prefixed `warning: `;
  - it never returns an error.

  Name `vm/screenshot.sh` as the shell does until phase 6 ports it.
- `ProductName(plist)` is `smbios_plist_product_name`:
  1. Find the first line containing `<key>SystemProductName</key>`.
  2. Take the next line at or after it that contains `<string>`. That
     includes the key line itself only if the key and the string share
     a line; the awk skips the key line with `next`, so start at the
     line after it.
  3. Strip everything up to and including `<string>`, and everything
     from `</string>` on.
  4. Return `""` if there is no such line.
- `SetProductName(plist, model)` is `smbios_plist_set`:
  1. Refuse a model for which `SMBIOSWellformed` is false. The error
     quotes the shell's.
  2. Count the lines containing `<key>SystemProductName</key>` (as
     `grep -c` does). If the count is not 1, return
     `fmt.Errorf("smbios: %d SystemProductName keys, expected 1; refusing to guess which one PlatformInfo reads", n)`.
  3. Walk the lines. After the key line, the first line containing
     `<string>` is replaced by its leading run of non-`<` characters,
     then `<string>` + model + `</string>`.
  4. Output every line followed by `\n`, as awk prints it. Split the
     input as `strings.Split(strings.TrimSuffix(s, "\n"), "\n")`, so a
     final newline is not doubled.
  5. If no `<string>` line followed the key, return
     `smbios: no <string> after <key>SystemProductName</key>`.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -run 'Table|Default|Verdicts|Wellformed|ProductName|NeverFails' -v 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware/smbios.go internal/firmware/smbios_test.go
git commit   # subject: "firmware: the SMBIOS table and the one-value plist edit, byte for byte with lib/smbios.sh"
```

---

### Task 7: The GUID partition table (`internal/diskimg`)

**Files:**
- Create: `internal/diskimg/guid.go`, `internal/diskimg/gpt.go`, `internal/diskimg/gpt_test.go`

**Interfaces:**
- Produces:
  - `const SectorSize = 512`, `AlignLBA = 2048`, `FirstUsableLBA = 34`
  - `type GUID [16]byte`, in on-disk byte order, with:
    - `ParseGUID(s string) (GUID, error)`
    - `MustGUID(s string) GUID`
    - `(GUID) String() string`
    - `DerivedGUID(seed string) GUID`
  - `TypeEFISystem`, `TypeAppleHFS`
  - `type Partition struct{ Type, GUID GUID; Name string; FirstLBA, LastLBA uint64 }`
  - `LastUsableLBA(sectors uint64) uint64`
  - `WriteGPT(w io.WriterAt, sectors uint64, disk GUID, parts []Partition) error`
  - `ReadGPT(r io.ReaderAt, sectors uint64) (disk GUID, parts []Partition, err error)`

  Phase 4's media builder will use `TypeAppleHFS` to replace
  `lib/hfs.sh`'s sgdisk call.

- [ ] **Step 1: Write the failing tests**

`internal/diskimg/gpt_test.go`:

```go
package diskimg

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const mib192 = 192 * 1024 * 1024 / SectorSize // 393216 sectors

func espOn(sectors uint64) []Partition {
	return []Partition{{Type: TypeEFISystem, GUID: DerivedGUID("test esp"), Name: "EFI",
		FirstLBA: AlignLBA, LastLBA: LastUsableLBA(sectors)}}
}

// image is an in-memory disk of n sectors.
type image []byte

func (m image) WriteAt(p []byte, off int64) (int, error) { return copy(m[off:], p), nil }
func (m image) ReadAt(p []byte, off int64) (int, error)  { return copy(p, m[off:]), nil }

func TestGUIDTextRoundTrips(t *testing.T) {
	g := MustGUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
	if g.String() != "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" {
		t.Fatal(g.String())
	}
	// On disk, the first three fields are little-endian.
	if !bytes.Equal(g[:8], []byte{0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11}) {
		t.Fatalf("% X", g[:8])
	}
	if _, err := ParseGUID("C12A7328F81F11D2BA4B00A0C93EC93B"); err == nil {
		t.Fatal("a GUID without dashes must be refused")
	}
}

func TestDerivedGUIDsAreStableAndVersion4(t *testing.T) {
	a, b := DerivedGUID("opencore esp"), DerivedGUID("opencore esp")
	if a != b || a == DerivedGUID("opencore disk") {
		t.Fatal("same seed, same GUID; different seed, different GUID")
	}
	s := a.String()
	if s[14] != '4' || !strings.ContainsRune("89AB", rune(s[19])) {
		t.Fatalf("not version 4 / RFC 4122 variant: %s", s)
	}
}

func TestLastUsableLBAIsSgdisksEnd(t *testing.T) {
	if got := LastUsableLBA(mib192); got != 393182 {
		t.Fatalf("got %d, sgdisk --new=1:2048:0 ends at 393182", got)
	}
}

func TestGPTRoundTrip(t *testing.T) {
	img := make(image, mib192*SectorSize)
	disk := DerivedGUID("test disk")
	if err := WriteGPT(img, mib192, disk, espOn(mib192)); err != nil {
		t.Fatal(err)
	}
	gotDisk, parts, err := ReadGPT(img, mib192)
	if err != nil {
		t.Fatal(err)
	}
	if gotDisk != disk || len(parts) != 1 || parts[0] != espOn(mib192)[0] {
		t.Fatalf("%v %+v", gotDisk, parts)
	}
	if img[510] != 0x55 || img[511] != 0xAA || img[450] != 0xEE {
		t.Fatal("no protective MBR")
	}
}

func TestReadGPTRefusesACorruptTable(t *testing.T) {
	img := make(image, mib192*SectorSize)
	if err := WriteGPT(img, mib192, DerivedGUID("d"), espOn(mib192)); err != nil {
		t.Fatal(err)
	}
	img[2*SectorSize+100] ^= 0xFF // inside the primary partition entries
	if _, _, err := ReadGPT(img, mib192); err == nil || !strings.Contains(err.Error(), "CRC") {
		t.Fatalf("err = %v", err)
	}
}

func TestWriteGPTRefusesPartitionsThatDoNotFit(t *testing.T) {
	img := make(image, mib192*SectorSize)
	for name, p := range map[string]Partition{
		"before the first usable LBA": {Type: TypeEFISystem, FirstLBA: 33, LastLBA: 100},
		"past the last usable LBA":    {Type: TypeEFISystem, FirstLBA: AlignLBA, LastLBA: LastUsableLBA(mib192) + 1},
		"ending before it starts":     {Type: TypeEFISystem, FirstLBA: 5000, LastLBA: 4000},
		"with a name too long":        {Type: TypeEFISystem, FirstLBA: AlignLBA, LastLBA: 4000, Name: strings.Repeat("x", 37)},
	} {
		if err := WriteGPT(img, mib192, DerivedGUID("d"), []Partition{p}); err == nil {
			t.Errorf("a partition %s must be refused", name)
		}
	}
	overlap := []Partition{
		{Type: TypeEFISystem, FirstLBA: AlignLBA, LastLBA: 10000},
		{Type: TypeAppleHFS, FirstLBA: 9000, LastLBA: 20000},
	}
	if err := WriteGPT(img, mib192, DerivedGUID("d"), overlap); err == nil {
		t.Error("overlapping partitions must be refused")
	}
}

// sgdisk is the reference: it must find nothing wrong with Go's table,
// and must read back the partition Go wrote, where sgdisk would have put
// it. And Go must read sgdisk's own table.
func TestGPTMatchesSgdisk(t *testing.T) {
	for _, tool := range []string{"sgdisk", "truncate"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip(tool + " not installed")
		}
	}
	dir := t.TempDir()
	goImg := filepath.Join(dir, "go.img")
	f, err := os.Create(goImg)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(mib192 * SectorSize); err != nil {
		t.Fatal(err)
	}
	if err := WriteGPT(f, mib192, DerivedGUID("d"), espOn(mib192)); err != nil {
		t.Fatal(err)
	}
	f.Close()
	out, err := exec.Command("sgdisk", "-v", goImg).CombinedOutput()
	if err != nil || !strings.Contains(string(out), "No problems found") {
		t.Fatalf("sgdisk -v: %v\n%s", err, out)
	}
	info, _ := exec.Command("sgdisk", "-i", "1", goImg).CombinedOutput()
	for _, want := range []string{"First sector: 2048", "Last sector: 393182", "EFI system partition", "Partition name: 'EFI'"} {
		if !strings.Contains(string(info), want) {
			t.Errorf("sgdisk -i 1 lacks %q:\n%s", want, info)
		}
	}

	shImg := filepath.Join(dir, "sh.img")
	if out, err := exec.Command("truncate", "-s", "192M", shImg).CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	if out, err := exec.Command("sgdisk", "--clear", "--new=1:2048:0", "--typecode=1:EF00",
		"--change-name=1:EFI", shImg).CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	sf, err := os.Open(shImg)
	if err != nil {
		t.Fatal(err)
	}
	defer sf.Close()
	_, parts, err := ReadGPT(sf, mib192)
	if err != nil {
		t.Fatal(err)
	}
	p := parts[0]
	if len(parts) != 1 || p.Type != TypeEFISystem || p.FirstLBA != 2048 || p.LastLBA != 393182 || p.Name != "EFI" {
		t.Fatalf("read sgdisk's table as %+v", parts)
	}
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/diskimg/ 2>&1 | head`
Expected: the package does not exist.

- [ ] **Step 3: Implement**

`internal/diskimg/guid.go`:

```go
// Package diskimg writes and reads the disk images vmavs builds -- a GUID
// partition table and a FAT32 filesystem -- as plain files: no loop
// devices, no root, no sgdisk, no mtools. It knows file formats and
// nothing about what goes in them.
//
// Everything it writes is deterministic: the same inputs give the same
// bytes, which the shell tree's images (sgdisk's random GUIDs, mtools'
// random serial and current timestamps) never were.
package diskimg

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// SectorSize is the only sector size these images use.
const SectorSize = 512

// A GUID in its on-disk byte order: the first three fields
// little-endian, the last two as written.
type GUID [16]byte

// The partition types vmavs writes.
var (
	TypeEFISystem = MustGUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")
	TypeAppleHFS  = MustGUID("48465300-0000-11AA-AA11-00306543ECAC")
)

// ParseGUID reads the textual form, 8-4-4-4-12 hex digits.
func ParseGUID(s string) (GUID, error) {
	var g GUID
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return g, fmt.Errorf("not a GUID: %q", s)
	}
	var b [16]byte
	if _, err := hex.Decode(b[:], []byte(s[0:8]+s[9:13]+s[14:18]+s[19:23]+s[24:36])); err != nil {
		return g, fmt.Errorf("not a GUID: %q", s)
	}
	return fromText(b), nil
}

// MustGUID is ParseGUID for constants.
func MustGUID(s string) GUID {
	g, err := ParseGUID(s)
	if err != nil {
		panic(err)
	}
	return g
}

// fromText swaps the first three fields between textual (big-endian)
// and on-disk (little-endian) order. It is its own inverse.
func fromText(b [16]byte) GUID {
	return GUID{b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6],
		b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]}
}

func (g GUID) String() string {
	t := fromText(g)
	h := fmt.Sprintf("%X", t[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// DerivedGUID is a GUID taken from a hash of seed, shaped as a version-4
// (random) GUID: stable across builds, which random GUIDs are not.
func DerivedGUID(seed string) GUID {
	sum := sha256.Sum256([]byte("vmavs diskimg " + seed))
	var b [16]byte
	copy(b[:], sum[:16])
	b[6] = b[6]&0x0f | 0x40 // version 4
	b[8] = b[8]&0x3f | 0x80 // RFC 4122 variant
	return fromText(b)
}
```

`internal/diskimg/gpt.go`:

```go
package diskimg

import (
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"sort"
	"unicode/utf16"
)

const (
	gptEntries      = 128
	gptEntrySize    = 128
	gptEntrySectors = gptEntries * gptEntrySize / SectorSize // 32
	gptHeaderSize   = 92

	// FirstUsableLBA follows the protective MBR (0), the header (1) and
	// the partition entries (2-33).
	FirstUsableLBA = 2 + gptEntrySectors
	// AlignLBA is where a first partition starts: 1 MiB, as sgdisk and
	// every current tool align it.
	AlignLBA = 2048
)

// A Partition is one GPT entry. LastLBA is inclusive; Name is at most 36
// UTF-16 code units.
type Partition struct {
	Type, GUID        GUID
	Name              string
	FirstLBA, LastLBA uint64
}

// LastUsableLBA is the last sector a partition may use on a disk of
// sectors sectors: the backup entries and header follow it.
func LastUsableLBA(sectors uint64) uint64 { return sectors - 2 - gptEntrySectors }

// WriteGPT writes a protective MBR, the primary GPT header and entries,
// and the backup entries and header, to a disk of sectors sectors. It
// writes nothing else: w is expected to be zero elsewhere (a fresh,
// truncated file).
func WriteGPT(w io.WriterAt, sectors uint64, disk GUID, parts []Partition) error {
	if sectors < AlignLBA+FirstUsableLBA {
		return fmt.Errorf("a disk of %d sectors is too small for a GPT", sectors)
	}
	if len(parts) > gptEntries {
		return fmt.Errorf("%d partitions; a GPT holds %d", len(parts), gptEntries)
	}
	sorted := append([]Partition(nil), parts...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].FirstLBA < sorted[j].FirstLBA })
	for i, p := range sorted {
		switch {
		case p.FirstLBA < FirstUsableLBA:
			return fmt.Errorf("partition %q starts at LBA %d, before the first usable LBA %d", p.Name, p.FirstLBA, FirstUsableLBA)
		case p.LastLBA > LastUsableLBA(sectors):
			return fmt.Errorf("partition %q ends at LBA %d, past the last usable LBA %d", p.Name, p.LastLBA, LastUsableLBA(sectors))
		case p.LastLBA < p.FirstLBA:
			return fmt.Errorf("partition %q ends (LBA %d) before it starts (LBA %d)", p.Name, p.LastLBA, p.FirstLBA)
		case len(utf16.Encode([]rune(p.Name))) > 36:
			return fmt.Errorf("partition name %q is longer than 36 UTF-16 units", p.Name)
		case i > 0 && p.FirstLBA <= sorted[i-1].LastLBA:
			return fmt.Errorf("partitions %q and %q overlap", sorted[i-1].Name, p.Name)
		}
	}

	entries := make([]byte, gptEntries*gptEntrySize)
	for i, p := range parts {
		e := entries[i*gptEntrySize:]
		copy(e[0:16], p.Type[:])
		copy(e[16:32], p.GUID[:])
		binary.LittleEndian.PutUint64(e[32:], p.FirstLBA)
		binary.LittleEndian.PutUint64(e[40:], p.LastLBA)
		// e[48:56] attributes: none
		for j, u := range utf16.Encode([]rune(p.Name)) {
			binary.LittleEndian.PutUint16(e[56+2*j:], u)
		}
	}
	entriesCRC := crc32.ChecksumIEEE(entries)
	last := sectors - 1
	backupEntries := last - gptEntrySectors

	header := func(my, alt, entriesLBA uint64) []byte {
		h := make([]byte, SectorSize)
		copy(h[0:8], "EFI PART")
		binary.LittleEndian.PutUint32(h[8:], 0x00010000)
		binary.LittleEndian.PutUint32(h[12:], gptHeaderSize)
		binary.LittleEndian.PutUint64(h[24:], my)
		binary.LittleEndian.PutUint64(h[32:], alt)
		binary.LittleEndian.PutUint64(h[40:], FirstUsableLBA)
		binary.LittleEndian.PutUint64(h[48:], LastUsableLBA(sectors))
		copy(h[56:72], disk[:])
		binary.LittleEndian.PutUint64(h[72:], entriesLBA)
		binary.LittleEndian.PutUint32(h[80:], gptEntries)
		binary.LittleEndian.PutUint32(h[84:], gptEntrySize)
		binary.LittleEndian.PutUint32(h[88:], entriesCRC)
		binary.LittleEndian.PutUint32(h[16:], crc32.ChecksumIEEE(h[:gptHeaderSize]))
		return h
	}

	mbr := make([]byte, SectorSize)
	pe := mbr[446:]
	pe[1], pe[2], pe[3] = 0x00, 0x02, 0x00 // CHS of LBA 1
	pe[4] = 0xEE                           // GPT protective
	pe[5], pe[6], pe[7] = 0xFF, 0xFF, 0xFF // CHS "beyond"
	binary.LittleEndian.PutUint32(pe[8:], 1)
	size := sectors - 1
	if size > 0xFFFFFFFF {
		size = 0xFFFFFFFF
	}
	binary.LittleEndian.PutUint32(pe[12:], uint32(size))
	mbr[510], mbr[511] = 0x55, 0xAA

	for _, wr := range []struct {
		lba  uint64
		data []byte
	}{
		{0, mbr},
		{1, header(1, last, 2)},
		{2, entries},
		{backupEntries, entries},
		{last, header(last, 1, backupEntries)},
	} {
		if _, err := w.WriteAt(wr.data, int64(wr.lba)*SectorSize); err != nil {
			return err
		}
	}
	return nil
}

// ReadGPT reads a disk's primary GPT, checking both CRCs, and returns its
// disk GUID and non-empty partitions in table order.
func ReadGPT(r io.ReaderAt, sectors uint64) (GUID, []Partition, error) {
	var disk GUID
	h := make([]byte, SectorSize)
	if _, err := r.ReadAt(h, SectorSize); err != nil {
		return disk, nil, err
	}
	if string(h[0:8]) != "EFI PART" {
		return disk, nil, errors.New("no GPT header at LBA 1")
	}
	hsize := binary.LittleEndian.Uint32(h[12:])
	if hsize < gptHeaderSize || hsize > SectorSize {
		return disk, nil, fmt.Errorf("GPT header size %d", hsize)
	}
	want := binary.LittleEndian.Uint32(h[16:])
	c := append([]byte(nil), h[:hsize]...)
	binary.LittleEndian.PutUint32(c[16:], 0)
	if crc32.ChecksumIEEE(c) != want {
		return disk, nil, errors.New("GPT header CRC mismatch")
	}
	copy(disk[:], h[56:72])
	lba := binary.LittleEndian.Uint64(h[72:])
	n := binary.LittleEndian.Uint32(h[80:])
	esz := binary.LittleEndian.Uint32(h[84:])
	if esz < gptEntrySize || n == 0 || uint64(n)*uint64(esz) > 1<<20 || lba >= sectors {
		return disk, nil, fmt.Errorf("implausible GPT entry array: %d entries of %d bytes at LBA %d", n, esz, lba)
	}
	entries := make([]byte, int(n)*int(esz))
	if _, err := r.ReadAt(entries, int64(lba)*SectorSize); err != nil {
		return disk, nil, err
	}
	if crc32.ChecksumIEEE(entries) != binary.LittleEndian.Uint32(h[88:]) {
		return disk, nil, errors.New("GPT partition entries CRC mismatch")
	}
	var parts []Partition
	for i := 0; i < int(n); i++ {
		e := entries[i*int(esz):]
		var p Partition
		copy(p.Type[:], e[0:16])
		if p.Type == (GUID{}) {
			continue
		}
		copy(p.GUID[:], e[16:32])
		p.FirstLBA = binary.LittleEndian.Uint64(e[32:])
		p.LastLBA = binary.LittleEndian.Uint64(e[40:])
		var u []uint16
		for j := 0; j < 36; j++ {
			c := binary.LittleEndian.Uint16(e[56+2*j:])
			if c == 0 {
				break
			}
			u = append(u, c)
		}
		p.Name = string(utf16.Decode(u))
		parts = append(parts, p)
	}
	return disk, parts, nil
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/diskimg/ -v 2>&1 | tail -20`
Expected: PASS, with `TestGPTMatchesSgdisk` running here, because
sgdisk is installed.

- [ ] **Step 5: Commit**

```bash
git add internal/diskimg
git commit   # subject: "diskimg: a deterministic GPT writer and reader that sgdisk agrees with"
```

---

### Task 8: FAT32 (`internal/diskimg`)

**Files:**
- Create: `internal/diskimg/fat.go`, `internal/diskimg/fatname.go`, `internal/diskimg/fatread.go`
- Create: `internal/diskimg/fat_test.go` (pure Go) and `internal/diskimg/parity_test.go` (runs against mtools, sgdisk and fsck.fat)

**Interfaces:**
- Consumes: `SectorSize`, `WriteGPT`, `ReadGPT`, `LastUsableLBA`, `AlignLBA`, `TypeEFISystem`, `DerivedGUID`, from Task 7.
- Produces:
  - `type Geometry struct{ Sectors, SectorsPerCluster, ReservedSectors, FATs, FATSectors, Clusters, HiddenSectors uint32 }`
  - `FAT32Geometry(sectors, hidden uint32) (Geometry, error)`
  - `type FAT struct`, with:
    - `NewFAT(label string, serial uint32) (*FAT, error)`
    - `(*FAT).Mkdir(path string) error`
    - `(*FAT).WriteFile(path string, data []byte) error`
    - `(*FAT).WriteTo(w io.WriterAt, off int64, g Geometry) error`
  - `type DirEntry struct{ Name, Short string; Dir bool; Size, Cluster uint32 }`
  - `type FATReader struct{ G Geometry; Label, OEM string; Serial uint32; … }`, with:
    - `OpenFAT(r io.ReaderAt, off int64) (*FATReader, error)`
    - `(*FATReader).ReadDir(path string) ([]DirEntry, error)`
    - `(*FATReader).ReadFile(path string) ([]byte, error)`
    - `(*FATReader).Walk(fn func(path string, e DirEntry) error) error`

  Paths are slash-separated from the root, as in `/EFI/OC/OpenCore.efi`,
  and matched case-insensitively, as FAT names are.

- [ ] **Step 1: Write the failing tests**

`internal/diskimg/fat_test.go`:

```go
package diskimg

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// The geometry table MEASURED against mformat (mtools 4.0.43) on
// 2026-09-25, through lib/efi.sh: filesystem sectors -> sectors per
// cluster, FAT sectors. parity_test.go re-measures it live.
var mformatGeometry = []struct{ sectors, spc, fatSectors uint32 }{
	{79839, 1, 614}, {96223, 1, 740}, {128991, 1, 993}, {202719, 2, 786},
	{391135, 4, 761}, {612319, 8, 597}, {1046495, 8, 1020},
	{2095071, 8, 2042}, {4192223, 8, 4086},
}

func TestGeometryIsMformats(t *testing.T) {
	for _, m := range mformatGeometry {
		g, err := FAT32Geometry(m.sectors, AlignLBA)
		if err != nil {
			t.Fatal(err)
		}
		if g.SectorsPerCluster != m.spc || g.FATSectors != m.fatSectors || g.ReservedSectors != 32 || g.FATs != 2 {
			t.Errorf("%d sectors: got %+v, mformat chose %d/cluster and %d FAT sectors", m.sectors, g, m.spc, m.fatSectors)
		}
	}
}

func TestFAT32GeometryRefusesATinyFilesystem(t *testing.T) {
	if _, err := FAT32Geometry(20*2048, AlignLBA); err == nil || !strings.Contains(err.Error(), "65525") {
		t.Fatalf("err = %v", err)
	}
}

// build writes f into a fresh in-memory filesystem of mib MiB (the whole
// buffer is the filesystem, as a partition is) and opens it for reading.
func build(t *testing.T, f *FAT, mib uint32) (image, *FATReader) {
	t.Helper()
	sectors := mib * 2048
	g, err := FAT32Geometry(sectors, 0)
	if err != nil {
		t.Fatal(err)
	}
	img := make(image, int(sectors)*SectorSize)
	if err := f.WriteTo(img, 0, g); err != nil {
		t.Fatal(err)
	}
	r, err := OpenFAT(img, 0)
	if err != nil {
		t.Fatal(err)
	}
	return img, r
}

func mustFAT(t *testing.T) *FAT {
	t.Helper()
	f, err := NewFAT("EFI", 0x5641564D)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func TestFATRoundTrip(t *testing.T) {
	f := mustFAT(t)
	big := bytes.Repeat([]byte("0123456789abcdef"), 1000) // several clusters
	for _, step := range []error{
		f.Mkdir("/EFI"), f.Mkdir("/EFI/OC"), f.Mkdir("/EFI/BOOT"),
		f.WriteFile("/EFI/BOOT/BOOTx64.efi", []byte("boot")),
		f.WriteFile("/EFI/OC/OpenCore.efi", big),
		f.WriteFile("/EFI/OC/empty", nil),
	} {
		if step != nil {
			t.Fatal(step)
		}
	}
	_, r := build(t, f, 48)
	if r.Label != "EFI" || r.Serial != 0x5641564D || r.OEM != "MSWIN4.1" {
		t.Fatalf("label %q serial %x oem %q", r.Label, r.Serial, r.OEM)
	}
	if b, err := r.ReadFile("/EFI/OC/OpenCore.efi"); err != nil || !bytes.Equal(b, big) {
		t.Fatalf("OpenCore.efi: %v", err)
	}
	if b, err := r.ReadFile("/efi/boot/bootx64.EFI"); err != nil || string(b) != "boot" {
		t.Fatalf("names must match case-insensitively: %q %v", b, err)
	}
	if b, err := r.ReadFile("/EFI/OC/empty"); err != nil || len(b) != 0 {
		t.Fatalf("empty: %q %v", b, err)
	}
	es, err := r.ReadDir("/EFI")
	if err != nil || len(es) != 2 || es[0].Name != "OC" || es[1].Name != "BOOT" || !es[0].Dir {
		t.Fatalf("ReadDir keeps the order things were added in: %+v %v", es, err)
	}
}

func TestFATNestedDirectoriesAndLongDirectories(t *testing.T) {
	f := mustFAT(t)
	for _, d := range []string{"/a", "/a/b", "/a/b/c", "/a/b/c/Contents"} {
		if err := f.Mkdir(d); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.WriteFile("/a/b/c/Contents/Info.plist", []byte("plist")); err != nil {
		t.Fatal(err)
	}
	// 300 long names: many more entries than one 512-byte cluster holds.
	for i := 0; i < 300; i++ {
		if err := f.WriteFile(fmt.Sprintf("/a/A long file name number %03d.txt", i), []byte(fmt.Sprint(i))); err != nil {
			t.Fatal(err)
		}
	}
	_, r := build(t, f, 40) // 1 sector per cluster: the directory spans many
	if b, err := r.ReadFile("/a/b/c/Contents/Info.plist"); err != nil || string(b) != "plist" {
		t.Fatal(err)
	}
	for _, i := range []int{0, 150, 299} {
		b, err := r.ReadFile(fmt.Sprintf("/a/A long file name number %03d.txt", i))
		if err != nil || string(b) != fmt.Sprint(i) {
			t.Fatalf("%d: %q %v", i, b, err)
		}
	}
	var n int
	if err := r.Walk(func(string, DirEntry) error { n++; return nil }); err != nil || n != 305 {
		t.Fatalf("walked %d entries, err %v", n, err)
	}
}

func TestShortNames(t *testing.T) {
	cases := []struct {
		name, short string
		lfn         bool
	}{
		{"EFI", "EFI        ", false},
		{"ACPI", "ACPI       ", false},
		{"BOOTx64.efi", "BOOTX64 EFI", true},
		{"OpenCore.efi", "OPENCOREEFI", true},
		{"OpenRuntime.efi", "OPENRU~1EFI", true},
		{"config.plist", "CONFIG~1PLI", true},
		{"Info.plist", "INFO~1  PLI", true},
		{"Lilu.kext", "LILU~1  KEX", true},
		{"Resources", "RESOUR~1   ", true},
		{"a+b.txt", "A_B~1   TXT", true},
		{".hidden", "HIDDEN~1   ", true},
	}
	for _, c := range cases {
		s, lfn, err := shortName(c.name, map[[11]byte]bool{})
		if err != nil || string(s[:]) != c.short || lfn != c.lfn {
			t.Errorf("%q: got %q lfn=%v err=%v, want %q lfn=%v", c.name, s, lfn, err, c.short, c.lfn)
		}
	}
	taken := map[[11]byte]bool{}
	var got []string
	for _, n := range []string{"OpenRuntime.efi", "OpenRuntime2.efi", "OpenRuntimeX.efi"} {
		s, _, _ := shortName(n, taken)
		taken[s] = true
		got = append(got, string(s[:]))
	}
	if strings.Join(got, ",") != "OPENRU~1EFI,OPENRU~2EFI,OPENRU~3EFI" {
		t.Fatalf("collisions: %v", got)
	}
	for i := 1; i <= 9; i++ {
		taken[pack83(fmt.Sprintf("ABCDEF~%d", i), "")] = true
	}
	if s, _, _ := shortName("abcdefghij", taken); string(s[:]) != "ABCDE~10   " {
		t.Fatalf("a two-digit tail shortens the basis: %q", s)
	}
}

func TestLFNChecksumKnownAnswers(t *testing.T) {
	for short, want := range map[string]byte{"OPENRU~1EFI": 0x84, "CONFIG~1PLI": 0xEF, "BOOTX64 EFI": 0x1D} {
		var s [11]byte
		copy(s[:], short)
		if got := lfnChecksum(s); got != want {
			t.Errorf("%s: %#x, want %#x", short, got, want)
		}
	}
}

func TestFATRefusesWhatItCannotHold(t *testing.T) {
	f := mustFAT(t)
	if err := f.Mkdir("/EFI"); err != nil {
		t.Fatal(err)
	}
	for name, err := range map[string]error{
		"a duplicate":                  f.Mkdir("/EFI"),
		"a duplicate but for its case": f.Mkdir("/efi"),
		"a missing parent":             f.WriteFile("/nope/x", nil),
		"a file as a parent":           func() error { f.WriteFile("/f", nil); return f.WriteFile("/f/x", nil) }(),
		"a colon":                      f.WriteFile("/a:b", nil),
		"a star":                       f.WriteFile("/a*", nil),
		"a trailing dot":               f.WriteFile("/trailing.", nil),
		"a control character":          f.WriteFile("/x\x01", nil),
		"dot-dot":                      f.Mkdir("/EFI/.."),
	} {
		if err == nil {
			t.Errorf("%s must be refused", name)
		}
	}
	if _, err := NewFAT("A LABEL TOO LONG", 0); err == nil {
		t.Error("a label over 11 characters must be refused")
	}
}

func TestFATRefusesWhatDoesNotFit(t *testing.T) {
	f := mustFAT(t)
	if err := f.WriteFile("/big", make([]byte, 45<<20)); err != nil {
		t.Fatal(err)
	}
	g, _ := FAT32Geometry(40*2048, 0)
	err := f.WriteTo(make(image, 40<<20), 0, g)
	if err == nil || !strings.Contains(err.Error(), "clusters") {
		t.Fatalf("err = %v", err)
	}
}

func TestFATIsDeterministic(t *testing.T) {
	make1 := func() image {
		f := mustFAT(t)
		f.Mkdir("/EFI")
		f.WriteFile("/EFI/config.plist", []byte("<plist/>"))
		img, _ := build(t, f, 40)
		return img
	}
	if !bytes.Equal(make1(), make1()) {
		t.Fatal("the same calls must give the same bytes")
	}
}

// The filesystem must stay inside its partition, off the backup GPT at
// the end of the disk: mtools needed -T to promise that (lib/efi.sh);
// here the promise is that WriteTo writes nothing past g.Sectors.
func TestFATStaysInsideItsPartition(t *testing.T) {
	const sectors = 40 * 2048
	g, err := FAT32Geometry(sectors, 0)
	if err != nil {
		t.Fatal(err)
	}
	if end := g.ReservedSectors + g.FATs*g.FATSectors + g.Clusters*g.SectorsPerCluster; end > sectors {
		t.Fatalf("the layout ends at sector %d of %d", end, sectors)
	}
	img := make(image, sectors*SectorSize+4096)
	for i := sectors * SectorSize; i < len(img); i++ {
		img[i] = 0xAB
	}
	f := mustFAT(t)
	f.WriteFile("/fill", make([]byte, 30<<20))
	if err := f.WriteTo(img, 0, g); err != nil {
		t.Fatal(err)
	}
	for i := sectors * SectorSize; i < len(img); i++ {
		if img[i] != 0xAB {
			t.Fatalf("byte %d past the filesystem was written", i)
		}
	}
}
```

`internal/diskimg/parity_test.go`. Tools are checked with `LookPath`.
The shell helpers run `lib/efi.sh` from the repository root, located as
in `firmware`'s tests (`runtime.Caller`).

1. **`TestGeometryMatchesMformatLive`.** Skip unless on Linux with
   `bash`, `sgdisk`, `mformat`, `minfo` and `truncate` present. For each
   of 40, 48, 64, 100, 192, 300 and 512 MiB:
   1. Run `bash -c '. lib/common.sh; . lib/efi.sh; efi_image_create IMG N'`.
   2. Read the partition's size with `ReadGPT`.
   3. Open the filesystem with `OpenFAT(img, 2048*512)`.
   4. Assert that `SectorsPerCluster`, `ReservedSectors`, `FATs`,
      `FATSectors`, `Clusters` and `Sectors` equal
      `FAT32Geometry(partSectors, …)`'s, and that `Sectors` equals the
      partition's size.

   `HiddenSectors` is not compared: mformat writes 0 and Go writes the
   partition's LBA, Ruling 5. The comment says so.
2. **`TestFsckAcceptsTheGoFilesystem`.** Skip without `fsck.fat`.
   - Build a 48 MiB filesystem in memory with:
     - the tree from `TestFATNestedDirectoriesAndLongDirectories`;
     - three `OpenRuntime*.efi` names that collide at `~1`;
     - an empty file;
     - a 100 KiB file.
   - Write it to a temp file.
   - `fsck.fat -n -v <file>` must exit 0, and its output must not
     contain `differ` or `Bad`.
3. **`TestMtoolsReadsTheGoImage`.** Skip without `mdir` or `mcopy`.
   1. Make a full 192 MiB image in a temp file:
      `Truncate` → `WriteGPT` (one ESP from `AlignLBA` to
      `LastUsableLBA`) → `FAT32Geometry(part, AlignLBA)` →
      `WriteTo(f, AlignLBA*SectorSize, g)`. It holds
      `/EFI/OC/Drivers/OpenRuntime.efi`, `/EFI/OC/config.plist` and
      `/EFI/OC/Kexts/Lilu.kext/Contents/MacOS/Lilu`.
   2. With `MTOOLS_SKIP_CHECK=1` in the environment, run
      `mdir -b -/ -i IMG@@1048576 ::`. It lists each path with its long
      name: `::/EFI/OC/config.plist` and the others.
   3. `mcopy -n -i IMG@@1048576 ::/EFI/OC/config.plist OUT` gives the
      same bytes.
   4. `sgdisk -v IMG` says `No problems found`.
4. **`TestGoReadsAnMtoolsImage`.** Skip unless on Linux with `bash`,
   `sgdisk` and mtools present.
   1. In a temp dir, run
      `efi_image_create img 48; efi_mkdir img ::/EFI; efi_copy_in img <file> ::/EFI/OpenPartitionDxe.efi; efi_copy_tree img <bundle dir> ::/EFI/Lilu.kext`.
      The bundle is `Contents/Info.plist` and `Contents/MacOS/Lilu`.
   2. `OpenFAT(img, 2048*512)` reads every file back byte-for-byte.
   3. `Walk` visits exactly those paths, as long names.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/diskimg/ 2>&1 | head`
Expected: undefined `FAT32Geometry`, `NewFAT`, `shortName`, …

- [ ] **Step 3: Implement**

`internal/diskimg/fat.go`:

```go
package diskimg

import (
	"encoding/binary"
	"fmt"
	"io"
	"strings"
)

// Geometry is a FAT32 filesystem's layout, in sectors unless named
// otherwise.
type Geometry struct {
	Sectors           uint32 // the whole filesystem: its partition
	SectorsPerCluster uint32
	ReservedSectors   uint32
	FATs              uint32
	FATSectors        uint32 // each FAT's
	Clusters          uint32
	HiddenSectors     uint32 // before the filesystem on its disk: the partition's LBA
}

const (
	fatReserved      = 32
	fatCopies        = 2
	fat32MinClusters = 65525
	rootCluster      = 2
	fsInfoSector     = 1
	backupBootSector = 6
	fatEOC           = 0x0FFFFFFF
	dirEntrySize     = 32
	attrDir          = 0x10
	attrArchive      = 0x20
	attrVolumeID     = 0x08
	attrLFN          = 0x0F
	// fatDate is 1980-01-01, the FAT epoch, and every timestamp this
	// package writes: so the same files give the same bytes.
	fatDate = 1<<5 | 1
)

// FAT32Geometry lays out a FAT32 filesystem of sectors sectors the way
// mformat -F does -- MEASURED against mtools 4.0.43 from 40 MiB to 2 GiB,
// and held there by the parity test: 32 reserved sectors and two FATs;
// the largest cluster of 8, 4, 2 or 1 sectors that still leaves the
// 65525 clusters FAT32 needs; the smallest FAT that maps every cluster.
func FAT32Geometry(sectors, hidden uint32) (Geometry, error) {
	for _, spc := range []uint32{8, 4, 2, 1} {
		for fatSectors := uint32(1); fatReserved+fatCopies*fatSectors < sectors; fatSectors++ {
			clusters := (sectors - fatReserved - fatCopies*fatSectors) / spc
			if uint64(clusters+2)*4 > uint64(fatSectors)*SectorSize {
				continue // this FAT is too small to map them; try a larger one
			}
			if clusters < fat32MinClusters {
				break // too few clusters at this size: try a smaller cluster
			}
			return Geometry{Sectors: sectors, SectorsPerCluster: spc, ReservedSectors: fatReserved,
				FATs: fatCopies, FATSectors: fatSectors, Clusters: clusters, HiddenSectors: hidden}, nil
		}
	}
	return Geometry{}, fmt.Errorf("%d sectors is too small for FAT32, which needs at least %d clusters", sectors, fat32MinClusters)
}

func (g Geometry) clusterBytes() uint32 { return g.SectorsPerCluster * SectorSize }

// clusterOffset is cluster c's byte offset within the filesystem.
func (g Geometry) clusterOffset(c uint32) int64 {
	return int64(g.ReservedSectors+g.FATs*g.FATSectors+(c-2)*g.SectorsPerCluster) * SectorSize
}

// A FAT is a FAT32 filesystem put together in memory and written in one
// pass by WriteTo. Entries keep the order they were added in, and so does
// the layout, so the same calls give the same bytes.
type FAT struct {
	label  [11]byte
	serial uint32
	root   *fnode
}

type fnode struct {
	name     string
	dir      bool
	data     []byte
	children []*fnode
	// set by WriteTo
	short  [11]byte
	lfn    bool
	first  uint32
	nclust uint32
	parent *fnode
}

// NewFAT starts an empty filesystem. label is at most 11 characters that
// are valid in a short name; it is stored upper-case.
func NewFAT(label string, serial uint32) (*FAT, error) {
	up := strings.ToUpper(label)
	if up == "" || len(up) > 11 {
		return nil, fmt.Errorf("volume label %q: 1 to 11 characters", label)
	}
	for _, c := range up {
		if !validShort(c) && c != ' ' {
			return nil, fmt.Errorf("volume label %q: %q is not allowed", label, c)
		}
	}
	var l [11]byte
	copy(l[:], up+strings.Repeat(" ", 11-len(up)))
	return &FAT{label: l, serial: serial, root: &fnode{dir: true}}, nil
}

// Mkdir adds a directory. Its parent must exist; it must not.
func (f *FAT) Mkdir(path string) error { return f.add(path, &fnode{dir: true}) }

// WriteFile adds a file holding data. Its parent must exist; it must not.
func (f *FAT) WriteFile(path string, data []byte) error {
	return f.add(path, &fnode{data: append([]byte(nil), data...)})
}

func (f *FAT) add(path string, n *fnode) error {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	dir := f.root
	for i, p := range parts {
		if err := checkLongName(p); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		var found *fnode
		for _, c := range dir.children {
			if strings.EqualFold(c.name, p) {
				found = c
			}
		}
		if i == len(parts)-1 {
			if found != nil {
				return fmt.Errorf("%s already exists", path)
			}
			n.name = p
			dir.children = append(dir.children, n)
			return nil
		}
		if found == nil || !found.dir {
			return fmt.Errorf("%s: %s is not a directory", path, "/"+strings.Join(parts[:i+1], "/"))
		}
		dir = found
	}
	return nil
}

// entryCount is how many 32-byte entries dir's directory holds.
func (n *fnode) entryCount() uint32 {
	c := uint32(2) // "." and ".."; the root's volume label, and one entry spare
	for _, ch := range n.children {
		c++
		if ch.lfn {
			c += lfnCount(ch.name)
		}
	}
	return c
}

// WriteTo writes the filesystem at byte offset off of w, laid out by g
// (from FAT32Geometry). It writes the boot sectors, both FATs, every
// directory and every file, and nothing outside g.Sectors: w is expected
// to be zero where nothing is written (a fresh, truncated file).
func (f *FAT) WriteTo(w io.WriterAt, off int64, g Geometry) error {
	if err := f.root.assignNames(); err != nil {
		return err
	}
	cb := g.clusterBytes()
	next := uint32(rootCluster)
	alloc := func(n *fnode, bytes uint32) {
		n.nclust = (bytes + cb - 1) / cb
		if n.dir && n.nclust == 0 {
			n.nclust = 1
		}
		if n.nclust > 0 {
			n.first = next
			next += n.nclust
		}
	}
	var place func(d *fnode)
	place = func(d *fnode) {
		for _, c := range d.children {
			c.parent = d
			if c.dir {
				alloc(c, c.entryCount()*dirEntrySize)
				place(c)
			} else {
				alloc(c, uint32(len(c.data)))
			}
		}
	}
	alloc(f.root, f.root.entryCount()*dirEntrySize)
	place(f.root)
	used := next - rootCluster
	if used > g.Clusters {
		return fmt.Errorf("the files need %d clusters; a filesystem of %d sectors has %d", used, g.Sectors, g.Clusters)
	}

	fat := make([]byte, g.FATSectors*SectorSize)
	binary.LittleEndian.PutUint32(fat[0:], 0x0FFFFFF8)
	binary.LittleEndian.PutUint32(fat[4:], fatEOC)
	var chain func(n *fnode)
	chain = func(n *fnode) {
		for i := uint32(0); i < n.nclust; i++ {
			v := uint32(fatEOC)
			if i+1 < n.nclust {
				v = n.first + i + 1
			}
			binary.LittleEndian.PutUint32(fat[(n.first+i)*4:], v)
		}
		for _, c := range n.children {
			chain(c)
		}
	}
	chain(f.root)

	reserved := make([]byte, g.ReservedSectors*SectorSize)
	boot := bootSector(g, f.label, f.serial)
	info := fsInfo(g.Clusters-used, next)
	copy(reserved[0:], boot)
	copy(reserved[fsInfoSector*SectorSize:], info)
	copy(reserved[backupBootSector*SectorSize:], boot)
	copy(reserved[(backupBootSector+1)*SectorSize:], info)

	writes := []write{{0, reserved}}
	for i := uint32(0); i < g.FATs; i++ {
		writes = append(writes, write{int64(g.ReservedSectors+i*g.FATSectors) * SectorSize, fat})
	}
	var dirs func(d *fnode)
	dirs = func(d *fnode) {
		writes = append(writes, write{g.clusterOffset(d.first), d.dirBytes(f.label, cb)})
		for _, c := range d.children {
			if c.dir {
				dirs(c)
			} else if c.nclust > 0 {
				buf := make([]byte, c.nclust*cb)
				copy(buf, c.data)
				writes = append(writes, write{g.clusterOffset(c.first), buf})
			}
		}
	}
	dirs(f.root)
	for _, wr := range writes {
		if _, err := w.WriteAt(wr.data, off+wr.at); err != nil {
			return err
		}
	}
	return nil
}

// A write is bytes at an offset within the filesystem.
type write struct {
	at   int64
	data []byte
}

// assignNames gives every entry below n its short name, and says which
// need long-name entries too.
func (n *fnode) assignNames() error {
	taken := map[[11]byte]bool{}
	for _, c := range n.children {
		s, lfn, err := shortName(c.name, taken)
		if err != nil {
			return err
		}
		taken[s] = true
		c.short, c.lfn = s, lfn
		if c.dir {
			if err := c.assignNames(); err != nil {
				return err
			}
		}
	}
	return nil
}

// dirBytes is directory d's clusters: the volume label (root) or "." and
// ".." (anything else), then each child's long-name entries and short
// entry.
func (d *fnode) dirBytes(label [11]byte, cb uint32) []byte {
	buf := make([]byte, 0, d.nclust*cb)
	if d.parent == nil {
		buf = append(buf, dirent(label, attrVolumeID, 0, 0)...)
	} else {
		parent := d.parent.first
		if d.parent.parent == nil {
			parent = 0 // ".." of a top-level directory names the root as 0
		}
		buf = append(buf, dirent(pack83(".", ""), attrDir, d.first, 0)...)
		buf = append(buf, dirent(pack83("..", ""), attrDir, parent, 0)...)
	}
	for _, c := range d.children {
		if c.lfn {
			for _, e := range lfnEntries(c.name, c.short) {
				buf = append(buf, e...)
			}
		}
		attr, size := byte(attrArchive), uint32(len(c.data))
		if c.dir {
			attr, size = attrDir, 0
		}
		buf = append(buf, dirent(c.short, attr, c.first, size)...)
	}
	out := make([]byte, d.nclust*cb)
	copy(out, buf)
	return out
}

// dirent is one 32-byte short directory entry.
func dirent(name [11]byte, attr byte, cluster, size uint32) []byte {
	e := make([]byte, dirEntrySize)
	copy(e[0:11], name[:])
	e[11] = attr
	binary.LittleEndian.PutUint16(e[16:], fatDate) // created
	binary.LittleEndian.PutUint16(e[18:], fatDate) // accessed
	binary.LittleEndian.PutUint16(e[20:], uint16(cluster>>16))
	binary.LittleEndian.PutUint16(e[24:], fatDate) // written
	binary.LittleEndian.PutUint16(e[26:], uint16(cluster))
	binary.LittleEndian.PutUint32(e[28:], size)
	return e
}

func bootSector(g Geometry, label [11]byte, serial uint32) []byte {
	b := make([]byte, SectorSize)
	copy(b[0:3], []byte{0xEB, 0x58, 0x90})
	copy(b[3:11], "MSWIN4.1")
	binary.LittleEndian.PutUint16(b[11:], SectorSize)
	b[13] = byte(g.SectorsPerCluster)
	binary.LittleEndian.PutUint16(b[14:], uint16(g.ReservedSectors))
	b[16] = byte(g.FATs)
	b[21] = 0xF8                              // media: fixed disk
	binary.LittleEndian.PutUint16(b[24:], 63) // sectors per track, as mformat
	binary.LittleEndian.PutUint16(b[26:], 16) // heads, as mformat
	binary.LittleEndian.PutUint32(b[28:], g.HiddenSectors)
	binary.LittleEndian.PutUint32(b[32:], g.Sectors)
	binary.LittleEndian.PutUint32(b[36:], g.FATSectors)
	binary.LittleEndian.PutUint32(b[44:], rootCluster)
	binary.LittleEndian.PutUint16(b[48:], fsInfoSector)
	binary.LittleEndian.PutUint16(b[50:], backupBootSector)
	b[64] = 0x80 // drive number
	b[66] = 0x29 // the next three fields are present
	binary.LittleEndian.PutUint32(b[67:], serial)
	copy(b[71:82], label[:])
	copy(b[82:90], "FAT32   ")
	b[510], b[511] = 0x55, 0xAA
	return b
}

func fsInfo(free, next uint32) []byte {
	b := make([]byte, SectorSize)
	binary.LittleEndian.PutUint32(b[0:], 0x41615252)
	binary.LittleEndian.PutUint32(b[484:], 0x61417272)
	binary.LittleEndian.PutUint32(b[488:], free)
	binary.LittleEndian.PutUint32(b[492:], next)
	binary.LittleEndian.PutUint32(b[508:], 0xAA550000)
	return b
}
```

`internal/diskimg/fatname.go`:

```go
package diskimg

import (
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf16"
)

// shortSpecial is what an 8.3 name may hold besides A-Z and 0-9.
const shortSpecial = "!#$%&'()-@^_`{}~"

func validShort(c rune) bool {
	return c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune(shortSpecial, c)
}

// checkLongName refuses a name FAT cannot hold.
func checkLongName(name string) error {
	switch {
	case name == "", name == ".", name == "..":
		return fmt.Errorf("%q is not a file name", name)
	case strings.ContainsAny(name, `"*/:<>?\|`):
		return fmt.Errorf("%q: FAT names cannot hold any of \"*/:<>?\\|", name)
	case strings.HasSuffix(name, ".") || strings.HasSuffix(name, " "):
		return fmt.Errorf("%q: FAT names cannot end in a dot or a space", name)
	case len(utf16.Encode([]rune(name))) > 255:
		return fmt.Errorf("%q: longer than 255 UTF-16 units", name)
	}
	for _, r := range name {
		if r < 0x20 {
			return fmt.Errorf("%q: FAT names cannot hold control characters", name)
		}
	}
	return nil
}

// pack83 is an 8.3 entry name: base and ext, space-padded.
func pack83(base, ext string) [11]byte {
	var s [11]byte
	copy(s[:], base+strings.Repeat(" ", 8-len(base))+ext+strings.Repeat(" ", 3-len(ext)))
	return s
}

func allShort(s string) bool {
	for _, c := range s {
		if !validShort(c) {
			return false
		}
	}
	return true
}

// shortName is name's 8.3 entry name in a directory whose short names so
// far are taken, and whether name needs long-name entries as well:
//
//   - a valid upper-case 8.3 name is its own short name (EFI, ACPI);
//   - a name that is valid 8.3 but for its case is upper-cased, and keeps
//     its case in a long name (BOOTx64.efi -> BOOTX64 EFI);
//   - anything else gets a basis name -- upper-cased, spaces and extra dots
//     dropped, other characters an 8.3 name cannot hold made "_" -- cut to
//     leave room for a numeric tail, ~1, ~2, ... (OpenRuntime.efi ->
//     OPENRU~1EFI), as Windows and mtools generate them.
func shortName(name string, taken map[[11]byte]bool) ([11]byte, bool, error) {
	if err := checkLongName(name); err != nil {
		return [11]byte{}, false, err
	}
	up := strings.ToUpper(name)
	base, ext := up, ""
	if i := strings.LastIndexByte(up, '.'); i > 0 {
		base, ext = up[:i], up[i+1:]
	}
	if base != "" && len(base) <= 8 && len(ext) <= 3 && allShort(base) && allShort(ext) {
		if s := pack83(base, ext); !taken[s] {
			return s, up != name, nil
		}
	}
	clean := func(s string) string {
		var b strings.Builder
		for _, c := range s {
			switch {
			case c == ' ' || c == '.':
			case validShort(c):
				b.WriteRune(c)
			default:
				b.WriteByte('_')
			}
		}
		return b.String()
	}
	b, e := clean(base), clean(ext)
	if len(e) > 3 {
		e = e[:3]
	}
	if b == "" {
		b = "_"
	}
	for n := 1; n <= 999999; n++ {
		tail := "~" + strconv.Itoa(n)
		keep := b
		if len(keep) > 8-len(tail) {
			keep = keep[:8-len(tail)]
		}
		if s := pack83(keep+tail, e); !taken[s] {
			return s, true, nil
		}
	}
	return [11]byte{}, false, fmt.Errorf("%q: no free short name", name)
}

// lfnCount is how many long-name entries name takes: 13 UTF-16 units each.
func lfnCount(name string) uint32 {
	return uint32((len(utf16.Encode([]rune(name))) + 12) / 13)
}

// lfnChecksum ties long-name entries to their short entry.
func lfnChecksum(s [11]byte) byte {
	var sum byte
	for _, c := range s {
		sum = (sum>>1 | sum<<7) + c
	}
	return sum
}

// lfnEntries are name's long-name entries, in the order they sit on disk:
// the last part first, flagged 0x40.
func lfnEntries(name string, short [11]byte) [][]byte {
	u := utf16.Encode([]rune(name))
	n := int(lfnCount(name))
	padded := make([]uint16, n*13)
	copy(padded, u)
	if len(u) < len(padded) {
		for i := len(u) + 1; i < len(padded); i++ {
			padded[i] = 0xFFFF // after the 0x0000 terminator
		}
	}
	sum := lfnChecksum(short)
	var out [][]byte
	for i := n; i >= 1; i-- {
		e := make([]byte, dirEntrySize)
		e[0] = byte(i)
		if i == n {
			e[0] |= 0x40
		}
		chunk := padded[(i-1)*13 : i*13]
		for j, c := range chunk {
			var at int
			switch {
			case j < 5:
				at = 1 + 2*j
			case j < 11:
				at = 14 + 2*(j-5)
			default:
				at = 28 + 2*(j-11)
			}
			binary.LittleEndian.PutUint16(e[at:], c)
		}
		e[11] = attrLFN
		e[13] = sum
		out = append(out, e)
	}
	return out
}
```

`internal/diskimg/fatread.go` is the reader. Write it to these rules.
The tests above are its specification.

- **`OpenFAT`**:
  - Read the boot sector at `off`.
  - Require `0x55AA` at 510, 512 bytes per sector, `FATSz16 == 0`,
    `FATSz32 != 0` and a root cluster ≥ 2.
  - Fill `G` from the BPB fields:
    `Clusters = (TotSec32 - reserved - FATs*FATSz32) / SecPerClus`.
  - `Label` is bytes 71–82, right-trimmed of spaces. `OEM` is bytes
    3–11, and `Serial` is at 67.
  - Read the whole first FAT into `[]uint32`.
- **`chain(first)`** follows entries until one is ≥ `0x0FFFFFF8`. These
  are errors: an entry < 2, an entry > `Clusters+1`, or more steps than
  `Clusters` (a loop). `first == 0` is an empty chain.
- **`ReadFile`** reads the chain and truncates it to the entry's size.
  A directory is an error. So is a size larger than the chain.
- **Parsing a directory's clusters**, 32 bytes at a time:
  - A `0x00` first byte ends the directory. `0xE5` is a deleted entry:
    skip it and drop any pending long name.
  - An `attr == 0x0F` entry is part of a long name. Its ordinal is
    `b[0] & 0x1F`; `0x40` marks the last part, which starts a new
    sequence. Keep its checksum at byte 13. Put its 13 units at
    `(ordinal-1)*13`, from offsets 1–10, 14–25 and 28–31. The name
    ends at the first `0x0000`.
  - A short entry with `attr & 0x08` (the volume label) is skipped.
    So are `.` and `..`.
  - For any other short entry:
    - `Short` is the base, right-trimmed, then `.` + ext if the ext is
      not blank.
    - A first byte of `0x05` stands for `0xE5`.
    - Byte 12's `0x08` lower-cases the base and `0x10` the ext. This
      is how mtools and Windows store all-lower-case 8.3 names without
      a long name.
    - `Name` is the pending long name if its checksum matches
      `lfnChecksum` of these 11 bytes; otherwise it is `Short`.
    - `Cluster` is `hi<<16 | lo`.
- **`ReadDir(path)`** walks from the root cluster (`G`'s root cluster
  field), matching each component case-insensitively against `Name`,
  then against `Short`.
- **`Walk`** is a pre-order walk in directory order, with paths
  `"/" + names joined by "/"`.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/diskimg/ -v 2>&1 | grep -E '^(--- |FAIL|ok|PASS)' | head -40`
Expected: PASS. Every parity test runs here: mtools, sgdisk and
fsck.fat are installed.

- [ ] **Step 5: Commit**

```bash
git add internal/diskimg
git commit   # subject: "diskimg: a deterministic FAT32 writer, mformat's geometry, readable by mtools and clean under fsck.fat"
```

---

### Task 9: The OpenCore build (`firmware/builder.go`, `opencore.go`)

**Files:**
- Create: `internal/firmware/builder.go`, `internal/firmware/opencore.go`
- Create: `internal/firmware/fixture_test.go` (shared by Tasks 9–11), `internal/firmware/opencore_test.go`

**Interfaces:**
- Consumes:
  - `untarGz` (Task 4);
  - `Toolchain`, `CcacheVerdict`, `CcacheLine` and `writeCcacheShims`
    (Task 5);
  - the pins (Task 2);
  - `fetch.SHA256File`;
  - `vmguest.Files` (the patches, Task 1);
  - `proc.Cmd.Env` (Task 1).
- Produces:
  - `type Builder struct{ Paths config.Paths; Registry *pins.Registry; Runner proc.Runner; Toolchain Toolchain; Ccache bool; Env []string; Log func(string, ...any) }`
  - `type Inputs map[string]string`: registry source name to verified
    path.
  - `(*Builder).OpenCore(ctx, in Inputs) ([]string, error)`: the five
    shipped paths, in `ShipNames()` order.
  - Unexported helpers that Tasks 10–11 use:
    - paths: `src()`, `udk()`, `artifactsDir()`, `buildLog()`,
      `ocvalidate()`;
    - `input(in, name)`, `requireTools(names...)`;
    - `buildEnv(ctx) (env []string, ccache bool, err error)`,
      `ccacheStats(ctx)`;
    - `runLogged(ctx, cmd, logPath)`, `applyPatch(ctx, dir, embedded)`;
    - `copyAtomic`, `writeFileAtomic`, `writeSums(dir, names)`;
    - `logf`.

- [ ] **Step 1: Write the test fixture and the failing tests**

`internal/firmware/fixture_test.go` builds a `VMAVS_HOME` whose every
firmware input is a small generated file. It pins them in a test
registry, and a `proc.Fake` plays gcc, git, `build_oc.tool` and EDK
II's `build`:

```go
package firmware

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/pins"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

const buildOCToolFetch = "src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) && eval \"$src\" || exit 1\n"

type fixture struct {
	t    *testing.T
	home string
	b    *Builder
	in   Inputs
	fake *proc.Fake
	log  bytes.Buffer

	// What the fake tools do; a test changes these before building.
	banner      string   // gcc --version's first line
	built       []string // build_oc.tool's outputs; default: every Artifacts Built name
	flags       string   // the fake GNUmakefile's CC_FLAGS
	patchesTake bool     // whether a fake `git apply -p1 -` changes the file
	buildErr    error    // build_oc.tool's (and EDK II build's) result
	fv          []string // OVMF's outputs; default: OVMFFiles
	stdins      [][]byte // every patch git apply read from stdin
}

func sha(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{t: t, home: t.TempDir(), in: Inputs{}, banner: "gcc (GCC) 13.3.0",
		flags: "-std=gnu17 -Wno-error", patchesTake: true}
	for _, a := range Artifacts {
		f.built = append(f.built, a.Built)
	}
	f.fv = append(f.fv, OVMFFiles...)
	inputs := t.TempDir()
	var reg strings.Builder
	pin := func(name, commit, file string) {
		f.in[name] = file
		reg.WriteString(name + "\thttps://example.test/" + commit + "/" + filepath.Base(file) + "\t" + sha(t, file) + "\n")
	}

	efibuild := filepath.Join(inputs, "efibuild.sh")
	os.WriteFile(efibuild, []byte("# efibuild\n"), 0o644)
	pin("ocbuild-efibuild", OCBuildCommit, efibuild)

	audk := []entry{{name: "audk-x/"}, {name: "audk-x/MdePkg/MdePkg.dec", body: "dec"},
		{name: "audk-x/OpenCorePkg/"}, {name: "audk-x/OvmfPkg/OvmfPkgX64.dsc", body: "[BuildOptions]\n"}}
	for _, s := range Submodules {
		audk = append(audk, entry{name: "audk-x/" + s.Path + "/"})
	}
	pin("audk-src", AudkCommit, rename(t, makeTarGz(t, t.TempDir(), audk...), filepath.Join(inputs, AudkCommit+".tar.gz")))
	for _, p := range OpenCorePins()[2:] {
		tgz := makeTarGz(t, t.TempDir(), entry{name: p.Source + "-x/"}, entry{name: p.Source + "-x/README", body: p.Source})
		pin(p.Source, p.Commit, rename(t, tgz, filepath.Join(inputs, p.Commit+".tar.gz")))
	}
	ocpkg := makeTarGz(t, t.TempDir(),
		entry{name: "OpenCorePkg-" + OCVersion + "/"},
		entry{name: "OpenCorePkg-" + OCVersion + "/build_oc.tool", body: "#!/bin/bash\n" + buildOCToolFetch, mode: 0o755},
		entry{name: "OpenCorePkg-" + OCVersion + "/Patches/0002-second.patch", body: "second"},
		entry{name: "OpenCorePkg-" + OCVersion + "/Patches/0001-first.patch", body: "first"},
	)
	pin("opencorepkg-src", "refs/tags/"+OCVersion, rename(t, ocpkg, filepath.Join(inputs, OCVersion+".tar.gz")))
	for _, k := range Kexts {
		z := makeZip(t, inputs, k.Name+"-RELEASE.zip",
			entry{name: k.Name + ".kext/Contents/Info.plist", body: "plist " + k.Name},
			entry{name: k.Name + ".kext/Contents/MacOS/" + k.Name, body: "macho " + k.Name, mode: 0o755})
		pin(k.Source, "releases", z)
	}

	r, err := pins.Parse(strings.NewReader(reg.String()))
	if err != nil {
		t.Fatal(err)
	}
	f.fake = &proc.Fake{Paths: map[string]string{}, Handle: f.handle}
	for _, tool := range []string{"bash", "git", "zip", "make", "python3", "gcc", "nasm", "iasl"} {
		f.fake.Paths[tool] = "/usr/bin/" + tool
	}
	f.b = &Builder{
		Paths:     config.Paths{Home: f.home},
		Registry:  r,
		Runner:    f.fake,
		Toolchain: Toolchain{Runner: f.fake},
		Env:       []string{"PATH=/usr/bin:/bin", "HOME=" + f.home},
		Log:       func(format string, a ...any) { f.log.WriteString(fmt.Sprintf(format, a...) + "\n") },
	}
	return f
}

func rename(t *testing.T, from, to string) string {
	t.Helper()
	if err := os.Rename(from, to); err != nil {
		t.Fatal(err)
	}
	return to
}

// handle plays the external tools.
func (f *fixture) handle(c proc.Cmd) error {
	switch {
	case c.Name == f.b.Toolchain.GCC() && len(c.Args) == 1 && c.Args[0] == "--version":
		io.WriteString(c.Stdout, f.banner+"\n")
	case c.Name == f.b.Toolchain.GCC() && len(c.Args) == 1 && c.Args[0] == "-dumpmachine":
		io.WriteString(c.Stdout, "x86_64-linux-gnu\n")
	case c.Name == "git" && len(c.Args) >= 4 && c.Args[2] == "apply" && c.Args[len(c.Args)-1] == "-":
		patch, _ := io.ReadAll(c.Stdin)
		f.stdins = append(f.stdins, patch)
		if f.patchesTake {
			f.applyFake(c.Args[1], string(patch))
		}
	case c.Name == "./build_oc.tool":
		if c.Stdout != nil {
			io.WriteString(c.Stdout, "compiling OpenCore\nline 2\n")
		}
		if f.buildErr != nil {
			return f.buildErr
		}
		built := filepath.Join(c.Dir, "UDK", "Build", "OpenCorePkg", Target+"_"+Toolchain, Arch)
		os.MkdirAll(filepath.Join(built, "OpenCorePkg", "Library", "x"), 0o755)
		os.WriteFile(filepath.Join(built, "OpenCorePkg", "Library", "x", "GNUmakefile"), []byte("CC_FLAGS = -Os "+f.flags+"\n"), 0o644)
		for _, n := range f.built {
			os.WriteFile(filepath.Join(built, n), []byte("built "+n), 0o644)
		}
		os.MkdirAll(filepath.Join(c.Dir, "UDK", "BaseTools", "Source", "C", "bin"), 0o755)
		os.WriteFile(filepath.Join(c.Dir, "UDK", "BaseTools", "Source", "C", "bin", "GenFv"), []byte("#!/bin/sh\n"), 0o755)
	case c.Name == "bash" && len(c.Args) == 2 && c.Args[0] == "-c" && strings.Contains(c.Args[1], "edksetup.sh"):
		if f.buildErr != nil {
			return f.buildErr
		}
		fv := filepath.Join(c.Dir, "Build", "OvmfX64", Target+"_"+Toolchain, "FV")
		os.MkdirAll(fv, 0o755)
		for _, n := range f.fv {
			os.WriteFile(filepath.Join(fv, n), []byte("fd "+n), 0o644)
		}
	}
	return nil
}

// applyFake makes a patch's effect happen: build_oc.tool stops fetching
// efibuild.sh, or the OVMF dsc gains the flag its patch adds.
func (f *fixture) applyFake(dir, patch string) {
	switch {
	case strings.Contains(patch, "build_oc.tool"):
		p := filepath.Join(dir, "build_oc.tool")
		b, _ := os.ReadFile(p)
		os.WriteFile(p, []byte(strings.Replace(string(b), buildOCToolFetch, "src=$(cat \"${EFIBUILD_SH}\") && eval \"$src\" || exit 1\n", 1)), 0o755)
	case strings.Contains(patch, "std=gnu17"):
		appendTo(filepath.Join(dir, OVMFDsc), "  GCC:*_*_*_CC_FLAGS = -std=gnu17\n")
	case strings.Contains(patch, "Wno-error"):
		appendTo(filepath.Join(dir, OVMFDsc), "  GCC:*_*_*_CC_FLAGS = -Wno-error\n")
	}
}

func appendTo(p, s string) {
	b, _ := os.ReadFile(p)
	os.WriteFile(p, append(b, s...), 0o644)
}

// calls is every command the fake saw whose name is name.
func (f *fixture) calls(name string) []proc.Cmd {
	var out []proc.Cmd
	for _, c := range f.fake.Calls {
		if c.Name == name {
			out = append(out, c)
		}
	}
	return out
}
```

`entry`, `makeTarGz` and `makeZip` are Task 4's.

`internal/firmware/opencore_test.go` covers these. Each builds with
`newFixture(t)`, changes what the test needs, and calls
`f.b.OpenCore(context.Background(), f.in)`.

1. **`TestOpenCoreBuildsAndShips`.**
   - It returns the five `artifacts/<ship>` paths, in `ShipNames()`
     order.
   - `artifacts/BOOTx64.efi` holds `built Bootstrap.efi`.
   - `artifacts/SHA256SUMS` is exactly
     `<sha of each>  <ship name>\n` in that order, as `sha256sum`
     prints it. If `sha256sum` is installed, also compare byte-for-byte
     with `(cd artifacts && sha256sum OpenCore.efi BOOTx64.efi …)`.
2. **`TestOpenCoreBuildEnvironment`.** There is exactly one
   `./build_oc.tool` call. Its:
   - `Dir` is `build/OpenCorePkg-1.0.7`;
   - `Env` contains `PATH=/usr/bin:/bin`, `ARCHS=X64`,
     `TOOLCHAINS=GCC`, `TARGETS=RELEASE`, `OFFLINE_MODE=1` and
     `EFIBUILD_SH=<f.in["ocbuild-efibuild"]>`;
   - `Env` contains exactly
     `BUILD_ARGUMENTS=-D OCPKG_BUILD_OPTIONS=-std=gnu17\t-Wno-error`,
     with a real tab;
   - output is in `build/opencore-build.log`, which holds
     `compiling OpenCore`.
3. **`TestOpenCorePatchesBuildOCToolAndChecksIt`.**
   - The first stdin patch equals the embedded
     `boot/patches/0001-build_oc-source-pinned-efibuild.patch`, and was
     applied with `git -C <src> apply -p1 -`.
   - Afterwards `build_oc.tool` no longer contains
     `raw.githubusercontent.com`.
   - With `patchesTake = false`, `OpenCore` fails with
     `build_oc.tool still fetches shell from the network`, and no
     `./build_oc.tool` call happened.
   - A second `OpenCore` on the patched tree applies no patch to
     `build_oc.tool`.
4. **`TestOpenCoreAssemblesTheUDKTree`.**
   - `UDK/.mqg-prepared` is `<AudkCommit>\n`, and
     `UDK/{patches,submodules,UDK}.ready` exist.
   - `UDK/OpenCorePkg` does not exist: the archive had it, and it was
     removed.
   - Every `Submodules` path holds its tarball's `README`: both brotli
     paths hold `audk-brotli`.
   - The upstream patches were applied in sorted order,
     `0001-first.patch` then `0002-second.patch`, each with
     `git -C <udk> apply --ignore-whitespace <path>`.
5. **`TestOpenCoreKeepsAWarmTree`.**
   - After a first build, write `UDK/sentinel`, then build again.
   - `sentinel` is still there, and no further
     `apply --ignore-whitespace` call was made.
6. **`TestOpenCoreRebuildsATreeAtAnotherCommit`.**
   - After a first build, write `old\n` to `.mqg-prepared` and create
     `UDK/sentinel`, then build again.
   - `sentinel` is gone, and the marker is the commit again.
7. **`TestOpenCoreRefusesFlagsThatDidNotArrive`.**
   - `flags` is `"-std=gnu17"`.
   - The error names `-Wno-error` and the GNUmakefile's path, and
     `artifacts/` holds no `.efi`.
8. **`TestOpenCoreNamesTheMissingArtifacts`.**
   - `built` lacks `Bootstrap.efi`.
   - The error contains `Bootstrap.efi` and `missing 1 of 5`.
9. **`TestOpenCoreNamesTheMissingInput`.**
   - Delete `f.in["audk-src"]`.
   - The error names `audk-src` and `vmavs fetch firmware`, and the
     fake ran nothing but `gcc`.
10. **`TestOpenCoreRefusesAnInputThatNoLongerVerifies`.**
    - Append a byte to the audk tarball.
    - The error contains `checksum mismatch` and the file's path.
11. **`TestOpenCoreRefusesACompilerBelowTheFloor`.**
    - `banner` is `gcc (GCC) 12.2.0`.
    - The error contains `below the floor`, and there was no
      `./build_oc.tool` call.
    - Then set `f.b.Toolchain.Override = "gcc 13.3.0"`: it builds, and
      the log says `--compiler is set`.
12. **`TestOpenCoreNamesEveryMissingTool`.**
    - Delete `zip` and `python3` from `f.fake.Paths`.
    - The error names both, and `vmavs doctor`.
13. **`TestOpenCoreBuildFailureNamesTheLogs`.**
    - `buildErr` is `&proc.ExitError{Cmd: "./build_oc.tool", Code: 2}`.
    - The error names `UDK/build.log` and `build/opencore-build.log`.
    - The log (`f.log`) contains `line 2`, from the tail.
14. **`TestOpenCoreWithCcache`.**
    - `f.b.Ccache = true` and `f.fake.Paths["ccache"] = "/usr/bin/ccache"`.
    - `build/ccache-bin/gcc` is `#!/bin/sh\nexec /usr/bin/ccache /usr/bin/gcc "$@"\n`.
    - The build's `Env` has a `PATH=` entry that starts with
      `build/ccache-bin` and comes after the base `PATH`, and has
      `CCACHE_DIR=<home>/build/ccache`.
    - Without `ccache` in `Paths`: the log says `ccache is not
      installed`, the build happens, and there is no shim directory.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ -run OpenCore 2>&1 | head`
Expected: `undefined: Builder` and similar.

- [ ] **Step 3: Implement**

`internal/firmware/builder.go`:

```go
package firmware

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/pins"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// Builder builds the firmware under one VMAVS_HOME. Every external
// program goes through Runner; Env is what those programs inherit
// (vmavs's own environment), to which each build adds its settings.
type Builder struct {
	Paths     config.Paths
	Registry  *pins.Registry
	Runner    proc.Runner
	Toolchain Toolchain
	Ccache    bool
	Env       []string
	Log       func(format string, a ...any)
}

// Inputs is each registry source a build reads, by name, at the path
// fetch verified it to (vmavs fetch firmware, or firmware itself).
type Inputs map[string]string

// The files and directories firmware names under build/ -- the shell
// tree's layout, so either tree can build on what the other left.
func (b *Builder) src() string          { return filepath.Join(b.Paths.Build(), "OpenCorePkg-"+OCVersion) }
func (b *Builder) udk() string          { return filepath.Join(b.src(), "UDK") }
func (b *Builder) artifactsDir() string { return filepath.Join(b.Paths.Build(), "artifacts") }
func (b *Builder) buildLog() string     { return filepath.Join(b.Paths.Build(), "opencore-build.log") }
func (b *Builder) ocvalidate() string {
	return filepath.Join(b.src(), "Utilities", "ocvalidate", "ocvalidate")
}

func (b *Builder) logf(format string, a ...any) {
	if b.Log != nil {
		b.Log(format, a...)
	}
}

// input is source name's file, re-hashed against the registry: the
// cache is read-only and was verified when filled, but a build that is
// about to spend fifteen minutes checks what it builds from, as
// build-opencore.sh's pinned_file does.
func (b *Builder) input(in Inputs, name string) (string, error) {
	p := in[name]
	if p == "" {
		return "", fmt.Errorf("no %s -- run 'vmavs fetch firmware'", name)
	}
	s, err := b.Registry.Lookup(name)
	if err != nil {
		return "", err
	}
	got, err := fetch.SHA256File(p)
	if err != nil {
		return "", err
	}
	if got != s.SHA256 {
		return "", fmt.Errorf("checksum mismatch for %s at %s: want %s, got %s", name, p, s.SHA256, got)
	}
	return p, nil
}

// requireTools names, in one error, every tool that is not on PATH.
func (b *Builder) requireTools(names ...string) error {
	var missing []string
	for _, n := range names {
		if _, err := b.Runner.LookPath(n); err != nil {
			missing = append(missing, n)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing build tools: %s -- run 'vmavs doctor'", strings.Join(missing, ", "))
	}
	return nil
}

// buildEnv is the environment a firmware build runs in: Env, plus, when
// ccache is asked for and present, the shim directory first on PATH and
// CCACHE_DIR under build/ (never the repository: thousands of small
// files). Whether ccache was used is logged either way.
func (b *Builder) buildEnv(ctx context.Context) ([]string, bool, error) {
	env := append([]string(nil), b.Env...)
	path, _ := b.Runner.LookPath("ccache")
	verdict, detail := CcacheVerdict(b.Ccache, path)
	switch verdict {
	case "MISSING":
		b.logf("warning: ccache: %s", detail)
		return env, false, nil
	case "OFF":
		b.logf("ccache: %s", detail)
		return env, false, nil
	}
	shims := filepath.Join(b.Paths.Build(), "ccache-bin")
	cache := filepath.Join(b.Paths.Build(), "ccache")
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return nil, false, err
	}
	if err := writeCcacheShims(shims, path, b.Runner.LookPath); err != nil {
		return nil, false, err
	}
	env = append(env, "PATH="+shims+string(os.PathListSeparator)+lookupEnv(b.Env, "PATH"), "CCACHE_DIR="+cache)
	b.logf("ccache: %s, cache in %s, shims in %s", path, cache, shims)
	b.logf("ccache: the compiler the manifest records is still the real one -- a shim answers --version as what it wraps")
	return env, true, nil
}

// lookupEnv is key's value in env, the last one if it is there twice.
func lookupEnv(env []string, key string) string {
	v := ""
	for _, kv := range env {
		if k, val, ok := strings.Cut(kv, "="); ok && k == key {
			v = val
		}
	}
	return v
}

// ccacheStats logs the first lines of `ccache -s` after a build that used
// it; ccache has reorganised that output more than once, so it is shown,
// not parsed.
func (b *Builder) ccacheStats(ctx context.Context) {
	var out bytes.Buffer
	if err := b.Runner.Run(ctx, proc.Cmd{Name: "ccache", Args: []string{"-s"}, Stdout: &out}); err != nil {
		return
	}
	sc := bufio.NewScanner(&out)
	for i := 0; i < 8 && sc.Scan(); i++ {
		b.logf("ccache: %s", sc.Text())
	}
}

// runLogged runs c with its output in logPath (spec §2: stdout carries a
// command's own output, and a firmware build's is not that). On failure
// it logs the last 20 lines of the log and returns an error naming it.
func (b *Builder) runLogged(ctx context.Context, c proc.Cmd, logPath string) error {
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		return err
	}
	lf, err := os.Create(logPath)
	if err != nil {
		return err
	}
	c.Stdout, c.Stderr = lf, lf
	runErr := b.Runner.Run(ctx, c)
	if err := lf.Close(); err != nil && runErr == nil {
		runErr = err
	}
	if runErr == nil {
		return nil
	}
	if data, err := os.ReadFile(logPath); err == nil {
		lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
		if len(lines) > 20 {
			lines = lines[len(lines)-20:]
		}
		b.logf("the last lines of %s:", logPath)
		for _, l := range lines {
			b.logf("  %s", l)
		}
	}
	return fmt.Errorf("%w (log: %s)", runErr, logPath)
}

// applyPatch applies one of the patches the binary carries (boot/patches/
// in the repository) in dir with `git apply -p1`, reading it from stdin.
func (b *Builder) applyPatch(ctx context.Context, dir, name string) error {
	patch, err := fs.ReadFile(vmguest.Files, "boot/patches/"+name)
	if err != nil {
		return err
	}
	return b.Runner.Run(ctx, proc.Cmd{Name: "git", Args: []string{"-C", dir, "apply", "-p1", "-"},
		Stdin: bytes.NewReader(patch), Stderr: logWriter{b}})
}

// logWriter sends a tool's stderr to the log, line by line.
type logWriter struct{ b *Builder }

func (w logWriter) Write(p []byte) (int, error) {
	for _, l := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		w.b.logf("  %s", l)
	}
	return len(p), nil
}

// copyAtomic copies src to dst through a temp file beside dst, synced and
// renamed, so dst is never half-written.
func copyAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	return writeAtomic(dst, 0o644, func(w io.Writer) error { _, err := io.Copy(w, in); return err })
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	return writeAtomic(path, perm, func(w io.Writer) error { _, err := w.Write(data); return err })
}

func writeAtomic(path string, perm os.FileMode, fill func(io.Writer) error) (err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	if err = fill(tmp); err != nil {
		return err
	}
	if err = tmp.Chmod(perm); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// writeSums writes dir/SHA256SUMS for names, in order, as sha256sum
// prints it: "<hex>  <name>".
func writeSums(dir string, names []string) error {
	var b strings.Builder
	for _, n := range names {
		sum, err := fetch.SHA256File(filepath.Join(dir, n))
		if err != nil {
			return err
		}
		b.WriteString(sum + "  " + n + "\n")
	}
	return writeFileAtomic(filepath.Join(dir, "SHA256SUMS"), []byte(b.String()), 0o644)
}
```

`internal/firmware/opencore.go`:

```go
package firmware

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

const buildOCPatch = "0001-build_oc-source-pinned-efibuild.patch"

// OpenCore builds OpenCore from the pinned sources in in and ships its
// five artifacts to build/artifacts with a SHA256SUMS: the Go form of
// boot/build-opencore.sh. It reaches no network. Steps a warm tree has
// done (unpacking, patching, assembling the EDK II tree) are skipped;
// build_oc.tool itself is incremental.
func (b *Builder) OpenCore(ctx context.Context, in Inputs) ([]string, error) {
	// The compiler first: a host below the floor hears that before
	// anything expensive, not after a fetch and three minutes of gcc.
	if err := b.Toolchain.Check(ctx, b.logf); err != nil {
		return nil, err
	}
	if err := CheckPins(b.Registry); err != nil {
		return nil, err
	}
	files := map[string]string{}
	for _, n := range OpenCoreSources() {
		p, err := b.input(in, n)
		if err != nil {
			return nil, err
		}
		files[n] = p
	}
	// git: efibuild.sh insists on it, and patches are applied with it.
	// zip: efibuild.sh will not start without it.
	if err := b.requireTools("bash", "git", "zip", "make", "python3", b.Toolchain.GCC()); err != nil {
		return nil, err
	}
	if err := b.unpackOpenCorePkg(ctx, files["opencorepkg-src"]); err != nil {
		return nil, err
	}
	if err := b.patchBuildOCTool(ctx); err != nil {
		return nil, err
	}
	if err := b.assembleUDK(ctx, files); err != nil {
		return nil, err
	}
	env, ccache, err := b.buildEnv(ctx)
	if err != nil {
		return nil, err
	}

	b.logf("building OpenCore %s in %s", OCVersion, b.src())
	b.logf("arch %s, toolchain %s, target %s -- this takes a while; its output goes to %s", Arch, Toolchain, Target, b.buildLog())
	b.logf("compiler: %s", b.Toolchain.CompilerLine(ctx))
	start := time.Now()
	cmd := proc.Cmd{Name: "./build_oc.tool", Dir: b.src(), Env: append(env,
		"ARCHS="+Arch, "TOOLCHAINS="+Toolchain, "TARGETS="+Target, "OFFLINE_MODE=1",
		"EFIBUILD_SH="+files["ocbuild-efibuild"],
		"BUILD_ARGUMENTS=-D OCPKG_BUILD_OPTIONS="+BuildOptions())}
	if err := b.runLogged(ctx, cmd, b.buildLog()); err != nil {
		return nil, fmt.Errorf("build_oc.tool failed -- see %s and %s, and report the error rather than working around it: %w",
			filepath.Join(b.udk(), "build.log"), b.buildLog(), err)
	}
	b.logf("build_oc.tool finished in %s", time.Since(start).Round(time.Second))
	if ccache {
		b.ccacheStats(ctx)
	}

	built := filepath.Join(b.udk(), "Build", "OpenCorePkg", Target+"_"+Toolchain, Arch)
	if fi, err := os.Stat(built); err != nil || !fi.IsDir() {
		return nil, fmt.Errorf("build reported success but %s does not exist", built)
	}
	if err := checkFlags(built); err != nil {
		return nil, err
	}
	return b.shipArtifacts(built)
}

// unpackOpenCorePkg unpacks the OpenCorePkg release once.
func (b *Builder) unpackOpenCorePkg(ctx context.Context, tarball string) error {
	if _, err := os.Stat(b.src()); err != nil {
		b.logf("unpacking OpenCorePkg %s to %s", OCVersion, b.src())
		if err := untarGz(ctx, tarball, b.src(), 1); err != nil {
			return err
		}
	} else {
		b.logf("OpenCorePkg %s already unpacked at %s", OCVersion, b.src())
	}
	if _, err := os.Stat(filepath.Join(b.src(), "build_oc.tool")); err != nil {
		return fmt.Errorf("%s does not look like OpenCorePkg: no build_oc.tool", b.src())
	}
	return nil
}

// patchBuildOCTool replaces build_oc.tool's curl-and-eval of efibuild.sh
// with a read of the pinned copy (boot/patches/0001), and checks it took,
// so a patch that silently did nothing cannot pass for success.
func (b *Builder) patchBuildOCTool(ctx context.Context) error {
	tool := filepath.Join(b.src(), "build_oc.tool")
	fetches := func() (bool, error) {
		data, err := os.ReadFile(tool)
		return strings.Contains(string(data), "raw.githubusercontent.com"), err
	}
	yes, err := fetches()
	if err != nil {
		return err
	}
	if yes {
		b.logf("patching build_oc.tool to read the pinned efibuild.sh")
		if err := b.applyPatch(ctx, b.src(), buildOCPatch); err != nil {
			return fmt.Errorf("cannot patch build_oc.tool -- did OpenCorePkg %s change? %w", OCVersion, err)
		}
		if yes, err = fetches(); err != nil {
			return err
		}
	}
	if yes {
		return fmt.Errorf("build_oc.tool still fetches shell from the network")
	}
	return nil
}

// assembleUDK builds the EDK II tree efibuild.sh would otherwise clone
// at master: audk at its pinned commit, its submodules from their own
// tarballs, OpenCorePkg's own patches. The .mqg-prepared marker says
// which commit the tree holds; a tree at another (or no) commit is
// removed and rebuilt, exactly as build-opencore.sh does. UDK.ready must
// exist before build_oc.tool runs, or efibuild.sh deletes the tree.
func (b *Builder) assembleUDK(ctx context.Context, files map[string]string) error {
	marker := filepath.Join(b.udk(), ".mqg-prepared")
	if have, err := os.ReadFile(marker); err == nil && string(have) == AudkCommit+"\n" {
		b.logf("EDK II tree already assembled at audk %s", AudkCommit)
		return nil
	}
	b.logf("assembling the EDK II tree: audk %s", AudkCommit)
	if err := os.RemoveAll(b.udk()); err != nil {
		return err
	}
	if err := untarGz(ctx, files["audk-src"], b.udk(), 1); err != nil {
		return err
	}
	// audk has a submodule of its own called OpenCorePkg, which the
	// archive leaves as an empty directory; efibuild.sh wants a symlink
	// there, and its symlink() does nothing if a directory is in the way.
	if err := os.RemoveAll(filepath.Join(b.udk(), "OpenCorePkg")); err != nil {
		return err
	}
	for _, s := range Submodules {
		b.logf("  + %s @ %s", s.Path, s.Commit)
		dest := filepath.Join(b.udk(), filepath.FromSlash(s.Path))
		if err := os.RemoveAll(dest); err != nil { // the archive's empty placeholder
			return err
		}
		if err := untarGz(ctx, files[s.Source], dest, 1); err != nil {
			return err
		}
	}
	patches, err := filepath.Glob(filepath.Join(b.src(), "Patches", "*"))
	if err != nil {
		return err
	}
	sort.Strings(patches)
	for _, p := range patches {
		if fi, err := os.Stat(p); err != nil || !fi.Mode().IsRegular() {
			continue
		}
		b.logf("  + patch %s", filepath.Base(p))
		if err := b.Runner.Run(ctx, proc.Cmd{Name: "git", Args: []string{"-C", b.udk(), "apply", "--ignore-whitespace", p},
			Stderr: logWriter{b}}); err != nil {
			return fmt.Errorf("cannot apply %s to the EDK II tree: %w", p, err)
		}
	}
	for _, r := range []string{"patches.ready", "submodules.ready", "UDK.ready"} {
		if err := os.WriteFile(filepath.Join(b.udk(), r), nil, 0o644); err != nil {
			return err
		}
	}
	return writeFileAtomic(marker, []byte(AudkCommit+"\n"), 0o644)
}

// checkFlags asserts both halves of BuildOptions reached the compiler, in
// the first generated GNUmakefile: the check a tab quietly becoming a
// space, or upstream's hook quietly going away on a pin bump, cannot get
// past. The makefiles are rewritten on every build, warm or cold.
func checkFlags(built string) error {
	var mk string
	err := filepath.WalkDir(built, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && d.Name() == "GNUmakefile" {
			mk = p
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		return err
	}
	if mk == "" {
		return fmt.Errorf("no GNUmakefile under %s -- cannot check the build flags", built)
	}
	data, err := os.ReadFile(mk)
	if err != nil {
		return err
	}
	for _, flag := range []string{"-std=" + CStd, NoWerror} {
		if !strings.Contains(string(data), flag) {
			return fmt.Errorf("%s never reached the compiler (checked %s) -- did OpenCorePkg %s drop $(OCPKG_BUILD_OPTIONS)?", flag, mk, OCVersion)
		}
	}
	return nil
}

// shipArtifacts copies what we ship out of the build tree, under the
// names we ship them as, and writes their SHA256SUMS.
func (b *Builder) shipArtifacts(built string) ([]string, error) {
	var missing []string
	for _, a := range Artifacts {
		if _, err := os.Stat(filepath.Join(built, a.Built)); err != nil {
			missing = append(missing, a.Built)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing %d of %d artifacts: %s (looked in %s)", len(missing), len(Artifacts), strings.Join(missing, " "), built)
	}
	var out []string
	for _, a := range Artifacts {
		dst := filepath.Join(b.artifactsDir(), a.Ship)
		if err := copyAtomic(filepath.Join(built, a.Built), dst); err != nil {
			return nil, err
		}
		out = append(out, dst)
	}
	if err := writeSums(b.artifactsDir(), ShipNames()); err != nil {
		return nil, err
	}
	if fi, err := os.Stat(b.ocvalidate()); err == nil && fi.Mode()&0o111 != 0 {
		b.logf("ocvalidate: %s", b.ocvalidate())
	} else {
		b.logf("warning: ocvalidate not built at %s -- a derived SMBIOS config will ship unvalidated", b.ocvalidate())
	}
	b.logf("built %d artifacts into %s", len(out), b.artifactsDir())
	return out, nil
}
```

`checkFlags` takes the first GNUmakefile in `WalkDir`'s lexical order,
which is the order `find | sort` gives in the C locale. All the
makefiles carry the same `CC_FLAGS`, so which one is checked does not
matter.

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -run 'OpenCore' -v 2>&1 | grep -E '^(--- |FAIL|ok)' && go vet ./internal/firmware/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware
git commit   # subject: "firmware: build OpenCore from the pinned sources, offline, and ship what build-opencore.sh ships"
```

---

### Task 10: The OVMF build (`firmware/ovmf.go`)

**Files:**
- Create: `internal/firmware/ovmf.go`, `internal/firmware/ovmf_test.go`

**Interfaces:**
- Consumes: Task 9's `Builder` helpers and fixture; `config.Paths.Firmware()`.
- Produces: `(*Builder).OVMF(ctx) ([]string, error)`, which returns the
  three `build/firmware/*.fd` paths in `OVMFFiles` order.

- [ ] **Step 1: Write the failing tests**

In `internal/firmware/ovmf_test.go`, every test first runs
`f.b.OpenCore` with the fixture, which leaves an assembled tree and a
`GenFv`. The exceptions build their precondition by hand, as noted.

1. **`TestOVMFBuildsX64ReleaseWithGCC`.** There is exactly one call
   named `bash`. Its:
   - `Args` are
     `["-c", "set +u; . ./edksetup.sh >/dev/null || exit 1; exec build -a X64 -b RELEASE -t GCC -p OvmfPkg/OvmfPkgX64.dsc"]`;
   - `Dir` is the UDK tree;
   - `Env` contains the base `PATH`;
   - output goes to `UDK/ovmf-build.log`.
2. **`TestOVMFShipsTheThreeImages`.**
   - It returns `build/firmware/{OVMF_CODE,OVMF_VARS,OVMF}.fd`.
   - Their contents are `fd OVMF_CODE.fd` and so on.
   - `build/firmware/SHA256SUMS` lists all three, in that order, in
     `sha256sum` form.
   - The log names each file's size in bytes.
3. **`TestOVMFAppliesBothPatchesAndChecksThem`.**
   - After the build, the stdin patches (after 0001) are the embedded
     `0002-ovmf-pin-the-c-dialect.patch` and
     `0003-firmware-drop-werror.patch`, in that order.
   - The dsc contains `std=gnu17` and `Wno-error`.
   - A second `OVMF` applies neither.
   - On a fresh fixture, run `OpenCore` first (it needs its own patch
     to take). Then set `patchesTake = false`: `OVMF`'s error is
     `OvmfPkg/OvmfPkgX64.dsc still does not state a C dialect`.
4. **`TestOVMFRefusesAnAbsentTree`.** No `OpenCore` first. The error is
   `no assembled EDK II tree at <udk> -- run 'vmavs firmware opencore' first`,
   and there is no `bash` call.
5. **`TestOVMFRefusesATreeAtAnotherCommit`.** `.mqg-prepared` holds
   `abc\n`. The error names `abc` and the pinned commit.
6. **`TestOVMFSaysSoWhenBaseToolsAreNotBuilt`.** Remove `GenFv`. The
   error is `BaseTools are not built in <udk> -- run 'vmavs firmware opencore' first`.
7. **`TestOVMFNamesMissingImages`.** `fv` lacks `OVMF.fd`. The error
   contains `missing 1 of 3 firmware images: OVMF.fd`.
8. **`TestOVMFBuildFailureNamesTheLog`.** Set `buildErr` after
   `OpenCore`. The error names `ovmf-build.log`.
9. **`TestOVMFRefusesACompilerBelowTheFloor`.** It fails like
   OpenCore's, with no `bash` call.
10. **`TestOVMFNeedsNasmAndIasl`.** Remove both from the fake's
    `Paths`. The error names them.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ -run OVMF 2>&1 | head`
Expected: `b.OVMF undefined`.

- [ ] **Step 3: Implement `internal/firmware/ovmf.go`**

```go
package firmware

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

// ovmfBuild is EDK II's own way to build: edksetup.sh (not written for
// set -u) puts `build` on PATH with WORKSPACE and CONF_PATH set, then
// build runs. bash -c is its subshell.
var ovmfBuild = fmt.Sprintf("set +u; . ./edksetup.sh >/dev/null || exit 1; exec build -a %s -b %s -t %s -p %s",
	Arch, Target, Toolchain, OVMFDsc)

// OVMF builds the guest's UEFI firmware from the EDK II tree OpenCore
// assembled (one pinned tree, not a second copy that could drift), and
// ships OVMF_CODE.fd, OVMF_VARS.fd and OVMF.fd to build/firmware with a
// SHA256SUMS: the Go form of boot/build-ovmf.sh. Debian's stock OVMF does
// not work with OpenCore on these hosts (NOTES.md, P3 Task 8); the one
// built from acidanthera's audk does.
func (b *Builder) OVMF(ctx context.Context) ([]string, error) {
	// The compiler first, and for this build above all: OvmfPkg compiled
	// clean under C23 and emitted different firmware.
	if err := b.Toolchain.Check(ctx, b.logf); err != nil {
		return nil, err
	}
	have, err := os.ReadFile(filepath.Join(b.udk(), ".mqg-prepared"))
	switch {
	case err != nil:
		return nil, fmt.Errorf("no assembled EDK II tree at %s -- run 'vmavs firmware opencore' first", b.udk())
	case string(have) != AudkCommit+"\n":
		return nil, fmt.Errorf("the EDK II tree at %s holds audk %s, not the pinned %s -- run 'vmavs firmware opencore'",
			b.udk(), strings.TrimSpace(string(have)), AudkCommit)
	}
	if fi, err := os.Stat(filepath.Join(b.udk(), "BaseTools", "Source", "C", "bin", "GenFv")); err != nil || fi.Mode()&0o111 == 0 {
		return nil, fmt.Errorf("BaseTools are not built in %s -- run 'vmavs firmware opencore' first", b.udk())
	}
	// nasm assembles the reset vector; iasl compiles the ACPI tables.
	if err := b.requireTools("bash", "git", "make", "python3", "nasm", "iasl", b.Toolchain.GCC()); err != nil {
		return nil, err
	}
	dsc := filepath.Join(b.udk(), filepath.FromSlash(OVMFDsc))
	for _, p := range []struct{ patch, marker, what string }{
		{"0002-ovmf-pin-the-c-dialect.patch", "std=gnu17", "state a C dialect"},
		{"0003-firmware-drop-werror.patch", "Wno-error", "stop promoting upstream's warnings to errors"},
	} {
		if err := b.patchOnce(ctx, dsc, p.patch, p.marker, p.what); err != nil {
			return nil, err
		}
	}
	env, ccache, err := b.buildEnv(ctx)
	if err != nil {
		return nil, err
	}

	logPath := filepath.Join(b.udk(), "ovmf-build.log")
	b.logf("building %s from audk %s in %s", OVMFDsc, AudkCommit, b.udk())
	b.logf("arch %s, toolchain %s, target %s -- its output goes to %s", Arch, Toolchain, Target, logPath)
	b.logf("compiler: %s", b.Toolchain.CompilerLine(ctx))
	start := time.Now()
	if err := b.runLogged(ctx, proc.Cmd{Name: "bash", Args: []string{"-c", ovmfBuild}, Dir: b.udk(), Env: env}, logPath); err != nil {
		return nil, fmt.Errorf("the OVMF build failed -- see %s, and report the error rather than working around it: %w", logPath, err)
	}
	b.logf("build finished in %s", time.Since(start).Round(time.Second))
	if ccache {
		b.ccacheStats(ctx)
	}

	fv := filepath.Join(b.udk(), "Build", "OvmfX64", Target+"_"+Toolchain, "FV")
	var missing []string
	for _, n := range OVMFFiles {
		if _, err := os.Stat(filepath.Join(fv, n)); err != nil {
			missing = append(missing, n)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing %d of %d firmware images: %s (looked in %s)", len(missing), len(OVMFFiles), strings.Join(missing, " "), fv)
	}
	var out []string
	for _, n := range OVMFFiles {
		dst := filepath.Join(b.Paths.Firmware(), n)
		if err := copyAtomic(filepath.Join(fv, n), dst); err != nil {
			return nil, err
		}
		out = append(out, dst)
	}
	if err := writeSums(b.Paths.Firmware(), OVMFFiles); err != nil {
		return nil, err
	}
	// The sizes are load-bearing for the pflash pair: QEMU sizes each
	// flash device from its file.
	b.logf("built %d firmware images into %s", len(out), b.Paths.Firmware())
	for _, p := range out {
		if fi, err := os.Stat(p); err == nil {
			b.logf("  %s  %d bytes", filepath.Base(p), fi.Size())
		}
	}
	return out, nil
}

// patchOnce applies one of our dsc patches unless the dsc already has its
// marker, then checks that it does. The tree is re-unpacked whenever the
// audk pin moves, which is why this runs on every build.
func (b *Builder) patchOnce(ctx context.Context, dsc, patch, marker, what string) error {
	has := func() (bool, error) {
		data, err := os.ReadFile(dsc)
		return strings.Contains(string(data), marker), err
	}
	ok, err := has()
	if err != nil {
		return err
	}
	if !ok {
		b.logf("patching %s to %s", OVMFDsc, what)
		if err := b.applyPatch(ctx, b.udk(), patch); err != nil {
			return fmt.Errorf("cannot patch %s -- did audk %s change? %w", OVMFDsc, AudkCommit, err)
		}
		if ok, err = has(); err != nil {
			return err
		}
	}
	if !ok {
		return fmt.Errorf("%s still does not %s", OVMFDsc, what)
	}
	return nil
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -run 'OVMF|OpenCore' -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware/ovmf.go internal/firmware/ovmf_test.go
git commit   # subject: "firmware: build OVMF from the same pinned EDK II tree, patched and checked as build-ovmf.sh does"
```

---

### Task 11: The kexts and the OpenCore EFI image (`firmware/kexts.go`, `efi.go`)

**Files:**
- Create: `internal/firmware/kexts.go`, `internal/firmware/efi.go`, `internal/firmware/efi_test.go`

**Interfaces:**
- Consumes:
  - `extractKext` (Task 4);
  - the SMBIOS functions (Task 6);
  - `diskimg` (Tasks 7–8);
  - Task 9's helpers;
  - `config.Paths.OpenCoreImageOut()` (Task 1);
  - the embedded `boot/config/config.plist`.
- Produces:
  - `(*Builder).Kexts(ctx, in Inputs) ([]string, error)`: the bundle
    paths, in `Kexts` order.
  - `(*Builder).EFIImage(ctx, model string) (string, error)`: the image
    path. `model` of `""` means `DefaultSMBIOS`.
  - `Fits(mib int, payload int64) bool`.

- [ ] **Step 1: Write the failing tests**

`internal/firmware/efi_test.go`. A helper `shipped(f)` writes five fake
artifacts (`fake <name>`) into `build/artifacts` with `writeSums`, then
runs `f.b.Kexts(ctx, f.in)`. Neither build tool is needed.

1. **`TestFitsDemandsHeadroomLikeEfiFits`.**
   - For `mib` 192, check payloads 0, 98041855, 98041856, 98041857 and
     200000000. The capacity is `(191-4)*1048576 = 196083712`, so the
     last payload that fits is 98041856. Also check `mib` 5 with 1
     (capacity 0) and `mib` 4 with 0 (capacity negative): both are
     false.
   - Each `Fits` equals `bash -c '. lib/common.sh; . lib/efi.sh; efi_fits M B'`'s
     exit status.
   - `efi_fits` needs no GNU tools, so this runs wherever bash does.
2. **`TestKextsUnpackEachBundleWithItsBinary`.**
   - It returns `build/kexts/{Lilu,VirtualSMC}.kext`.
   - Each holds `Contents/Info.plist` and an executable
     `Contents/MacOS/<K>`.
3. **`TestKextsKeepAnExistingBundle`.** Write a sentinel into
   `build/kexts/Lilu.kext/Contents/`, then run `Kexts` again: the
   sentinel is still there.
4. **`TestKextsNameTheMissingBinary`.**
   - Rebuild the Lilu zip without `MacOS/Lilu`, and re-pin it with a
     fresh registry row.
   - The error is
     `<home>/build/kexts/Lilu.kext is not a kext bundle: no Contents/MacOS/Lilu`.
5. **`TestEFIImageLayout`.** After `shipped(f)`, run `EFIImage(ctx, "")`:
   - It returns `<home>/build/opencore.img`.
   - `opencore.img.sha256` is the image's hex and `\n`.
   - `ReadGPT` finds one partition: `TypeEFISystem`, LBA 2048 to
     393182, named `EFI`.
   - `OpenFAT(img, 2048*512)`, walked, gives exactly these paths:
     ```
     /EFI /EFI/BOOT /EFI/OC /EFI/OC/Drivers /EFI/OC/Kexts /EFI/OC/ACPI /EFI/OC/Tools /EFI/OC/Resources
     /EFI/BOOT/BOOTx64.efi /EFI/OC/OpenCore.efi
     /EFI/OC/Drivers/OpenRuntime.efi /EFI/OC/Drivers/OpenPartitionDxe.efi /EFI/OC/Drivers/OpenHfsPlus.efi
     /EFI/OC/config.plist
     /EFI/OC/Kexts/Lilu.kext /EFI/OC/Kexts/Lilu.kext/Contents /EFI/OC/Kexts/Lilu.kext/Contents/MacOS
     /EFI/OC/Kexts/Lilu.kext/Contents/Info.plist /EFI/OC/Kexts/Lilu.kext/Contents/MacOS/Lilu
     (the same five for VirtualSMC)
     ```
     Compare them as a sorted set.
   - `config.plist` is the embedded config, byte for byte.
   - No path contains `HfsPlusLegacy`.
6. **`TestEFIImageIsDeterministic`.** Build, record the sha, remove the
   image and its sidecar, build again: the sha is the same.
7. **`TestEFIImageRefusesArtifactsThatDoNotMatchSHA256SUMS`.**
   - Overwrite `artifacts/OpenCore.efi` after `shipped`.
   - The error names `SHA256SUMS`.
   - A pre-existing `build/opencore.img` holding `old` is unchanged.
8. **`TestEFIImageNamesTheMissingPiece`.**
   - With no `artifacts/` at all, the error is
     `no artifacts at <dir> -- run 'vmavs firmware opencore' first`.
   - With `kexts/VirtualSMC.kext/Contents/Info.plist` removed, the
     error names the bundle, `Contents/Info.plist` and
     `vmavs firmware efi`.
9. **`TestEFIImageWithAnotherSMBIOS`.** Model `MacPro5,1`:
   - `build/config/config-MacPro5,1.plist` equals
     `SetProductName(embedded, "MacPro5,1")`, and so does the image's
     `config.plist`.
   - If a fake executable `ocvalidate` exists at `b.ocvalidate()` (write
     `#!/bin/sh\n` 0755 there), the fake saw a call with that name and
     the derived path as its only argument.
   - If the fake returns an `ExitError` for it, the error contains
     `ocvalidate rejected the derived config`.
   - With no ocvalidate at all (not built, and not in `Paths`), the log
     warns `shipping the derived config unvalidated`.
10. **`TestEFIImageRefusesAMalformedSMBIOS`.** Model `a<b`: the error
    names it, and no image is written.
11. **`TestEFIImageMatchesBuildEFIImageSh`.** Skip unless on Linux with
    `bash`, `sgdisk`, `mformat`, `mmd`, `mcopy`, `mdir`, `truncate` and
    `sha256sum`.
    1. After `shipped(f)`, run
       `env MQG_IMAGE_DIR=<home> MQG_BUILD_DIR=<home>/build bash boot/build-efi-image.sh <home>/shell.img`
       from the repository root.
    2. Build Go's image.
    3. Open both with `ReadGPT`, and with `OpenFAT` at `2048*512`.
    4. Assert that these are equal:
       - the partition's first LBA, last LBA, type and name;
       - the FAT geometry, except `HiddenSectors`;
       - the walked set of paths, as long names;
       - every file's bytes.
    5. The comment lists the differences that are deliberate (Ruling 5
       and 6): GUIDs, serial, OEM name, hidden sectors, timestamps and
       short-name tails.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/firmware/ -run 'Fits|Kexts|EFIImage' 2>&1 | head`
Expected: undefined symbols.

- [ ] **Step 3: Implement**

`internal/firmware/kexts.go`:

```go
package firmware

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// kextsDir is where the kext bundles are unpacked: build/kexts.
func (b *Builder) kextsDir() string { return filepath.Join(b.Paths.Build(), "kexts") }

// Kexts unpacks each pinned kext release's bundle into build/kexts, once:
// the layout the EFI image copies from. These are the only things in the
// image not built here (acidanthera ships them as binaries); they are
// pinned by checksum, and each bundle must hold the two files
// config.plist names for it, checked by name so a failure says which.
func (b *Builder) Kexts(ctx context.Context, in Inputs) ([]string, error) {
	var out []string
	for _, k := range Kexts {
		bundle := filepath.Join(b.kextsDir(), k.Name+".kext")
		if _, err := os.Stat(bundle); err == nil {
			b.logf("%s.kext already unpacked at %s", k.Name, bundle)
		} else {
			archive, err := b.input(in, k.Source)
			if err != nil {
				return nil, err
			}
			if err := extractKext(ctx, archive, k.Name, bundle); err != nil {
				return nil, err
			}
		}
		if err := checkKext(bundle, k.Name); err != nil {
			return nil, err
		}
		out = append(out, bundle)
	}
	return out, nil
}

func checkKext(bundle, name string) error {
	for _, want := range []string{filepath.Join("Contents", "Info.plist"), filepath.Join("Contents", "MacOS", name)} {
		if fi, err := os.Stat(filepath.Join(bundle, want)); err != nil || !fi.Mode().IsRegular() {
			return fmt.Errorf("%s is not a kext bundle: no %s", bundle, filepath.ToSlash(want))
		}
	}
	return nil
}
```

`internal/firmware/efi.go`:

```go
package firmware

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/diskimg"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// configDir is where a derived config.plist goes: build/config.
func (b *Builder) configDir() string { return filepath.Join(b.Paths.Build(), "config") }

// verifySums checks every file dir/SHA256SUMS lists, as `sha256sum -c`.
func verifySums(dir string) error {
	data, err := os.ReadFile(filepath.Join(dir, "SHA256SUMS"))
	if err != nil {
		return err
	}
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		want, name, ok := strings.Cut(line, "  ")
		if !ok || len(want) != 64 || strings.ContainsAny(name, `/\`) {
			return fmt.Errorf("%s: a line that is not '<sha256>  <name>': %q", filepath.Join(dir, "SHA256SUMS"), line)
		}
		got, err := fetch.SHA256File(filepath.Join(dir, name))
		if err != nil {
			return err
		}
		if got != want {
			return fmt.Errorf("%s does not match %s -- rebuild", filepath.Join(dir, name), filepath.Join(dir, "SHA256SUMS"))
		}
	}
	return nil
}

// Fits says whether a payload of that many bytes belongs in an image of
// mib MiB, with room to spare: 1 MiB before the partition and ~4 MiB of
// FAT32 overhead reserved, then the payload twice over, so a driver or a
// kext can double without anyone redoing this arithmetic (efi_fits).
func Fits(mib int, payload int64) bool {
	capacity := int64(mib-1)*1024*1024 - 4*1024*1024
	return capacity > 0 && payload*2 <= capacity
}

// efiDirs is the image's directory tree, parents first.
var efiDirs = []string{"/EFI", "/EFI/BOOT", "/EFI/OC", "/EFI/OC/Drivers", "/EFI/OC/Kexts",
	"/EFI/OC/ACPI", "/EFI/OC/Tools", "/EFI/OC/Resources"}

// EFIImage assembles OpenCore's EFI image -- the artifacts, the kexts and
// config.plist on a FAT32 EFI System Partition -- and writes it to
// build/opencore.img with a .sha256 sidecar: the Go form of
// boot/build-efi-image.sh, without sgdisk or mtools, and deterministic.
//
// config.plist ships verbatim unless model asks for a different SMBIOS,
// when a copy with SystemProductName changed (and nothing else) is
// written to build/config/, checked by the ocvalidate this OpenCore
// built, and shipped instead: the repository config's checksum is in
// every manifest, and a default build must keep producing it.
func (b *Builder) EFIImage(ctx context.Context, model string) (string, error) {
	if model == "" {
		model = DefaultSMBIOS
	}
	if !SMBIOSWellformed(model) {
		return "", fmt.Errorf("SMBIOS %q is not a usable model identifier (letters, digits, comma, dot, dash, underscore; 64 at most)", model)
	}
	SMBIOSCheck(model, b.logf)
	config, err := b.config(ctx, model)
	if err != nil {
		return "", err
	}

	art := b.artifactsDir()
	if _, err := os.Stat(art); err != nil {
		return "", fmt.Errorf("no artifacts at %s -- run 'vmavs firmware opencore' first", art)
	}
	if err := verifySums(art); err != nil {
		return "", err
	}
	payload := int64(len(config))
	files := map[string]string{
		"/EFI/BOOT/BOOTx64.efi": filepath.Join(art, "BOOTx64.efi"),
		"/EFI/OC/OpenCore.efi":  filepath.Join(art, "OpenCore.efi"),
	}
	order := []string{"/EFI/BOOT/BOOTx64.efi", "/EFI/OC/OpenCore.efi"}
	for _, d := range EFIDrivers {
		files["/EFI/OC/Drivers/"+d] = filepath.Join(art, d)
		order = append(order, "/EFI/OC/Drivers/"+d)
	}
	for _, p := range order {
		fi, err := os.Stat(files[p])
		if err != nil {
			return "", fmt.Errorf("missing %s -- run 'vmavs firmware opencore'", files[p])
		}
		payload += fi.Size()
	}
	for _, k := range Kexts {
		bundle := filepath.Join(b.kextsDir(), k.Name+".kext")
		if err := checkKext(bundle, k.Name); err != nil {
			return "", fmt.Errorf("%w -- run 'vmavs firmware efi'", err)
		}
		n, err := treeSize(bundle)
		if err != nil {
			return "", err
		}
		payload += n
	}
	if !Fits(EFIImageMiB, payload) {
		return "", fmt.Errorf("a payload of %d bytes does not fit in %d MiB with headroom -- raise EFIImageMiB", payload, EFIImageMiB)
	}
	b.logf("payload is %d bytes; the image is %d MiB", payload, EFIImageMiB)

	fat, err := diskimg.NewFAT("EFI", serial("opencore"))
	if err != nil {
		return "", err
	}
	for _, d := range efiDirs {
		if err := fat.Mkdir(d); err != nil {
			return "", err
		}
	}
	for _, p := range order {
		data, err := os.ReadFile(files[p])
		if err != nil {
			return "", err
		}
		if err := fat.WriteFile(p, data); err != nil {
			return "", err
		}
	}
	if err := fat.WriteFile("/EFI/OC/config.plist", config); err != nil {
		return "", err
	}
	for _, k := range Kexts {
		if err := addTree(fat, filepath.Join(b.kextsDir(), k.Name+".kext"), "/EFI/OC/Kexts/"+k.Name+".kext"); err != nil {
			return "", err
		}
	}

	out := b.Paths.OpenCoreImageOut()
	sum, err := writeImage(out, fat)
	if err != nil {
		return "", err
	}
	if err := writeFileAtomic(out+".sha256", []byte(sum+"\n"), 0o644); err != nil {
		return "", err
	}
	b.logf("built %s (sha256 %s)", out, sum)
	return out, nil
}

// config is the config.plist to ship for model: the repository's,
// verbatim, or a derived copy, validated.
func (b *Builder) config(ctx context.Context, model string) ([]byte, error) {
	base, err := fs.ReadFile(vmguest.Files, "boot/config/config.plist")
	if err != nil {
		return nil, err
	}
	have := ProductName(base)
	if model == have {
		b.logf("smbios: %s, as boot/config/config.plist has it", model)
		return base, nil
	}
	derived, err := SetProductName(base, model)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(b.configDir(), "config-"+model+".plist")
	if err := writeFileAtomic(path, derived, 0o644); err != nil {
		return nil, err
	}
	ocv := b.ocvalidate()
	if fi, err := os.Stat(ocv); err != nil || fi.Mode()&0o111 == 0 {
		ocv, _ = b.Runner.LookPath("ocvalidate")
	}
	if ocv == "" {
		b.logf("warning: no ocvalidate found; shipping the derived config unvalidated")
	} else if err := b.Runner.Run(ctx, proc.Cmd{Name: ocv, Args: []string{path}, Stderr: logWriter{b}}); err != nil {
		return nil, fmt.Errorf("ocvalidate rejected the derived config at %s: %w", path, err)
	} else {
		b.logf("ocvalidate accepts the derived config")
	}
	b.logf("smbios: SystemProductName %s -> %s (%s)", have, model, path)
	b.logf("smbios: serial, board serial, ROM and UUID are unchanged -- OpenCore derives the board id from the product name (Automatic=true)")
	return derived, nil
}

// addTree copies a directory tree into the image, keeping its shape:
// OpenCore reads paths inside a kext bundle, so it must arrive as a
// bundle. Directories come before what is in them (WalkDir's lexical
// order puts a parent first).
func addTree(fat *diskimg.FAT, src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := dst
		if rel != "." {
			target = dst + "/" + filepath.ToSlash(rel)
		}
		switch {
		case d.IsDir():
			return fat.Mkdir(target)
		case d.Type().IsRegular():
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			return fat.WriteFile(target, data)
		}
		return fmt.Errorf("%s: only files and directories can go into the image", p)
	})
}

func treeSize(dir string) (int64, error) {
	var n int64
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		fi, err := d.Info()
		if err == nil {
			n += fi.Size()
		}
		return err
	})
	return n, err
}

// serial is a FAT volume serial number derived from seed, so the image
// is the same every time (mformat's is random).
func serial(seed string) uint32 {
	s := sha256.Sum256([]byte("vmavs fat serial " + seed))
	return binary.LittleEndian.Uint32(s[:4])
}

// writeImage writes a GPT disk of EFIImageMiB with one EFI System
// Partition holding fat, to a temp file beside out, then renames it into
// place: out is never half-written, and a failed build leaves the
// previous image alone. It returns the image's sha256.
func writeImage(out string, fat *diskimg.FAT) (string, error) {
	const sectors = uint64(EFIImageMiB) * 1024 * 1024 / diskimg.SectorSize
	part := diskimg.Partition{Type: diskimg.TypeEFISystem, GUID: diskimg.DerivedGUID("opencore esp"),
		Name: "EFI", FirstLBA: diskimg.AlignLBA, LastLBA: diskimg.LastUsableLBA(sectors)}
	g, err := diskimg.FAT32Geometry(uint32(part.LastLBA-part.FirstLBA+1), uint32(part.FirstLBA))
	if err != nil {
		return "", err
	}
	var sum string
	err = writeAtomicFile(out, func(f *os.File) error {
		if err := f.Truncate(int64(sectors) * diskimg.SectorSize); err != nil {
			return err
		}
		if err := diskimg.WriteGPT(f, sectors, diskimg.DerivedGUID("opencore disk"), []diskimg.Partition{part}); err != nil {
			return err
		}
		if err := fat.WriteTo(f, int64(part.FirstLBA)*diskimg.SectorSize, g); err != nil {
			return err
		}
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return err
		}
		h := sha256.New()
		if _, err := io.Copy(h, f); err != nil {
			return err
		}
		sum = hex.EncodeToString(h.Sum(nil))
		return nil
	})
	return sum, err
}

// writeAtomicFile is writeAtomic for a caller that needs the file itself
// (to Truncate it, WriteAt into it and read it back): a temp file beside
// path, filled, made 0644, synced, closed and renamed; removed on error.
func writeAtomicFile(path string, fill func(*os.File) error) (err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	if err = fill(tmp); err != nil {
		return err
	}
	if err = tmp.Chmod(0o644); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race -count=1 ./internal/firmware/ -v 2>&1 | grep -E '^(--- |FAIL|ok)'`
Expected: PASS, with the `build-efi-image.sh` parity test running here.

- [ ] **Step 5: Commit**

```bash
git add internal/firmware
git commit   # subject: "firmware: the OpenCore EFI image in Go, deterministic, with build-efi-image.sh's layout"
```

---

### Task 12: `vmavs firmware`, the doctor row, and the docs

**Files:**
- Create: `internal/cli/firmware.go`, `internal/cli/firmware_test.go`
- Modify: `internal/cli/cli.go` (the command table), `internal/cli/doctor.go`, `internal/cli/doctor_test.go`
- Modify: `internal/doctor/doctor.go`, `internal/doctor/doctor_test.go`
- Modify: `internal/firmware/pins.go` (`Tools`, `Headers`)
- Modify: `README.md`, `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` (§2, §3, §5)

**Interfaces:**
- Consumes: everything from Tasks 1–11.
- Produces:
  - `vmavs firmware [opencore|ovmf|efi ...] [--smbios MODEL] [--ccache] [--compiler 'NAME VERSION']`
  - `firmware.Tools(gcc string) []string`: `bash make <gcc> git python3 nasm iasl zip`
  - `firmware.Headers = []string{"uuid/uuid.h"}`
  - `doctor.Host.GCCBin string` and `doctor.Host.Header func(name string) bool`.
    A nil `Header` means it is not checked.
  - A `firmware` readiness row from `doctor.Subcommands`.

- [ ] **Step 1: Write the failing tests**

In `internal/cli/firmware_test.go`, `cmdFirmware` reaches the builder
through a variable, so a test can record what it was asked to do:

```go
// in firmware.go
type firmwareBuilder interface {
	OpenCore(ctx context.Context, in firmware.Inputs) ([]string, error)
	OVMF(ctx context.Context) ([]string, error)
	Kexts(ctx context.Context, in firmware.Inputs) ([]string, error)
	EFIImage(ctx context.Context, model string) (string, error)
}

var newFirmwareBuilder = func(b *firmware.Builder) firmwareBuilder { return b }
```

The tests:

1. **`TestFirmwareRunsEveryTargetInOrderByDefault`.**
   - A recording builder notes each call and returns `[<name>-path]`.
   - The registry is a test registry with every
     `firmware.SourceNames()` row served by an httptest server.
   - `vmavs firmware` exits 0. The calls are
     `OpenCore, OVMF, Kexts, EFIImage("")`.
   - Stdout is the returned paths, one per line, in that order.
   - The OpenCore call's `Inputs` hold every `OpenCoreSources()` name;
     the Kexts call's hold every `KextSources()` name.
2. **`TestFirmwareRunsOnlyTheNamedTargetsInTheirOrder`.**
   `vmavs firmware efi opencore` runs OpenCore, then Kexts and
   EFIImage. It fetches no source the named targets do not read: the
   server saw only those requests.
3. **`TestFirmwarePassesItsFlags`.**
   `--smbios MacPro5,1 --ccache --compiler 'gcc 15.1.0'` gives:
   - `EFIImage("MacPro5,1")`;
   - `Builder.Ccache == true`;
   - `Toolchain.Override == "gcc 15.1.0"`;
   - `Toolchain.GCCBin` from `GCC_BIN` in `Getenv`;
   - `Builder.Env` equal to `Env.Environ()`.

   Capture the `*firmware.Builder` in the `newFirmwareBuilder` stub.
4. **`TestFirmwareRefusesBadArguments`.** Each exits 2 with a message:
   - `vmavs firmware bogus`;
   - `vmavs firmware --smbios 'a<b'`;
   - `vmavs firmware --compiler ''`.

   `--compiler` given with an empty value is refused. Leaving the flag
   out means "detect", so the flag's default has to be told apart from
   an explicit `''`: use `fs.Visit` to see whether it was set.
5. **`TestFirmwareHelp`.** `vmavs firmware --help` exits 0. Stdout
   names the three targets, the three flags, and `vmavs fetch firmware`.
6. **`TestFirmwareEFIForReal`.** No stub:
   - The real builder runs, with `Env.Runner` a `proc.Fake` with no
     tools at all.
   - The home already holds `build/artifacts` (five fake files, and a
     `SHA256SUMS` the test writes in `sha256sum` form).
   - The kext zips are served by httptest (generated in the test).
   - `vmavs firmware efi` exits 0 and prints `<home>/build/opencore.img`.
   - The image's GPT has one ESP.
7. **`TestFirmwareOVMFWithoutATreeSaysWhatToRun`.** `vmavs firmware ovmf`
   on an empty home, with a fake gcc banner inside the range, exits 1.
   Stderr contains `run 'vmavs firmware opencore' first`.

In `internal/doctor/doctor_test.go`, add:

1. **`TestDoctorFirmwareRow`.**
   - With every `firmware.Tools("")` tool on the fake `LookPath` and
     `Header` returning true, the `firmware` row is ready.
   - Without `nasm` and `zip`, and with `Header` false, it is blocked.
     `Missing` is `nasm, zip, uuid/uuid.h (a C header: the uuid
     development package)`.
2. **`TestDoctorFirmwareHonoursGCCBin`.** With `GCCBin`
   `x86_64-elf-`, the row looks up `x86_64-elf-gcc`.
3. **The verdict is unchanged.** `GO` still depends only on `run` and
   the host rows. The existing `TestVerdict…` tests still pass.

In `internal/cli/doctor_test.go`, update the expected subcommand list to
include `firmware`, after `fetch`.

- [ ] **Step 2: Run them and watch them fail**

Run: `go test ./internal/cli/ ./internal/doctor/ 2>&1 | head`
Expected: an unknown subcommand, undefined fields.

- [ ] **Step 3: Implement**

`internal/firmware/pins.go` gains:

```go
// Tools is every external program the firmware builds run, for doctor:
// gcc is the Toolchain's GCC() (GCC_BIN-prefixed). bash runs
// edksetup.sh, build_oc.tool and efibuild.sh; git and zip are
// efibuild.sh's own requirements; nasm and iasl are OvmfPkg's.
func Tools(gcc string) []string {
	return []string{"bash", "make", gcc, "git", "python3", "nasm", "iasl", "zip"}
}

// Headers is the C headers the EDK II BaseTools compile against.
var Headers = []string{"uuid/uuid.h"}
```

`internal/doctor/doctor.go`:
- `Host` gains `GCCBin string` and `Header func(name string) bool`.
- `Subcommands` builds a `firmware` readiness from `firmware.Tools(h.GCCBin + "gcc")`
  via `h.LookPath`. Each missing header, when `h.Header != nil`,
  becomes `"<h> (a C header: the uuid development package)"`.
- It has one note:
  `the compiler's range is checked when the build starts (vmavs firmware)`.
- The returned order is `fetch, firmware, run, ssh, emit`.
- `run`'s missing OpenCore image becomes
  `<path> -- vmavs firmware efi`, and its missing OVMF files become
  `<path> -- vmavs firmware ovmf`. Keep the paths first, so the
  existing tests' substring checks still hold.

`internal/cli/doctor.go` fills the two new `Host` fields for the real
host:
- `GCCBin` is `e.Getenv("GCC_BIN")`.
- `Header` runs `<gcc> -fsyntax-only -x c -` through the Runner, with
  stdin `#include <NAME>\nint main(void){return 0;}\n`. It returns
  whether that exited 0. With no gcc on PATH, it returns true and adds
  nothing: the missing gcc is already reported, and "cannot tell" is
  not "missing".

`internal/cli/firmware.go`:

```go
package cli

import (
	"context"
	"flag"
	"fmt"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/firmware"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const firmwareHelp = `usage: vmavs firmware [opencore|ovmf|efi ...] [--smbios MODEL] [--ccache] [--compiler 'NAME VERSION']

Build what the guest boots before its kernel, from pinned source, under
$VMAVS_HOME/build:

  opencore  OpenCore 1.0.7, built with upstream's build_oc.tool against
            acidanthera's EDK II (audk) at its pinned commit
            -> build/artifacts/*.efi
  ovmf      the guest's UEFI firmware, from the same EDK II tree
            -> build/firmware/OVMF_CODE.fd, OVMF_VARS.fd, OVMF.fd
  efi       the OpenCore EFI image: the artifacts, the Lilu and
            VirtualSMC kexts and config.plist on a FAT32 EFI System
            Partition -> build/opencore.img

With no target, all three, in that order. Each output's path is printed
on stdout; progress goes to stderr, and each build's own output to a log
file under build/ named when it starts.

The sources are fetched and verified first, as 'vmavs fetch firmware'
does, adopting the shell tree's downloads where it can; the builds
themselves reach no network. A build tree the shell tree made is built
on, not replaced.

The firmware is reproducible per compiler, not across compilers
(docs/decisions/0004). The host's gcc is judged against the range this
project has evidence for: below it the build stops, above it or unknown
it warns and carries on.
`

// firmwareOrder is the order the targets build in.
var firmwareOrder = []string{"opencore", "ovmf", "efi"}

func cmdFirmware(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("firmware")
	smbios := fs.String("smbios", firmware.DefaultSMBIOS, "the guest's SMBIOS model (SystemProductName); see lib/smbios.sh for what each has been measured to do")
	ccache := fs.Bool("ccache", firmware.CcacheDefault, "compile through ccache, if it is installed (off by default: not yet shown to give the same bytes)")
	compiler := fs.String("compiler", "", "treat the host compiler as 'NAME VERSION' for the range check (the manifest still records the real one)")
	if err := parse(fs, e, firmwareHelp, args); err != nil {
		return err
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if set["compiler"] && strings.TrimSpace(*compiler) == "" {
		return usagef("--compiler needs a value, e.g. --compiler 'gcc 15.1.0'")
	}
	if !firmware.SMBIOSWellformed(*smbios) {
		return usagef("--smbios %q is not a usable SMBIOS model identifier (letters, digits, comma, dot, dash, underscore; 64 at most)", *smbios)
	}
	targets, err := orderedTargets("firmware", fs.Args(), firmwareOrder)
	if err != nil {
		return err
	}

	p, err := paths(e)
	if err != nil {
		return err
	}
	reg := e.Registry
	if reg == nil {
		if reg, err = pins.Embedded(); err != nil {
			return err
		}
	}
	logFW := func(format string, a ...any) { logf(e, "firmware", format, a...) }
	b := &firmware.Builder{
		Paths:     p,
		Registry:  reg,
		Runner:    runner(e),
		Toolchain: firmware.Toolchain{Runner: runner(e), GCCBin: e.Getenv("GCC_BIN"), Override: *compiler},
		Ccache:    *ccache,
		Env:       environ(e),
		Log:       logFW,
	}
	fb := newFirmwareBuilder(b)

	// Fetch what the named targets read, before building anything.
	var names []string
	for _, t := range targets {
		switch t {
		case "opencore":
			names = append(names, firmware.OpenCoreSources()...)
		case "efi":
			names = append(names, firmware.KextSources()...)
		}
	}
	in := firmware.Inputs{}
	if len(names) > 0 {
		g := &fetch.Getter{Paths: p, Client: httpClient(e), Log: func(f string, a ...any) { logf(e, "firmware", f, a...) }}
		legacyBase := ""
		if legacy := config.LegacyHome(e.Getenv); legacy != "" && legacy != p.Home {
			legacyBase = legacy
		}
		for _, n := range names {
			path, err := g.Pinned(ctx, reg, n, adoptCandidates(p, legacyBase, config.Paths.ShellBuild))
			if err != nil {
				return err
			}
			in[n] = path
		}
	}

	for _, t := range targets {
		var out []string
		switch t {
		case "opencore":
			out, err = fb.OpenCore(ctx, in)
		case "ovmf":
			out, err = fb.OVMF(ctx)
		case "efi":
			if out, err = fb.Kexts(ctx, in); err == nil {
				var img string
				img, err = fb.EFIImage(ctx, *smbios)
				out = append(out, img)
			}
		}
		if err != nil {
			return err
		}
		for _, o := range out {
			fmt.Fprintln(e.Stdout, o)
		}
	}
	return nil
}
```

`orderedTargets(cmd string, args, order []string) ([]string, error)`
returns the targets deduplicated in `order`'s order: all of `order` when
`args` is empty, and a `usagef("unknown %s target %q; choose from %s", …)`
otherwise. `cmdFetch`'s `fetchTargets` does the same thing today, so
move it into `cli.go` as this shared helper and make `fetchTargets` call
it. Keep `fetch`'s existing messages: its tests still pass unchanged.

Stdout for `efi` gets the kext bundle paths, then the image. This is
what `TestFirmwareRunsEveryTargetInOrderByDefault` expects: the
recording builder's `Kexts` returns one path and `EFIImage` one more.

Add `{"firmware", "Build OpenCore, OVMF and the OpenCore EFI image from pinned source", cmdFirmware}`
to `commandTable`, after `fetch`.

`README.md`, "The Go vmavs (in progress)":
- Add `vmavs firmware` to the command list, with one sentence per
  target.
- Say that it needs `bash make gcc git python3 nasm iasl zip` and the
  uuid header, that `vmavs doctor` reports any that are missing, and
  that it needs neither `sgdisk` nor mtools.
- Grep the README for `sgdisk` and `mtools`. The shell tree's
  prerequisites are unchanged, so leave its sections alone.

The spec:
- **§2's command block:**
  - `vmavs firmware  [opencore|ovmf|efi ...] [--smbios MODEL] [--ccache] [--compiler 'NAME VERSION']   OpenCore, OVMF and the EFI image, from pinned source`
  - `vmavs fetch     [esd|openssh|updates|firmware] …`
- **§2's Environment bullet:** one sentence saying `MQG_SMBIOS`,
  `MQG_CCACHE` and `MQG_COMPILER` became those flags, and that
  `GCC_BIN`, EDK II's own variable, is still honoured.
- **§3's "External tools that remain":** the EDK II toolchain item
  becomes: `make`, a C compiler, `nasm`, `iasl`, `python3`, and `bash`,
  `git` and `zip`, which upstream's `build_oc.tool`, `efibuild.sh` and
  `edksetup.sh` require. Patches are applied with `git apply`. Add a
  line: `sgdisk`, mtools, `tar`, `unzip` and `curl` are no longer
  needed by the Go path (`internal/diskimg`, `internal/firmware`,
  `internal/fetch`).
- **§5's State block:** the `build/` line gains the OpenCore image
  (`opencore.img`) and says firmware names what is inside it, in the
  shell tree's layout, so either can build on the other's tree.

`grep -n "boot-stack\|sgdisk\|mtools\|firmware" docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`
finds everything that must agree. Change only what this phase made
untrue.

- [ ] **Step 4: Run everything**

Run:
```bash
go vet ./... && go test -race -count=1 ./... && gofmt -l . && \
go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./... && \
for t in linux/amd64 darwin/amd64 darwin/arm64 netbsd/amd64; do GOOS=${t%/*} GOARCH=${t#*/} go build -o /dev/null ./cmd/vmavs || echo FAIL $t; done && \
./bin/run-tests.sh >/tmp/suite.log 2>&1; echo "shell $?"; bin/ingredient-fingerprint.sh | tail -1
```
Expected:
- Go: everything clean, and `gofmt -l` prints nothing;
- `shell 0`;
- the digest is unchanged: `a864536b…aa1d82`.

- [ ] **Step 5: Commit**

```bash
git add internal/cli internal/doctor internal/firmware/pins.go README.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md
git commit   # subject: "vmavs firmware: OpenCore, OVMF and the EFI image from one command; doctor says what the build needs"
```

---

### Task 13: Measure it, and say so

**Files:**
- Modify: `NOTES.md` (append only), `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` (§9's phase-3 row), `README.md` (only if a claim changes)

This task runs the real firmware build twice (about 15 minutes each on
the primary host; INHERITED from `lib/compiler.sh`'s table) and boots a
guest.
- **Network:** all HTTP goes to a dead proxy. Every input is adopted
  from the shell tree's `build/`.
- **The shell tree's home is only read:**
  - adoption and the image links below make hard links *from* it into
    a temp home;
  - `vmavs run` opens the linked image read-only, as a backing file.

  `VMAVS_HOME` is never the shell tree's home (Ruling 7).
- Record `date -u +%FT%TZ` before each step.

- [ ] **Step 1: Build, and make the temp home**

```bash
date -u +%FT%TZ
go build -o out/vmavs ./cmd/vmavs
S=/tmp/claude-1000/-home-schmonz-Documents-trees-mavergreen-vm-guest/62efee50-ef94-4607-99e0-b11c1c28b9ad/scratchpad   # or the session's scratchpad
export X=$(mktemp -d $S/vmavs-p3.XXXXXX)
export DEAD='env -u NO_PROXY -u no_proxy HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9'
```

- [ ] **Step 2: Fetch every firmware source, with no network**

```bash
$DEAD VMAVS_HOME=$X ./out/vmavs fetch firmware
```

Every source is adopted from `~/.local/share/mavericks-qemu-guest/build/`,
and the exit status is 0. Record the count and the time.

- [ ] **Step 3: The shell tree's build, in the temp home, as the reference**

`boot/build-*.sh` read their tarballs from `$MQG_BUILD_DIR/<basename>`.
Hard-link the cache entries there; the scripts only read them. Then run
the shell stages exactly as `image/build-image.sh` does, offline:

```bash
mkdir -p $X/build
for f in $X/cache/*/*; do [ -f "$f" ] && ln "$f" "$X/build/$(basename "$f")"; done
date -u +%FT%TZ
$DEAD MQG_IMAGE_DIR=$X MQG_BUILD_DIR=$X/build ./boot/fetch-opencorepkg.sh
$DEAD MQG_IMAGE_DIR=$X MQG_BUILD_DIR=$X/build ./boot/fetch-kexts.sh
time $DEAD MQG_IMAGE_DIR=$X MQG_BUILD_DIR=$X/build ./boot/build-opencore.sh > $S/p3-shell-opencore.log 2>&1
time $DEAD MQG_IMAGE_DIR=$X MQG_BUILD_DIR=$X/build ./boot/build-ovmf.sh > $S/p3-shell-ovmf.log 2>&1
$DEAD MQG_IMAGE_DIR=$X MQG_BUILD_DIR=$X/build ./boot/build-efi-image.sh $X/work/opencore-shell.img
cat $X/build/artifacts/SHA256SUMS $X/build/firmware/SHA256SUMS > $S/p3-shell-sums.txt
```

Then move the shell's outputs aside, so the Go build starts cold in the
same directory. EDK II writes the build directory into the PE images,
so the same path is what makes the bytes comparable (INHERITED from
`lib/ccache.sh`'s note). Everything removed here was created in this
temp home by the commands above:

```bash
rm -rf $X/build/OpenCorePkg-1.0.7 $X/build/artifacts $X/build/firmware $X/build/kexts
```

- [ ] **Step 4: The Go build, cold, in the same place**

```bash
date -u +%FT%TZ
time $DEAD VMAVS_HOME=$X ./out/vmavs firmware 2> $S/p3-go.log
cat $X/build/artifacts/SHA256SUMS $X/build/firmware/SHA256SUMS > $S/p3-go-sums.txt
diff $S/p3-shell-sums.txt $S/p3-go-sums.txt && echo "all eight byte-identical"
```

Record the times and the eight checksums.
- Expected (REASONED): identical, if both builds ran on the same UTC
  day. `OpenCore.efi` embeds its build date, so a build that crosses
  midnight differs in those bytes and nothing else (`lib/ccache.sh`).
- Any other difference is a finding. Record it as it is: the file, the
  bytes, and what differs. Do not work around it.

Then compare the two EFI images structurally with a throwaway Go test
file (run it with `go test`, then delete it). It opens both with
`diskimg.ReadGPT`/`OpenFAT` and prints:
- the partition bounds;
- the geometry;
- the walked paths;
- per-file equality.

Expected: the same partition, geometry apart from hidden sectors, and
the same files and bytes (Ruling 5 names the rest). Record
`sha256sum $X/build/opencore.img`.

- [ ] **Step 5: Boot an existing guest on the Go-built firmware**

Link the most recent shell-built image and its manifest into the temp
home. `vmavs run` opens the qcow2 read-only, as a backing file; its
overlay goes in `$X/run`:

```bash
L=$HOME/.local/share/mavericks-qemu-guest
name=$(ls -t $L/images/*.manifest | head -1 | xargs basename | sed 's/\.manifest$//')
mkdir -p $X/images
stat -c '%n %s %Y %i' $L/images/$name.qcow2 $L/images/$name.manifest | tee $S/p3-image-before.txt
ln $L/images/$name.qcow2 $L/images/$name.manifest $X/images/
date -u +%FT%TZ
VMAVS_HOME=$X ./out/vmavs run --image $name > $S/p3-run.log 2>&1 &
run=$!
for i in $(seq 1 60); do VMAVS_HOME=$X ./out/vmavs ssh -- sw_vers && break; sleep 10; done
date -u +%FT%TZ
kill -TERM $run; wait $run
stat -c '%n %s %Y %i' $L/images/$name.qcow2 $L/images/$name.manifest | diff $S/p3-image-before.txt - && echo "originals unchanged"
```

`vmavs ssh` needs the key the image authorized. If it is not found by
the default search, set `VMAVS_SSH_KEY` to the one the shell tree uses
(`lib/sshkey.sh`'s order) and record which.

Expected: `sw_vers` prints `10.9.5` within about a minute (phase 1
MEASURED 71 s on shell-built firmware), and the originals are
unchanged.
- If it does not boot, that is a finding, not something to fix here.
  Take a screenshot through the QEMU monitor if the run directory
  allows, and record exactly what was seen.
- Afterwards remove `$X/images` (the hard links this step made) and
  `$X/run` if it is left.

- [ ] **Step 6: NOTES.md, and the spec**

Append a dated entry (the date from Step 1) in NOTES.md's format:
`## <date> — P8 — vmavs firmware builds the boot stack, and a guest boots on it`.
It records:
- **Steps 2–5, verbatim, labelled MEASURED:**
  - times;
  - the eight checksums from each build, and whether they matched;
  - the image's sha256;
  - the structural comparison;
  - the boot time and the `sw_vers` output.
- **The parity tests (Tasks 2, 5, 6, 7, 8, 11):** which ran, and what
  each compared.
- **What was not measured:**
  - a guest *installed* using Go-built firmware (phase 5);
  - a host other than this one;
  - a compiler other than gcc 13.3.0;
  - ccache (absent here).

In spec §9's table, mark phase 3 `delivered <date>`, with a pointer to
that NOTES entry. Before marking it, quote the phase-3 row
(`firmware`, `diskimg`) and check each item against what shipped.

- [ ] **Step 7: Run everything; commit**

```bash
go test -race ./... && ./bin/run-tests.sh >/tmp/suite.log 2>&1; echo "shell $?"; bats tests/release.bats; bin/ingredient-fingerprint.sh | tail -1
git add NOTES.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md README.md
git commit   # subject: "NOTES: vmavs firmware builds the boot stack byte for byte, and a guest boots on it"
```

---

## Self-review

**Spec coverage** (spec §9, phase 3 row: `firmware`, `diskimg`):

| Requirement | Covered by |
|---|---|
| `firmware/`: OpenCore and OVMF builds (orchestrate make/gcc/nasm/iasl), compiler and ccache checks, EFI image assembly (§3) | Tasks 5, 9, 10, 11 |
| `diskimg/`: GPT and FAT32 writers, replacing sgdisk and mtools (§3) | Tasks 7, 8 |
| `fetch/`: kexts, edk2, opencorepkg (§3) | Task 3 |
| `vmavs firmware` (§2, renamed from `boot-stack`) | Task 12 |
| embedded `config.plist` and patches (§3) | Task 1; `config.plist` since phase 2 |
| golden/structural tests for GPT/FAT images (§7) | structural: Tasks 7, 8, 11; golden bytes (the images' sha256 and DerivedGUID's known answers, which no task delivered): the final fix wave's `internal/diskimg/golden_test.go` and `TestEFIImageIsDeterministic` |
| parity tests with the shell tree, differences named (§7) | Tasks 2, 5, 6, 7, 8, 11 |
| carrying the bats knowledge (§7) | the mapping table above |
| `doctor` reports the tools, derived from the code (§3) | Task 12 (`firmware.Tools`) |
| measurement (§10's discipline) | Task 13 |

**Out of phase:**
- The installer media's HFS+ GPT (`lib/hfs.sh`): phase 4. It will use
  `diskimg.TypeAppleHFS` and `WriteGPT`.
- The stage freshness and the manifest's `compiler`, `compiler-range`,
  `ccache`, `build-options`, `smbios` and `opencore` rows: phase 5.
  `firmware` exposes every value they need.
- Per-build NVRAM copies (`make-nvram.sh`): phase 5. Per-run copies are
  phase 1's `vm` package.
- `prereqs.sh`'s package-name table: stays in the shell tree until
  phase 6.

**Types:**
- `Builder`, `Inputs` and the helpers are introduced in Task 9 and used
  by Tasks 10–12.
- `untarGz`/`extractKext` come from Task 4, and are used by Tasks 9 and
  11.
- `Toolchain`, `CcacheVerdict` and `writeCcacheShims` come from Task 5,
  and are used by Tasks 9, 10 and 12.
- `SMBIOSWellformed`, `SetProductName`, `ProductName` and `SMBIOSCheck`
  come from Task 6, and are used by Tasks 11 and 12.
- `WriteGPT`, `ReadGPT`, `LastUsableLBA`, `AlignLBA`, `TypeEFISystem`
  and `DerivedGUID` come from Task 7. `NewFAT`, `FAT32Geometry` and
  `OpenFAT` come from Task 8. Both are used by Task 11.
- `Getter.Pinned` and `Paths.ShellBuild` come from Task 3, and are used
  by Task 12.
- `Paths.OpenCoreImageOut`, `Cmd.Env` and `Env.Environ` come from
  Task 1, and are used by Tasks 9, 11 and 12.
