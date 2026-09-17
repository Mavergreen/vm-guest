# Brief: OS X 10.9 smoke-test VM for GitHub Actions (QEMU TCG on arm64 macOS runners)

## Goal
A reusable GitHub Actions workflow that runs smoke tests and other validation (and, rarely, a single native build step) inside an OS X 10.9 guest. The guest runs under QEMU TCG on GitHub's arm64 macOS runners. It is used **sparingly**: release tags, a nightly/weekly schedule, manual dispatch, or a PR label. Never on every push. The goal is added assurance with as little Mavericks in the pipeline as possible.

## Context and constraints (verify anything marked "believed")
- **Prerequisite:** the separate Linux/KVM bring-up brief (`mavericks-qemu-brief.md`) has produced a working 10.9 guest configuration (OVMF + OpenCore + QEMU flags). Reuse it. Don't redo that work unless TCG forces changes; log any changes.
- **Why an arm64 Mac host:**
  - Apple's license permits macOS/OS X VMs only on Apple hardware running macOS.
  - GitHub's Intel macOS labels are ending (GitHub has said x86_64 macOS support ends in 2027). arm64 is the long-term host.
  - arm64 has no x86 hardware virtualization, so the guest runs under TCG.
- **Runner budget** (arm64 macOS standard runner: `macos-14`, `macos-15`, `macos-latest`, `macos-26`): 3 M1 cores, 7 GB RAM, 14 GB SSD. Everything must fit.
- **Jobs are capped at 6 hours** (believed).
- **Cache limits** (believed): `actions/cache` evicts entries not accessed in 7 days and has a per-repo quota, 10 GB by default. Occasional use is exactly the pattern that gets evicted.
- **Reference timing:** khronokernel measured a TCG boot to macOS recovery on an M1 at 17 min, and 8 min with forced multicore (`-accel tcg,thread=multi`), with a warning that multicore can cause bugs. https://khronokernel.com/apple/silicon/2021/01/17/QEMU-AS.html
- **Kostarelas** (https://adam.kostarelas.com/blog/mavericks-in-utm-on-silicon/) installed 10.9 successfully under UTM/TCG on Apple Silicon: 8 GB assigned, about 2.9 GB used at idle, graphics very slow. Graphics don't matter here; the guest runs headless over SSH.
- **No distribution:** never publish the guest image or snapshot publicly, as a release asset, public package, or anything else.

## Ground rules
- Study and reuse prior art before inventing anything: QEMU docs (snapshots, TCG, qcow2 backing files), the two posts above, vmactions/anyvm's workflow shape (boot, sync files in, run over SSH, sync back), and timsutton/osx-vm-templates' first-boot automation payload (user creation, SSH, skipping Setup Assistant).
- If you can't fetch a source, say so. Don't guess.
- Pin everything that affects snapshot compatibility, and record the exact versions and checksums in `NOTES.md`.
- Ask before using `sudo`, installing host packages, creating GitHub secrets, or pushing to any repo.
- Log every attempt, timing, and failure in `NOTES.md`.

## Phase 1: Local proof on an Apple Silicon Mac
1. **Pin QEMU.**
   - Build a specific QEMU release yourself. pkgsrc on macOS arm64 is the preferred route; building straight from source is acceptable. Don't depend on Homebrew's floating version.
   - Record the version, build options, and the binary's checksum.
2. **Build the base image under TCG** with the proven configuration:
   - Fixed `-machine pc-q35-X.Y`, never the unversioned alias.
   - A `-cpu` model matching the **oldest hardware we intend to support**; ask the user which. Record it.
   - Guest RAM at most about 4 GB, to leave headroom on a 7 GB runner. Find the smallest that works reliably.
   - Headless: no display dependency, serial console where possible, SSH for control.
   - Install unattended if practical, adapting osx-vm-templates' payload. At minimum the finished image must have: a CI user with key-based SSH, Setup Assistant skipped, sleep/screensaver/software update disabled, and a correct clock.
   - Record wall-clock install time.
3. **Trim and compact.**
   - Remove unneeded languages and apps, zero free space, then `qemu-img convert -c` to produce a compressed qcow2 base.
   - Record the size. The target: compressed download + base image + job overlay + test artifacts all fit comfortably in 14 GB.
4. **Test multicore TCG.**
   - Compare `thread=single` against `thread=multi` for boot time and stability over at least 10 boots each.
   - Pick one and pin it. Record the evidence.
5. **Test snapshots.**
   - Boot to an idle, logged-in, SSH-ready state, then `savevm ci-ready`.
   - Confirm `loadvm ci-ready` restores reliably across at least 10 cycles.
   - After each restore, verify: SSH works, the guest clock is correct (resync it after restore if not), and outbound network works through QEMU's user-mode networking (slirp).
   - Every job uses a throwaway qcow2 overlay on the base; the base is never written.
6. **Test CPU-model gating.**
   - Compile and run a test binary that uses an instruction set the chosen `-cpu` model doesn't advertise (e.g. AVX).
   - Confirm it faults (SIGILL) instead of silently running. If TCG runs it anyway, report that clearly: it changes what the smoke tests can promise.

**Stop and report after Phase 1** with timings, sizes, and stability numbers. If the snapshot round-trip (step 5) is unreliable, say so plainly; it decides whether the design is viable.

## Phase 2: Storage for the image
- Implement both options below and recommend one, with evidence:
  - **A: `actions/cache`**, plus a scheduled keep-alive job that restores the cache often enough to avoid eviction. Measure how long a restore takes and how many GB it downloads.
  - **B: user-controlled storage.** An authenticated HTTPS endpoint the user specifies; the credentials come from the user as a repo secret. Fetch per job, verify the checksum, and cache locally within the job if that helps.
- **The cache/storage key** must cover: QEMU version and build, machine type, CPU model, OVMF and OpenCore checksums, installer checksum, and image build revision.
- The pinned QEMU build is itself a cached or fetched artifact, not rebuilt per job.

## Phase 3: Runner proof
- On a `macos-15` runner, fetch the pinned QEMU and the image, then `loadvm ci-ready`, SSH in, and run `sw_vers` and `uname -a`.
- Record the timings of every step: download, decompression, restore, SSH-ready.
- Confirm the job runs within the 7 GB RAM and 14 GB disk limits; log `df` and memory pressure.
- If the runner can't restore the snapshot made locally, report exactly why. Fallbacks, in order:
  1. rebuild the snapshot on the runner in a dedicated job;
  2. cold boot on every job, with the cost measured.

## Phase 4: Reusable workflow
- Create `.github/workflows/mavericks-smoke.yml` with `on: workflow_call`. Inputs:
  - the name of an artifact built elsewhere, to copy into the guest;
  - a smoke-test script path, to run in the guest;
  - optional timeout and guest RAM overrides.
- Steps: restore QEMU and the image, create the overlay, `loadvm`, copy files in, run the script over SSH with a timeout, copy logs and results back out, upload them as artifacts, shut down.
- Retry the boot/restore step once on failure. Test failures inside the guest are never retried.
- Provide an example caller workflow triggered by release tags, a schedule, `workflow_dispatch`, and a PR label (e.g. `needs-mavericks`). Callers start with `continue-on-error: true`.
- Provide example smoke tests:
  - install a built package, run a binary's `--version`, check `otool -L` output for unexpected dylibs;
  - a real TLS handshake to a public HTTPS host using the project's own TLS stack;
  - the CPU-gating check from Phase 1.
- Keep all the logic in scripts under `ci/mavericks/` so it runs identically on a local Mac. The workflow YAML only calls those scripts.
- If the pieces separate cleanly, also package them as a composite action (`ci/mavericks/action.yml`).

## Deliverables
- **Scripts in `ci/mavericks/`:** `build-qemu.sh`, `build-base-image.sh`, `make-snapshot.sh`, `fetch-image.sh`, `boot.sh`, `run-in-guest.sh`, `shutdown.sh`, `cpu-gating-test/`.
- **Workflows:** `mavericks-smoke.yml` (reusable), an example caller, the image keep-alive job (if option A), and a runner proof workflow.
- **`NOTES.md`** covering: pinned versions and checksums, every timing and size measurement, the stability results, and the storage recommendation.
- **A final report covering:**
  - typical per-job wall-clock time;
  - which failure modes were seen and how they're handled;
  - what the setup can and cannot assure. It can't assure timing, real drivers/GPU, or hardware quirks; release sign-off still needs a real Mavericks Mac.
  - every assumption that would break if GitHub changes the runner specs, or if the pinned QEMU needs replacing.

## Stop and ask if
- Phase 1's snapshot round-trip is unreliable, or the install doesn't fit the runner's limits.
- TCG doesn't enforce CPU-model gating.
- A storage option would require making the image publicly reachable.
- A single smoke-test job can't reliably finish in under about 30 minutes. Report the breakdown before optimizing further.
- Three materially different attempts at the same step all fail.
