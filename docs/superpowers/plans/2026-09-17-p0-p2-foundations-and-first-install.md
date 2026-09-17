# Mavericks Guest P0–P2: Foundations, Known-Good Boot, First Install

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the scripted foundation for the project, boot the Mavericks installer under KVM using the one configuration known to have worked, and complete one instrumented manual install that produces the first golden image and the click-log that later automation will follow.

**Architecture:** A small library of POSIX-ish bash modules (`lib/`) under bats tests, driving thin executable scripts (`bin/`, `vm/`, `boot/`, `media/`). QEMU configurations live as plain-text *profiles* — one argument per line, composable by `@include` — so that "change one variable at a time" is a diffable file change rather than a remembered shell edit. Disk images are managed as read-only checksummed *goldens* with qcow2 overlay *clones*, so every experiment is disposable from the first install attempt onward.

**Tech Stack:** bash, bats-core 1.10, shellcheck 0.9, QEMU 8.2.2 + KVM, qemu-img, Python 3 `plistlib`, OVMF (Debian `ovmf` 2024.02), OpenCore (reference images in P1; built from source in P3).

**Already verified:** the library code in Tasks 2, 5, and 7 was linted clean and run against its own test cases before this plan was written — profile expansion (whitespace, comments, mid-line hashes, `@include`, cycle detection, `%REPO%`) and the full golden promote/clone/verify round-trip against real `qemu-img`. It should work as written. If it does not, that is a bug worth understanding rather than papering over.

**Read first:** `docs/superpowers/specs/2026-09-17-mavericks-guest-design.md`, `docs/prior-art.md`, `docs/host-profile.md`.

---

## Scope

This plan covers phases **P0, P1, and P2** of the umbrella design. It stops at
golden #1.

It does **not** cover P3 (reproducible boot stack), P4 (unattended pipeline),
P5 (performance), P6 (GitHub Actions), or P7 (guest integration). Those get
their own plans once their prerequisites exist.

## A note on what can and cannot be test-driven

Tasks 1–9 are ordinary software with real tests: text processing, checksum
handling, argument composition, image management. TDD applies literally.

Tasks 10–14 involve booting an operating system and clicking through a GUI
installer. They cannot be test-driven, and pretending otherwise would produce
a plan that lies. They are written instead as **procedures with recording
obligations**: exact commands, explicit decision trees for the failure modes
prior art predicts, and a requirement that every attempt lands in `NOTES.md`
whether it worked or not. The deliverable of a manual task is the record as
much as the result.

## File structure

| Path | Responsibility |
|---|---|
| `lib/common.sh` | Logging, fatal errors, command checks, SHA-256 helpers. Sourced by everything. No side effects on source. |
| `lib/vendor.sh` | The third-party artifact registry: read `vendor/sources.tsv`, fetch, verify or pin checksums. |
| `lib/profile.sh` | Profile expansion: comments, `@include` resolution with cycle detection, `%REPO%` substitution. |
| `lib/golden.sh` | Golden image promotion, listing, verification, path resolution. |
| `bin/preconditions.sh` | Host go/no-go check. Prints a table, exits non-zero on any FAIL. |
| `bin/run-tests.sh` | Runs the bats suite, plus shellcheck. Skips shellcheck gracefully on hosts that lack it. |
| `bin/tier-check.sh` | Reports which profiles reference the Tier 2 quarantine. Becomes a hard gate in P3. |
| `vm/run.sh` | Expands a profile and execs QEMU. Appends every invocation to the run log. |
| `vm/clone.sh` | Creates a qcow2 overlay over a golden. |
| `vm/golden.sh` | CLI wrapper over `lib/golden.sh`. |
| `vm/profiles/*.args` | One QEMU configuration each, with a provenance comment. |
| `boot/fetch-reference.sh` | Downloads Tier 2 reference artifacts into the quarantine. |
| `boot/inspect-utm-bundle.py` | Parses a UTM `config.plist` into Markdown. |
| `media/import-reference-dmg.sh` | Converts the Mac-produced installer dmg to a raw image and registers it. |
| `tests/*.bats` | One test file per library module. |
| `vendor/sources.tsv` | name, URL, SHA-256 (or `TOFU`) for every third-party artifact. |
| `vendor/reference/` | Tier 2 quarantine. Contents gitignored. |

---

## Task 1: Repository skeleton and test runner

**Files:**
- Create: `.gitignore`
- Create: `bin/run-tests.sh`
- Create: `tests/smoke.bats`
- Create: `vendor/reference/.gitignore`

- [ ] **Step 1: Write the failing test**

Create `tests/smoke.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "repository has the expected top-level directories" {
    for d in lib bin tests vm vm/profiles boot media vendor docs; do
        [ -d "$REPO/$d" ] || { echo "missing directory: $d"; return 1; }
    done
}

@test "the Tier 2 quarantine ignores its own contents" {
    [ -f "$REPO/vendor/reference/.gitignore" ]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/smoke.bats`

Expected: FAIL — `missing directory: lib`.

- [ ] **Step 3: Create the skeleton**

```bash
mkdir -p lib bin tests vm/profiles boot media vendor/reference bench
```

Create `vendor/reference/.gitignore` — the quarantine is tracked as a
directory but its contents never are:

```gitignore
# Tier 2 quarantine: third-party blobs we cannot rebuild.
# De-risking scaffolding only; never shipped. See docs/decisions/ and the
# provenance-tier rule in the umbrella design.
*
!.gitignore
```

Create `.gitignore` at the repository root:

```gitignore
# Disk images are large and, in the case of guest images, must never be
# published. See the "never publish the guest image" rule in the design.
golden/
work/
vendor/cache/
*.qcow2
*.img
*.dmg
*.iso
*.zip

# Run log: machine-generated, append-only, noisy.
run.log
```

- [ ] **Step 4: Write the test runner**

Create `bin/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Run the whole test suite. shellcheck is optional: it is not installed on
# every host, and needing a package install to run tests is a bad trade.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

status=0

echo "== bats =="
if ! bats tests/; then
    status=1
fi

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    # SC1091: shellcheck cannot follow dynamically-computed source paths.
    if ! shellcheck -e SC1091 \
        lib/*.sh bin/*.sh vm/*.sh boot/*.sh media/*.sh 2>/dev/null; then
        status=1
    fi
else
    echo "shellcheck not installed; skipping."
    echo "To enable: sudo apt install shellcheck  (requires an ask)"
fi

exit "$status"
```

Make it executable: `chmod +x bin/run-tests.sh`

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./bin/run-tests.sh`

Expected: both smoke tests pass; shellcheck runs and reports nothing; exit
status 0.

- [ ] **Step 6: Commit**

```bash
git add .gitignore bin/run-tests.sh tests/smoke.bats vendor/reference/.gitignore
git commit -m "Add repository skeleton and test runner

shellcheck is optional rather than required: it is not installed here,
and making the test suite depend on a package install would mean asking
permission before anyone can run tests.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `lib/common.sh`

**Files:**
- Create: `lib/common.sh`
- Test: `tests/common.bats`

Note on a deliberate choice: `common.sh` does **not** run `set -euo pipefail`
when sourced. A library that changes the caller's shell options is a library
that behaves differently depending on who sourced it, and it makes bats tests
awkward. Each executable script sets its own options.

- [ ] **Step 1: Write the failing test**

Create `tests/common.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
}

@test "sha256_file computes a known checksum" {
    printf 'hello\n' > "$BATS_TEST_TMPDIR/f"
    run sha256_file "$BATS_TEST_TMPDIR/f"
    [ "$status" -eq 0 ]
    [ "$output" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}

@test "sha256_file fails loudly on a missing file" {
    run sha256_file "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file"* ]]
}

@test "verify_sha256 accepts a matching checksum" {
    printf 'hello\n' > "$BATS_TEST_TMPDIR/f"
    run verify_sha256 "$BATS_TEST_TMPDIR/f" \
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    [ "$status" -eq 0 ]
}

@test "verify_sha256 rejects a mismatching checksum and names both values" {
    printf 'hello\n' > "$BATS_TEST_TMPDIR/f"
    run verify_sha256 "$BATS_TEST_TMPDIR/f" "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
    [[ "$output" == *"5891b5b5"* ]]
}

@test "require_cmd succeeds for commands that exist" {
    run require_cmd sh cat
    [ "$status" -eq 0 ]
}

@test "require_cmd fails and names the missing command" {
    run require_cmd sh definitely-not-a-real-command-xyz
    [ "$status" -ne 0 ]
    [[ "$output" == *"definitely-not-a-real-command-xyz"* ]]
}

@test "die exits non-zero with its message on stderr" {
    run die "the thing broke"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the thing broke"* ]]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/common.bats`

Expected: FAIL — every test errors because `lib/common.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/common.sh`:

```bash
# shellcheck shell=bash
# Shared helpers. Sourced, never executed.
#
# Deliberately does not set shell options: a library that mutates the
# caller's environment behaves differently depending on who sourced it.

: "${MQG_LOG_PREFIX:=mqg}"

log()  { printf '%s: %s\n'            "$MQG_LOG_PREFIX" "$*" >&2; }
warn() { printf '%s: warning: %s\n'   "$MQG_LOG_PREFIX" "$*" >&2; }
die()  { printf '%s: error: %s\n'     "$MQG_LOG_PREFIX" "$*" >&2; exit 1; }

# Absolute path of the repository root, derived from this file's location.
repo_root() {
    ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
}

# Fail if any named command is missing, naming all of them rather than
# stopping at the first.
require_cmd() {
    local missing=0 c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            warn "missing required command: $c"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "missing required commands"
}

sha256_file() {
    [ -f "$1" ] || die "no such file: $1"
    sha256sum "$1" | cut -d' ' -f1
}

# Verify a file against an expected checksum. Reports both values, because
# "checksum mismatch" without the numbers is useless when debugging a
# partial download.
verify_sha256() {
    local file=$1 want=$2 got
    got=$(sha256_file "$file") || exit 1
    if [ "$got" != "$want" ]; then
        die "checksum mismatch for $file: want $want, got $got"
    fi
}

# Append a timestamped line to the run log. Every QEMU invocation goes
# through this, so the lab log never depends on anyone remembering.
run_log() {
    local root
    root=$(repo_root)
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$root/run.log"
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/common.bats`

Expected: 7 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/common.bats
git commit -m "Add lib/common.sh: logging, command checks, checksums

verify_sha256 reports both the wanted and the got value. A bare
'checksum mismatch' tells you nothing when you are trying to work out
whether a download truncated.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `lib/vendor.sh` — the third-party artifact registry

**Files:**
- Create: `lib/vendor.sh`
- Create: `vendor/sources.tsv`
- Test: `tests/vendor.bats`

**Design note — trust on first use.** We cannot know the checksum of
Kostarelas's UTM bundle before downloading it; nobody has published one. So a
source may record `TOFU` instead of a checksum. On first fetch the script
computes the checksum, writes it into `vendor/sources.tsv`, and tells the
operator to commit that change. Every later fetch is pinned. This is honest
about what is actually being trusted — the download, once — rather than
pretending to a verification we cannot perform.

- [ ] **Step 1: Write the failing test**

Create `tests/vendor.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/vendor.sh"
    SOURCES="$BATS_TEST_TMPDIR/sources.tsv"
    printf '%s\n' \
        '# name	url	sha256' \
        'thing	https://example.invalid/thing.zip	abc123' \
        'untrusted	https://example.invalid/other.zip	TOFU' \
        > "$SOURCES"
}

@test "source_field returns the url for a known source" {
    run source_field "$SOURCES" thing url
    [ "$status" -eq 0 ]
    [ "$output" = "https://example.invalid/thing.zip" ]
}

@test "source_field returns the recorded checksum" {
    run source_field "$SOURCES" thing sha256
    [ "$status" -eq 0 ]
    [ "$output" = "abc123" ]
}

@test "source_field fails for an unknown source" {
    run source_field "$SOURCES" nosuch url
    [ "$status" -ne 0 ]
    [[ "$output" == *"nosuch"* ]]
}

@test "source_field ignores comment lines" {
    run source_field "$SOURCES" '#' url
    [ "$status" -ne 0 ]
}

@test "pin_checksum replaces TOFU with a real checksum in place" {
    run pin_checksum "$SOURCES" untrusted deadbeef
    [ "$status" -eq 0 ]
    run source_field "$SOURCES" untrusted sha256
    [ "$output" = "deadbeef" ]
}

@test "pin_checksum refuses to overwrite an already-pinned checksum" {
    run pin_checksum "$SOURCES" thing deadbeef
    [ "$status" -ne 0 ]
    [[ "$output" == *"already pinned"* ]]
    run source_field "$SOURCES" thing sha256
    [ "$output" = "abc123" ]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/vendor.bats`

Expected: FAIL — `lib/vendor.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/vendor.sh`:

```bash
# shellcheck shell=bash
# The third-party artifact registry.
#
# vendor/sources.tsv is tab-separated: name, url, sha256. A sha256 of TOFU
# means "not yet known" -- see the trust-on-first-use note in the plan.
#
# Requires lib/common.sh to be sourced first.

# source_field <tsv> <name> <url|sha256>
source_field() {
    local tsv=$1 name=$2 field=$3 line url sha
    [ -f "$tsv" ] || die "no such sources file: $tsv"
    case $name in
        '#'*|'') die "invalid source name: $name" ;;
    esac
    line=$(awk -F'\t' -v n="$name" \
        '$0 !~ /^#/ && $1 == n { print; exit }' "$tsv")
    [ -n "$line" ] || die "no such source: $name"
    url=$(printf '%s' "$line" | cut -f2)
    sha=$(printf '%s' "$line" | cut -f3)
    case $field in
        url)    printf '%s\n' "$url" ;;
        sha256) printf '%s\n' "$sha" ;;
        *)      die "unknown field: $field" ;;
    esac
}

# pin_checksum <tsv> <name> <sha256>
# Only ever promotes TOFU to a real value. Refuses to change a pinned one,
# because a checksum that silently changes is the whole problem.
pin_checksum() {
    local tsv=$1 name=$2 sha=$3 current tmp
    current=$(source_field "$tsv" "$name" sha256) || exit 1
    if [ "$current" != "TOFU" ]; then
        die "source $name is already pinned to $current; refusing to change it"
    fi
    tmp=$(mktemp)
    awk -F'\t' -v OFS='\t' -v n="$name" -v s="$sha" \
        '$0 !~ /^#/ && $1 == n { $3 = s } { print }' "$tsv" > "$tmp"
    mv "$tmp" "$tsv"
}

# fetch_source <tsv> <name> <destdir>
# Downloads if absent, then verifies. On TOFU, pins and tells the operator
# to commit.
fetch_source() {
    local tsv=$1 name=$2 destdir=$3 url sha dest got
    url=$(source_field "$tsv" "$name" url) || exit 1
    sha=$(source_field "$tsv" "$name" sha256) || exit 1
    mkdir -p "$destdir"
    dest="$destdir/$(basename "$url")"

    if [ ! -f "$dest" ]; then
        log "fetching $name from $url"
        curl -fSL --retry 3 -o "$dest.part" "$url" \
            || die "download failed for $name"
        mv "$dest.part" "$dest"
    else
        log "$name already present at $dest"
    fi

    if [ "$sha" = "TOFU" ]; then
        got=$(sha256_file "$dest")
        pin_checksum "$tsv" "$name" "$got"
        warn "pinned $name to $got on first use"
        warn "review and commit the change to $tsv"
    else
        verify_sha256 "$dest" "$sha"
        log "$name verified against pinned checksum"
    fi

    printf '%s\n' "$dest"
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/vendor.bats`

Expected: 6 tests, all passing.

- [ ] **Step 5: Create the sources file with what we know**

The URLs below are **not yet confirmed**. Task 10 confirms them against the
live pages before anything is fetched; do not invent them here.

Create `vendor/sources.tsv`:

```tsv
# Third-party artifacts. Tab-separated: name, url, sha256.
#
# sha256 of TOFU means "not yet known" -- the checksum is computed and
# pinned on first fetch, and the change is committed deliberately.
#
# Tier 2 entries land in vendor/reference/ and must never be referenced by
# a shipped profile or by the image pipeline. See bin/tier-check.sh.
#
# URLs marked CONFIRM-IN-TASK-10 have not been verified against the live
# page. Confirm them before fetching; do not guess.
#
# name	url	sha256
utm-bundle	CONFIRM-IN-TASK-10	TOFU
opencore-legacy-img	CONFIRM-IN-TASK-10	TOFU
```

- [ ] **Step 6: Commit**

```bash
git add lib/vendor.sh tests/vendor.bats vendor/sources.tsv
git commit -m "Add the third-party artifact registry

Checksums use trust-on-first-use: nobody has published a checksum for
Kostarelas's UTM bundle, so claiming to verify it in advance would be a
lie. TOFU records what is actually being trusted -- the download, once --
and pins it thereafter. pin_checksum refuses to change an already-pinned
value, since a checksum that quietly changes is the problem it exists to
catch.

URLs are placeholders until confirmed against the live pages.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `bin/preconditions.sh` — the host go/no-go check

**Files:**
- Create: `lib/preconditions.sh`
- Create: `bin/preconditions.sh`
- Test: `tests/preconditions.bats`

The checking logic lives in a library so it can be tested against synthetic
inputs; the executable is a thin shell around it. Testing "is KVM available"
by actually checking this host would be a test that passes for the wrong
reason.

- [ ] **Step 1: Write the failing test**

Create `tests/preconditions.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/preconditions.sh"
}

@test "check_result formats a pass row" {
    run check_result PASS "kvm" "/dev/kvm is writable"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"kvm"* ]]
}

@test "cpu_vendor_verdict passes for GenuineIntel" {
    run cpu_vendor_verdict "GenuineIntel"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS* ]]
}

@test "cpu_vendor_verdict fails for AuthenticAMD and explains why" {
    run cpu_vendor_verdict "AuthenticAMD"
    [ "$status" -eq 0 ]
    [[ "$output" == FAIL* ]]
    [[ "$output" == *"AMD"* ]]
}

@test "ignore_msrs_verdict passes when set to Y" {
    run ignore_msrs_verdict "Y"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS* ]]
}

@test "ignore_msrs_verdict warns when set to N and says it needs sudo" {
    run ignore_msrs_verdict "N"
    [ "$status" -eq 0 ]
    [[ "$output" == WARN* ]]
    [[ "$output" == *"sudo"* ]]
}

@test "ovmf_verdict passes when both code and vars are present" {
    mkdir -p "$BATS_TEST_TMPDIR/OVMF"
    touch "$BATS_TEST_TMPDIR/OVMF/OVMF_CODE_4M.fd" \
          "$BATS_TEST_TMPDIR/OVMF/OVMF_VARS_4M.fd"
    run ovmf_verdict "$BATS_TEST_TMPDIR/OVMF"
    [ "$status" -eq 0 ]
    [[ "$output" == PASS* ]]
}

@test "ovmf_verdict fails when the directory is empty" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run ovmf_verdict "$BATS_TEST_TMPDIR/empty"
    [ "$status" -eq 0 ]
    [[ "$output" == FAIL* ]]
}

@test "verdicts_exit_code is 0 when nothing failed" {
    run verdicts_exit_code "PASS a
WARN b
PASS c"
    [ "$status" -eq 0 ]
}

@test "verdicts_exit_code is non-zero when anything failed" {
    run verdicts_exit_code "PASS a
FAIL b"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/preconditions.bats`

Expected: FAIL — `lib/preconditions.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/preconditions.sh`:

```bash
# shellcheck shell=bash
# Host precondition verdicts.
#
# Each *_verdict function takes an already-gathered fact and returns a line
# of the form "<PASS|WARN|FAIL>\t<name>\t<detail>". Gathering is separated
# from judging so the judging can be tested without a particular host.
#
# Requires lib/common.sh to be sourced first.

check_result() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

cpu_vendor_verdict() {
    case $1 in
        GenuineIntel)
            check_result PASS cpu-vendor "Intel: the documented KVM path" ;;
        AuthenticAMD)
            check_result FAIL cpu-vendor \
                "AMD is a known-harder case for macOS guests; stop and ask" ;;
        *)
            check_result FAIL cpu-vendor "unrecognised CPU vendor: $1" ;;
    esac
}

vmx_verdict() {
    if [ "$1" = "yes" ]; then
        check_result PASS vmx "VT-x present"
    else
        check_result FAIL vmx "no VT-x; KVM acceleration unavailable"
    fi
}

kvm_device_verdict() {
    if [ -w "$1" ]; then
        check_result PASS kvm-device "$1 is writable by this user"
    elif [ -e "$1" ]; then
        check_result FAIL kvm-device \
            "$1 exists but is not writable; is this user in group kvm?"
    else
        check_result FAIL kvm-device "$1 does not exist"
    fi
}

# Somlo and OSX-KVM both require ignore_msrs. Setting it needs sudo, which
# is an ask -- so this warns rather than fails, and says what to do.
ignore_msrs_verdict() {
    if [ "$1" = "Y" ]; then
        check_result PASS ignore-msrs "kvm.ignore_msrs is enabled"
    else
        check_result WARN ignore-msrs \
            "kvm.ignore_msrs is '$1'; required by prior art. Needs sudo: ask before running 'echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs'"
    fi
}

ovmf_verdict() {
    local dir=$1
    if [ -f "$dir/OVMF_CODE_4M.fd" ] && [ -f "$dir/OVMF_VARS_4M.fd" ]; then
        check_result PASS ovmf "4M split CODE/VARS found in $dir"
    elif [ -f "$dir/OVMF.fd" ]; then
        check_result PASS ovmf "combined OVMF.fd found in $dir"
    else
        check_result FAIL ovmf "no usable OVMF firmware in $dir"
    fi
}

tool_verdict() {
    local tool=$1
    if command -v "$tool" >/dev/null 2>&1; then
        check_result PASS "tool:$tool" "$(command -v "$tool")"
    else
        check_result FAIL "tool:$tool" "not installed"
    fi
}

verdicts_exit_code() {
    if printf '%s\n' "$1" | grep -q '^FAIL'; then
        return 1
    fi
    return 0
}
```

Create `bin/preconditions.sh`:

```bash
#!/usr/bin/env bash
# Gather host facts, judge them, print a table, exit non-zero on any FAIL.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$repo_root/lib/common.sh"
# shellcheck source=../lib/preconditions.sh
. "$repo_root/lib/preconditions.sh"

OVMF_DIR=${OVMF_DIR:-/usr/share/OVMF}

vendor=$(awk -F': *' '/^Vendor ID/ { print $2; exit }' < <(LC_ALL=C lscpu))
if grep -qw vmx /proc/cpuinfo; then vmx=yes; else vmx=no; fi
msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || echo "unknown")

verdicts=$(
    cpu_vendor_verdict "$vendor"
    vmx_verdict "$vmx"
    kvm_device_verdict /dev/kvm
    ignore_msrs_verdict "$msrs"
    ovmf_verdict "$OVMF_DIR"
    for t in qemu-system-x86_64 qemu-img dmg2img kpartx sgdisk rsync xxd \
             openssl curl unzip python3 mkfs.hfsplus bats; do
        tool_verdict "$t"
    done
)

printf '%-6s  %-24s  %s\n' STATUS CHECK DETAIL
printf '%-6s  %-24s  %s\n' ------ ----- ------
printf '%s\n' "$verdicts" | while IFS=$'\t' read -r s n d; do
    printf '%-6s  %-24s  %s\n' "$s" "$n" "$d"
done

echo
if verdicts_exit_code "$verdicts"; then
    log "preconditions: GO"
else
    die "preconditions: NO-GO (see FAIL rows above)"
fi
```

Make it executable: `chmod +x bin/preconditions.sh`

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/preconditions.bats`

Expected: 9 tests, all passing.

- [ ] **Step 5: Run it against the real host**

Run: `./bin/preconditions.sh`

Expected on this host, per `docs/host-profile.md`: every row PASS except
`ignore-msrs`, which is WARN because the parameter reads `N`. Exit status 0,
since WARN is not FAIL.

If any tool row reports FAIL, **stop and ask** before installing packages.

- [ ] **Step 6: Record the result in the lab log**

Append the table to `NOTES.md` under a new `## <date> — P0 — preconditions`
heading, with a one-line conclusion.

- [ ] **Step 7: Commit**

```bash
git add lib/preconditions.sh bin/preconditions.sh tests/preconditions.bats NOTES.md
git commit -m "Add the host precondition check

Gathering facts is separated from judging them so the judgements can be
tested against synthetic inputs. A test that asks whether this host has
KVM passes for the wrong reason.

ignore_msrs warns rather than fails: it is required by prior art but
setting it needs sudo, which is an ask, and a NO-GO that everyone learns
to ignore is worse than a warning.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `lib/profile.sh` — QEMU configuration as composable text

**Files:**
- Create: `lib/profile.sh`
- Test: `tests/profile.bats`

A profile is a text file of QEMU arguments, one per line. Full-line comments
start with `#`. `@include <name>` pulls in another profile. `%REPO%` expands
to the repository root.

One argument per line — not a shell string — because it removes quoting
entirely from the problem. `-drive if=none,file=x,format=qcow2` never needs
escaping when it is its own line.

- [ ] **Step 1: Write the failing test**

Create `tests/profile.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/profile.sh"
    PROFILE_DIR="$BATS_TEST_TMPDIR/profiles"
    MQG_REPO_ROOT="/fake/repo"
    mkdir -p "$PROFILE_DIR"
}

@test "profile_expand emits one argument per line" {
    printf '%s\n' '-enable-kvm' '-m' '4096' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-enable-kvm" ]
    [ "${lines[1]}" = "-m" ]
    [ "${lines[2]}" = "4096" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "profile_expand skips full-line comments and blank lines" {
    printf '%s\n' '# a comment' '' '-enable-kvm' '   # indented comment' \
        > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "-enable-kvm" ]
}

@test "profile_expand keeps a hash that is not at the start of a line" {
    printf '%s\n' '-fw_cfg' 'name=opt/x,string=a#b' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[1]}" = 'name=opt/x,string=a#b' ]
}

@test "profile_expand trims surrounding whitespace" {
    printf '%s\n' '   -enable-kvm   ' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[0]}" = "-enable-kvm" ]
}

@test "profile_expand resolves @include in place" {
    printf '%s\n' '-enable-kvm' > "$PROFILE_DIR/base.args"
    printf '%s\n' '@include base' '-m' '4096' > "$PROFILE_DIR/derived.args"
    run profile_expand derived
    [ "${lines[0]}" = "-enable-kvm" ]
    [ "${lines[1]}" = "-m" ]
    [ "${lines[2]}" = "4096" ]
}

@test "profile_expand resolves nested includes" {
    printf '%s\n' '-enable-kvm' > "$PROFILE_DIR/a.args"
    printf '%s\n' '@include a' '-m' > "$PROFILE_DIR/b.args"
    printf '%s\n' '@include b' '4096' > "$PROFILE_DIR/c.args"
    run profile_expand c
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[2]}" = "4096" ]
}

@test "profile_expand detects an include cycle instead of looping forever" {
    printf '%s\n' '@include b' > "$PROFILE_DIR/a.args"
    printf '%s\n' '@include a' > "$PROFILE_DIR/b.args"
    run profile_expand a
    [ "$status" -ne 0 ]
    [[ "$output" == *"cycle"* ]]
}

@test "profile_expand fails for a missing profile and names it" {
    run profile_expand nosuch
    [ "$status" -ne 0 ]
    [[ "$output" == *"nosuch"* ]]
}

@test "profile_expand substitutes %REPO% with the repository root" {
    printf '%s\n' '-drive' 'file=%REPO%/work/disk.qcow2' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[1]}" = "file=/fake/repo/work/disk.qcow2" ]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/profile.bats`

Expected: FAIL — `lib/profile.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/profile.sh`:

```bash
# shellcheck shell=bash
# Profiles: QEMU configuration as composable plain text.
#
# One argument per line, so quoting never enters the picture. Full-line
# comments start with '#'. '@include <name>' pulls in another profile.
# '%REPO%' expands to the repository root.
#
# The point of the format is that an experiment is a diff. Changing one
# variable at a time is only verifiable if the change is a file change.
#
# Requires lib/common.sh. Callers set PROFILE_DIR and MQG_REPO_ROOT.

profile_path() {
    printf '%s/%s.args\n' "${PROFILE_DIR:?PROFILE_DIR is unset}" "$1"
}

# profile_expand <name> [include-chain]
profile_expand() {
    local name=$1 chain=${2:-} path line

    case ":$chain:" in
        *":$name:"*) die "profile include cycle: $chain -> $name" ;;
    esac

    path=$(profile_path "$name")
    [ -f "$path" ] || die "no such profile: $name (looked for $path)"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
        line="${line%"${line##*[![:space:]]}"}"   # strip trailing whitespace
        [ -n "$line" ] || continue
        case $line in
            '#'*)
                continue ;;
            '@include '*)
                profile_expand "${line#@include }" "$chain:$name" ;;
            *)
                printf '%s\n' "${line//'%REPO%'/${MQG_REPO_ROOT:?MQG_REPO_ROOT is unset}}" ;;
        esac
    done < "$path"
}

# List every profile name.
profile_list() {
    local p
    for p in "${PROFILE_DIR:?}"/*.args; do
        [ -e "$p" ] || continue
        basename "$p" .args
    done
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/profile.bats`

Expected: 9 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add lib/profile.sh tests/profile.bats
git commit -m "Add profile expansion: QEMU config as composable text

One argument per line removes shell quoting from the problem entirely,
which matters because the arguments we care about are the comma-soup
kind. @include lets an experiment be a two-line file that includes the
baseline, so 'one variable at a time' is checkable by reading a diff
rather than by trusting someone's memory.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `vm/run.sh` and `bin/tier-check.sh`

**Files:**
- Create: `vm/run.sh`
- Create: `bin/tier-check.sh`
- Create: `vm/profiles/base-kvm.args`
- Test: `tests/run.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/run.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "run.sh in dry-run mode prints the command without executing it" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm
    [ "$status" -eq 0 ]
    [[ "$output" == *"qemu-system-x86_64"* ]]
    [[ "$output" == *"-enable-kvm"* ]]
}

@test "run.sh appends extra arguments after the profile's own" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" base-kvm -snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"-snapshot"* ]]
}

@test "run.sh fails with usage when given no profile" {
    run "$REPO/vm/run.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "run.sh fails for an unknown profile" {
    run env MQG_DRY_RUN=1 "$REPO/vm/run.sh" no-such-profile
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such profile"* ]]
}

@test "tier-check reports clean when no profile uses the quarantine" {
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        "$REPO/bin/tier-check.sh"
    [ "$status" -eq 0 ]
}

@test "tier-check names a profile that references the quarantine" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-drive' 'file=%REPO%/vendor/reference/efi.img' \
        > "$BATS_TEST_TMPDIR/profiles/dirty.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        "$REPO/bin/tier-check.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dirty"* ]]
}

@test "tier-check --strict fails when a profile references the quarantine" {
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf '%s\n' '-drive' 'file=%REPO%/vendor/reference/efi.img' \
        > "$BATS_TEST_TMPDIR/profiles/dirty.args"
    run env MQG_TIER_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" \
        "$REPO/bin/tier-check.sh" --strict
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/run.bats`

Expected: FAIL — `vm/run.sh` does not exist.

- [ ] **Step 3: Write the baseline profile**

Create `vm/profiles/base-kvm.args`:

```
# base-kvm -- the machine-level settings common to every KVM profile.
#
# Provenance: machine/memory/smp from the umbrella design's starting flags,
# themselves from mavericks-qemu-brief step 3.
#
# SMP is not optional here: Somlo reports that 10.9's first boot after
# install fails without it. Do not "simplify" this to -smp 1.

-enable-kvm
-machine
q35
-m
4096
-smp
2
```

- [ ] **Step 4: Write `vm/run.sh`**

```bash
#!/usr/bin/env bash
# Expand a profile and run QEMU with it.
#
# Every invocation is appended to run.log. The lab notebook should not
# depend on anyone remembering to write things down.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/profile.sh
. "$MQG_REPO_ROOT/lib/profile.sh"

PROFILE_DIR=${PROFILE_DIR:-$MQG_REPO_ROOT/vm/profiles}

if [ $# -lt 1 ]; then
    die "usage: vm/run.sh <profile> [extra qemu args...]

Available profiles:
$(PROFILE_DIR="$PROFILE_DIR" profile_list 2>/dev/null | sed 's/^/  /')"
fi

profile=$1
shift

mapfile -t args < <(profile_expand "$profile")
if [ "${#args[@]}" -eq 0 ]; then
    die "profile $profile expanded to nothing"
fi

cmdline=$(printf '%q ' qemu-system-x86_64 "${args[@]}" "$@")

if [ "${MQG_DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$cmdline"
    exit 0
fi

run_log "profile=$profile $cmdline"
log "running profile $profile (${#args[@]} profile args, $# extra)"
exec qemu-system-x86_64 "${args[@]}" "$@"
```

Make it executable: `chmod +x vm/run.sh`

Note: `mapfile` inside a `$(...)` substitution would lose the exit status of
`profile_expand`, so it is written as a process substitution. If the profile
is missing, `profile_expand` calls `die`, which writes to stderr and exits its
subshell; `args` ends up empty and the length check fires. Both the message
and a non-zero exit reach the caller.

- [ ] **Step 5: Write `bin/tier-check.sh`**

```bash
#!/usr/bin/env bash
# Report which profiles reference the Tier 2 quarantine.
#
# During P1 and P2 this is expected to be non-empty: reference firmware is
# how we de-risk the first boot. P3's exit gate is that it becomes empty,
# at which point CI runs this with --strict.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export MQG_REPO_ROOT
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/profile.sh
. "$MQG_REPO_ROOT/lib/profile.sh"

PROFILE_DIR=${MQG_TIER_PROFILE_DIR:-$MQG_REPO_ROOT/vm/profiles}

strict=0
if [ "${1:-}" = "--strict" ]; then
    strict=1
fi

dirty=0
for name in $(profile_list); do
    if profile_expand "$name" 2>/dev/null | grep -q '/vendor/reference/'; then
        printf 'TIER2  %s\n' "$name"
        dirty=1
    fi
done

if [ "$dirty" -eq 0 ]; then
    log "no profile references vendor/reference/ -- Tier 2 clean"
    exit 0
fi

if [ "$strict" -eq 1 ]; then
    die "profiles above reference the Tier 2 quarantine; P3's exit gate is not met"
fi

log "the profiles above are Tier 2. Expected during P1 and P2; P3 must clear them."
exit 0
```

Make it executable: `chmod +x bin/tier-check.sh`

- [ ] **Step 6: Run the tests and make sure they pass**

Run: `bats tests/run.bats`

Expected: 7 tests, all passing.

- [ ] **Step 7: Verify the dry run by eye**

Run: `MQG_DRY_RUN=1 ./vm/run.sh base-kvm`

Expected output: `qemu-system-x86_64 -enable-kvm -machine q35 -m 4096 -smp 2`

- [ ] **Step 8: Commit**

```bash
git add vm/run.sh bin/tier-check.sh vm/profiles/base-kvm.args tests/run.bats
git commit -m "Add vm/run.sh and the Tier 2 quarantine check

run.sh appends every invocation to run.log, so the record of what was
actually run does not depend on anyone remembering to write it down.

tier-check reports rather than fails for now: P1 and P2 deliberately use
reference firmware to de-risk the first boot. P3's exit gate flips it to
--strict, which is the mechanism behind 'no blobs we cannot rebuild'.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Golden images

**Files:**
- Create: `lib/golden.sh`
- Create: `vm/golden.sh`
- Test: `tests/golden.bats`

A golden is a read-only, checksummed disk image with a metadata sidecar. The
tests use 1 MiB qcow2 images, so they exercise real `qemu-img` behavior
without needing real disks.

- [ ] **Step 1: Write the failing test**

Create `tests/golden.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/golden.sh"
    GOLDEN_DIR="$BATS_TEST_TMPDIR/golden"
    mkdir -p "$GOLDEN_DIR"
    SRC="$BATS_TEST_TMPDIR/src.qcow2"
    qemu-img create -f qcow2 "$SRC" 1M >/dev/null
}

@test "golden_promote creates the image, its checksum, and its metadata" {
    run golden_promote "$SRC" first "the first install"
    [ "$status" -eq 0 ]
    [ -f "$GOLDEN_DIR/first.qcow2" ]
    [ -f "$GOLDEN_DIR/first.sha256" ]
    [ -f "$GOLDEN_DIR/first.meta" ]
}

@test "golden_promote makes the image read-only" {
    golden_promote "$SRC" first "desc"
    [ ! -w "$GOLDEN_DIR/first.qcow2" ]
}

@test "golden_promote records the description in the metadata" {
    golden_promote "$SRC" first "the first install"
    grep -q "the first install" "$GOLDEN_DIR/first.meta"
}

@test "golden_promote refuses to overwrite an existing golden" {
    golden_promote "$SRC" first "desc"
    run golden_promote "$SRC" first "desc again"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "golden_verify passes for an untouched golden" {
    golden_promote "$SRC" first "desc"
    run golden_verify first
    [ "$status" -eq 0 ]
}

@test "golden_verify fails for a corrupted golden" {
    golden_promote "$SRC" first "desc"
    chmod u+w "$GOLDEN_DIR/first.qcow2"
    printf 'corruption' >> "$GOLDEN_DIR/first.qcow2"
    run golden_verify first
    [ "$status" -ne 0 ]
    [[ "$output" == *"checksum mismatch"* ]]
}

@test "golden_path returns the image path" {
    golden_promote "$SRC" first "desc"
    run golden_path first
    [ "$output" = "$GOLDEN_DIR/first.qcow2" ]
}

@test "golden_path fails for an unknown golden" {
    run golden_path nosuch
    [ "$status" -ne 0 ]
}

@test "golden_list names every golden" {
    golden_promote "$SRC" first "desc"
    qemu-img create -f qcow2 "$BATS_TEST_TMPDIR/s2.qcow2" 1M >/dev/null
    golden_promote "$BATS_TEST_TMPDIR/s2.qcow2" second "desc"
    run golden_list
    [[ "$output" == *"first"* ]]
    [[ "$output" == *"second"* ]]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/golden.bats`

Expected: FAIL — `lib/golden.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/golden.sh`:

```bash
# shellcheck shell=bash
# Golden images: read-only, checksummed, with a metadata sidecar.
#
# Nothing ever writes to a golden. Experiments run on overlays created by
# vm/clone.sh. Promotion is deliberate and, per the design, requires
# measurement and the user's approval -- this library only enforces the
# mechanical half.
#
# Requires lib/common.sh. Callers set GOLDEN_DIR.

golden_image() { printf '%s/%s.qcow2\n'  "${GOLDEN_DIR:?GOLDEN_DIR is unset}" "$1"; }
golden_sum()   { printf '%s/%s.sha256\n' "${GOLDEN_DIR:?}" "$1"; }
golden_meta()  { printf '%s/%s.meta\n'   "${GOLDEN_DIR:?}" "$1"; }

# golden_promote <source-image> <name> <description>
golden_promote() {
    local src=$1 name=$2 desc=$3 img sum meta
    [ -f "$src" ] || die "no such image: $src"
    img=$(golden_image "$name")
    [ ! -e "$img" ] || die "golden $name already exists at $img"

    mkdir -p "$GOLDEN_DIR"
    log "promoting $src to golden $name (this copies the whole image)"
    cp --reflink=auto "$src" "$img"

    sha256_file "$img" > "$(golden_sum "$name")"

    meta=$(golden_meta "$name")
    {
        printf 'name: %s\n'        "$name"
        printf 'description: %s\n' "$desc"
        printf 'promoted: %s\n'    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'source: %s\n'      "$src"
        printf 'sha256: %s\n'      "$(cat "$(golden_sum "$name")")"
        printf 'qemu-img-info:\n'
        qemu-img info "$img" | sed 's/^/  /'
    } > "$meta"

    chmod 0444 "$img"
    log "golden $name promoted"
}

golden_verify() {
    local name=$1 img sum
    img=$(golden_image "$name")
    sum=$(golden_sum "$name")
    [ -f "$img" ] || die "no such golden: $name"
    [ -f "$sum" ] || die "golden $name has no recorded checksum"
    verify_sha256 "$img" "$(cat "$sum")"
    log "golden $name verified"
}

golden_path() {
    local img
    img=$(golden_image "$1")
    [ -f "$img" ] || die "no such golden: $1"
    printf '%s\n' "$img"
}

golden_list() {
    local g
    for g in "${GOLDEN_DIR:?}"/*.qcow2; do
        [ -e "$g" ] || continue
        basename "$g" .qcow2
    done
}
```

Create `vm/golden.sh`:

```bash
#!/usr/bin/env bash
# CLI over lib/golden.sh.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/golden.sh
. "$MQG_REPO_ROOT/lib/golden.sh"

GOLDEN_DIR=${GOLDEN_DIR:-$MQG_REPO_ROOT/golden}

usage() {
    die "usage:
  vm/golden.sh promote <image> <name> <description>
  vm/golden.sh list
  vm/golden.sh verify <name>
  vm/golden.sh path <name>"
}

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
    promote) [ $# -eq 3 ] || usage; golden_promote "$1" "$2" "$3" ;;
    list)    golden_list ;;
    verify)  [ $# -eq 1 ] || usage; golden_verify "$1" ;;
    path)    [ $# -eq 1 ] || usage; golden_path "$1" ;;
    *)       usage ;;
esac
```

Make it executable: `chmod +x vm/golden.sh`

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/golden.bats`

Expected: 9 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add lib/golden.sh vm/golden.sh tests/golden.bats
git commit -m "Add golden image management

Goldens are chmod 0444 and checksummed on promotion, so accidentally
writing to one is an error rather than a silently invalidated baseline.
Tests use 1MiB qcow2 images, which exercises real qemu-img behaviour
without needing real disks.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Throwaway clones

**Files:**
- Create: `vm/clone.sh`
- Test: `tests/clone.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/clone.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export GOLDEN_DIR="$BATS_TEST_TMPDIR/golden"
    export WORK_DIR="$BATS_TEST_TMPDIR/work"
    mkdir -p "$GOLDEN_DIR"
    qemu-img create -f qcow2 "$BATS_TEST_TMPDIR/src.qcow2" 1M >/dev/null
    "$REPO/vm/golden.sh" promote "$BATS_TEST_TMPDIR/src.qcow2" base "test" >/dev/null 2>&1
}

@test "clone.sh creates an overlay backed by the golden" {
    run "$REPO/vm/clone.sh" base exp1
    [ "$status" -eq 0 ]
    [ -f "$WORK_DIR/exp1.qcow2" ]
    run qemu-img info "$WORK_DIR/exp1.qcow2"
    [[ "$output" == *"$GOLDEN_DIR/base.qcow2"* ]]
}

@test "clone.sh leaves the golden read-only and unmodified" {
    before=$(sha256sum "$GOLDEN_DIR/base.qcow2" | cut -d' ' -f1)
    "$REPO/vm/clone.sh" base exp1
    after=$(sha256sum "$GOLDEN_DIR/base.qcow2" | cut -d' ' -f1)
    [ "$before" = "$after" ]
    [ ! -w "$GOLDEN_DIR/base.qcow2" ]
}

@test "clone.sh defaults the clone name from the golden name" {
    run "$REPO/vm/clone.sh" base
    [ "$status" -eq 0 ]
    ls "$WORK_DIR" | grep -q '^base-'
}

@test "clone.sh refuses to overwrite an existing clone" {
    "$REPO/vm/clone.sh" base exp1
    run "$REPO/vm/clone.sh" base exp1
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "clone.sh fails for an unknown golden" {
    run "$REPO/vm/clone.sh" nosuch exp1
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/clone.bats`

Expected: FAIL — `vm/clone.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `vm/clone.sh`:

```bash
#!/usr/bin/env bash
# Create a throwaway qcow2 overlay over a golden image.
#
# Experiments run on clones. Nothing runs on a golden.
#
# --verify recomputes the golden's checksum first. It is opt-in because
# hashing a 60 GB image before every experiment would make the safe path
# the slow path, and people route around slow safe paths.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/golden.sh
. "$MQG_REPO_ROOT/lib/golden.sh"

GOLDEN_DIR=${GOLDEN_DIR:-$MQG_REPO_ROOT/golden}
WORK_DIR=${WORK_DIR:-$MQG_REPO_ROOT/work}

verify=0
if [ "${1:-}" = "--verify" ]; then
    verify=1
    shift
fi

if [ $# -lt 1 ]; then
    die "usage: vm/clone.sh [--verify] <golden-name> [clone-name]"
fi

golden=$1
clone=${2:-$golden-$(date -u +%Y%m%d-%H%M%S)}

src=$(golden_path "$golden")
[ "$verify" -eq 0 ] || golden_verify "$golden"

mkdir -p "$WORK_DIR"
dest="$WORK_DIR/$clone.qcow2"
[ ! -e "$dest" ] || die "clone $clone already exists at $dest"

qemu-img create -f qcow2 -F qcow2 -b "$src" "$dest" >/dev/null
log "clone $clone created at $dest, backed by golden $golden"
printf '%s\n' "$dest"
```

Make it executable: `chmod +x vm/clone.sh`

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/clone.bats`

Expected: 5 tests, all passing.

- [ ] **Step 5: Run the whole suite**

Run: `./bin/run-tests.sh`

Expected: every bats file passes; shellcheck reports nothing; exit 0.

- [ ] **Step 6: Commit — this closes P0**

```bash
git add vm/clone.sh tests/clone.bats
git commit -m "Add throwaway clones, closing P0

--verify is opt-in rather than default: hashing a 60GB golden before
every experiment would make the safe path the slow path, and people route
around slow safe paths.

P0 is complete: preconditions, profiles, goldens, clones, and a test
suite that runs without installing anything.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `boot/inspect-utm-bundle.py`

**Files:**
- Create: `boot/inspect-utm-bundle.py`
- Test: `tests/inspect_utm.bats`

**Design note.** The script is deliberately **schema-agnostic**: it walks
whatever the plist contains and reports every key, rather than knowing UTM's
layout. UTM's config format has changed across versions, nobody has inspected
this particular bundle, and the brief's instruction was to report what is
actually in it. A script that knows the schema silently omits everything that
does not match its guess — which is the one failure mode that matters here.

- [ ] **Step 1: Write the failing test**

Create `tests/inspect_utm.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/boot/inspect-utm-bundle.py"
    PLIST="$BATS_TEST_TMPDIR/config.plist"
}

make_plist() {
    python3 -c "
import plistlib, sys
plistlib.dump($1, open(sys.argv[1], 'wb'), fmt=plistlib.FMT_${2:-XML})
" "$PLIST"
}

@test "nested dictionary keys become dotted paths" {
    make_plist "{'System': {'Architecture': 'x86_64', 'MemorySize': 8192}}"
    run python3 "$SCRIPT" "$PLIST"
    [ "$status" -eq 0 ]
    [[ "$output" == *'`System.Architecture`'* ]]
    [[ "$output" == *'`x86_64`'* ]]
    [[ "$output" == *'`System.MemorySize`'* ]]
    [[ "$output" == *'`8192`'* ]]
}

@test "list elements are indexed without a stray dot" {
    make_plist "{'Drive': [{'ImagePath': 'disk.qcow2'}, {'ImagePath': 'efi.img'}]}"
    run python3 "$SCRIPT" "$PLIST"
    [[ "$output" == *'`Drive[0].ImagePath`'* ]]
    [[ "$output" == *'`Drive[1].ImagePath`'* ]]
    [[ "$output" != *'`Drive.[0]'* ]]
}

@test "booleans render readably" {
    make_plist "{'System': {'ForceMulticore': True}}"
    run python3 "$SCRIPT" "$PLIST"
    [[ "$output" == *'`true`'* ]]
}

@test "binary data is summarised by length, not dumped" {
    make_plist "{'Blob': b'0123456789'}"
    run python3 "$SCRIPT" "$PLIST"
    [[ "$output" == *'10 bytes'* ]]
    [[ "$output" != *'0123456789'* ]]
}

@test "pipes in values are escaped so the table survives" {
    make_plist "{'QEMU': {'Args': 'a|b'}}"
    run python3 "$SCRIPT" "$PLIST"
    [[ "$output" == *'a\|b'* ]]
}

@test "binary plists are read as happily as XML ones" {
    make_plist "{'System': {'Architecture': 'x86_64'}}" BINARY
    run python3 "$SCRIPT" "$PLIST"
    [ "$status" -eq 0 ]
    [[ "$output" == *'`x86_64`'* ]]
}

@test "a missing file fails rather than producing an empty table" {
    run python3 "$SCRIPT" "$BATS_TEST_TMPDIR/nope.plist"
    [ "$status" -ne 0 ]
}

@test "the title is settable" {
    make_plist "{'A': 'b'}"
    run python3 "$SCRIPT" --title "Kostarelas bundle" "$PLIST"
    [[ "$output" == *"# Kostarelas bundle"* ]]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/inspect_utm.bats`

Expected: FAIL — `boot/inspect-utm-bundle.py` does not exist.

- [ ] **Step 3: Write the implementation**

Create `boot/inspect-utm-bundle.py`:

```python
#!/usr/bin/env python3
"""Dump a UTM config.plist as a Markdown table.

Deliberately schema-agnostic. UTM's configuration format has changed across
versions, and nobody has inspected the particular bundle we care about, so
this walks whatever is present rather than looking for keys it expects. A
script that knows the schema quietly drops everything that does not match
its guess, which is exactly the failure we cannot afford here: the whole
point is to find out what the working configuration actually was.
"""

import argparse
import plistlib
import sys


def walk(obj, path=()):
    """Yield (path, scalar) for every leaf, preserving document order."""
    if isinstance(obj, dict):
        for key in obj:
            yield from walk(obj[key], path + (str(key),))
    elif isinstance(obj, (list, tuple)):
        for index, value in enumerate(obj):
            yield from walk(value, path + ("[%d]" % index,))
    else:
        yield path, obj


def join_path(path):
    """Render a path as System.Drive[0].ImagePath, with no stray dots."""
    out = ""
    for part in path:
        if part.startswith("["):
            out += part
        elif out:
            out += "." + part
        else:
            out = part
    return out


def format_value(value):
    if isinstance(value, bool):
        return "`true`" if value else "`false`"
    if isinstance(value, (bytes, bytearray)):
        return "`<%d bytes>`" % len(value)
    text = str(value)
    if not text:
        return "*(empty)*"
    return "`" + text.replace("|", r"\|") + "`"


def render(data, title):
    lines = [
        "# %s" % title,
        "",
        "Generated by `boot/inspect-utm-bundle.py`. Every key in the plist is",
        "listed and nothing is filtered, so that what actually worked is on",
        "the record rather than what we expected to find.",
        "",
        "| Key path | Value |",
        "| --- | --- |",
    ]
    for path, value in walk(data):
        lines.append("| `%s` | %s |" % (join_path(path), format_value(value)))
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", help="path to config.plist")
    parser.add_argument("--title", default="UTM bundle configuration")
    args = parser.parse_args()

    try:
        with open(args.plist, "rb") as handle:
            data = plistlib.load(handle)
    except OSError as exc:
        sys.exit("cannot read %s: %s" % (args.plist, exc))
    except plistlib.InvalidFileException as exc:
        sys.exit("not a readable plist: %s: %s" % (args.plist, exc))

    sys.stdout.write(render(data, args.title))


if __name__ == "__main__":
    main()
```

Make it executable: `chmod +x boot/inspect-utm-bundle.py`

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/inspect_utm.bats`

Expected: 8 tests, all passing.

- [ ] **Step 5: Commit**

```bash
git add boot/inspect-utm-bundle.py tests/inspect_utm.bats
git commit -m "Add a schema-agnostic UTM config.plist dumper

It walks whatever the plist contains rather than looking for the keys we
expect. UTM's format has changed across versions and nobody has opened
this bundle, so a schema-aware reader would quietly drop exactly the
settings we are trying to discover.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Confirm and fetch the Tier 2 reference artifacts

**This task requires network access and touches `vendor/sources.tsv`.**

**Files:**
- Modify: `vendor/sources.tsv`
- Create: `boot/fetch-reference.sh`
- Create: `docs/utm-bundle-config.md` (generated)
- Modify: `docs/prior-art.md`
- Modify: `NOTES.md`

This is not a TDD task. It is a research task with a recording obligation.

- [ ] **Step 1: Find the real URLs — do not guess them**

Read <https://adam.kostarelas.com/blog/mavericks-in-utm-on-silicon/> and find
the actual href of the UTM bundle download (the brief calls it
`Mavericks-OSX-10.9-Config.utm.zip`).

Read the `khronokernel/khronokernel.github.io` repository under
`Binaries/OpenCore/` and find the raw URL of `EFI-LEGACY.img`.

**If either page cannot be fetched, stop and report it.** Do not substitute a
mirror, a lookalike, or a guess. This is one of the umbrella design's
stop-and-ask conditions.

- [ ] **Step 2: Record the URLs**

Replace the two `CONFIRM-IN-TASK-10` placeholders in `vendor/sources.tsv`
with the real URLs. Leave both checksums as `TOFU`.

- [ ] **Step 3: Write the fetcher**

Create `boot/fetch-reference.sh`:

```bash
#!/usr/bin/env bash
# Fetch Tier 2 reference artifacts into the quarantine.
#
# These are somebody else's blobs. They exist to de-risk the first boot: if
# the known-good configuration will not boot, the problem is ours and not
# the firmware's. P3 replaces every one of them with something we can
# rebuild, and bin/tier-check.sh --strict is what proves it happened.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck source=../lib/vendor.sh
. "$MQG_REPO_ROOT/lib/vendor.sh"

require_cmd curl unzip

SOURCES="$MQG_REPO_ROOT/vendor/sources.tsv"
QUARANTINE="$MQG_REPO_ROOT/vendor/reference"

for name in "$@"; do
    url=$(source_field "$SOURCES" "$name" url)
    case $url in
        CONFIRM-IN-TASK-10)
            die "source $name still has a placeholder URL; confirm it against the live page first" ;;
    esac
done

[ $# -gt 0 ] || die "usage: boot/fetch-reference.sh <source-name>..."

for name in "$@"; do
    path=$(fetch_source "$SOURCES" "$name" "$QUARANTINE")
    log "$name -> $path"
    case $path in
        *.zip)
            dest="$QUARANTINE/${name}"
            if [ -d "$dest" ]; then
                log "$name already unpacked at $dest"
            else
                log "unpacking $name into $dest"
                mkdir -p "$dest"
                unzip -q "$path" -d "$dest"
            fi
            ;;
    esac
done

log "done. Review the pinned checksums in $SOURCES and commit them."
```

Make it executable: `chmod +x boot/fetch-reference.sh`

- [ ] **Step 4: Fetch**

Run:

```bash
./boot/fetch-reference.sh utm-bundle opencore-legacy-img
```

Expected: both download, both checksums get pinned on first use with a warning
telling you to commit them, and the zip is unpacked under
`vendor/reference/utm-bundle/`.

- [ ] **Step 5: Inspect the bundle**

A `.utm` is a directory. Find the `config.plist` inside it and dump it:

```bash
find vendor/reference/utm-bundle -name config.plist
./boot/inspect-utm-bundle.py --title "Kostarelas Mavericks UTM bundle" \
    "$(find vendor/reference/utm-bundle -name config.plist | head -1)" \
    > docs/utm-bundle-config.md
```

Also list what else the bundle contains, since the firmware and OpenCore
images are what we actually need:

```bash
find vendor/reference/utm-bundle -type f -exec ls -l {} \; \
    | tee -a NOTES.md
```

- [ ] **Step 6: Write up what was found**

In `docs/prior-art.md`, under the Kostarelas heading, replace the sentence
"**Nobody has inspected this bundle for this project.**" with the settings
that were actually found, linking to `docs/utm-bundle-config.md` for the full
dump. Cover at minimum, and say explicitly if any is absent: architecture,
machine type, CPU model and flags, extra QEMU arguments, memory, core count,
every drive with its interface and image type, NIC model, and display device.

Two specific questions the design asks you to answer here:

- **Is there an `isa-applesmc` device, or does the OpenCore image emulate the
  SMC itself?** khronokernel's settings list has no applesmc, which is why
  this matters. Record which of the two we end up relying on.
- **Is the OVMF a combined image or split CODE/VARS?** This host's `ovmf`
  package ships 4M split only, and the answer determines how much work P3's
  firmware swap is.

- [ ] **Step 7: Commit**

```bash
git add vendor/sources.tsv boot/fetch-reference.sh docs/utm-bundle-config.md \
        docs/prior-art.md NOTES.md
git commit -m "Fetch and inspect the Tier 2 reference artifacts

Records what is actually in Kostarelas's UTM bundle rather than what the
brief guessed. Checksums are pinned on first use and committed here, so
every later fetch is verified against what we actually got today.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Import the Mac-produced installer image

**Prerequisite (on the Intel Mac, not here):** run Mavericks Forever's
`get.sh` unmodified to produce `InstallMacOSXMavericks.dmg`, and copy it to
this host. `get.sh` verifies Apple's SHA-256 itself; if that check fails,
**stop and report** — it is a stop-and-ask condition.

**Files:**
- Create: `media/import-reference-dmg.sh`
- Test: `tests/import_dmg.bats`
- Modify: `vendor/sources.tsv`

- [ ] **Step 1: Write the failing test**

The conversion itself needs a real dmg, so the tests cover the parts that can
go wrong silently: argument handling, refusing to clobber, and recording the
checksums of both files.

Create `tests/import_dmg.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export MEDIA_DIR="$BATS_TEST_TMPDIR/media"
    export MQG_SKIP_CONVERT=1   # exercised without dmg2img
    printf 'not really a dmg\n' > "$BATS_TEST_TMPDIR/fake.dmg"
}

@test "import fails with usage when given no arguments" {
    run "$REPO/media/import-reference-dmg.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "import fails for a missing source file" {
    run "$REPO/media/import-reference-dmg.sh" "$BATS_TEST_TMPDIR/nope.dmg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such file"* ]]
}

@test "import records the checksum of the source dmg" {
    run "$REPO/media/import-reference-dmg.sh" "$BATS_TEST_TMPDIR/fake.dmg"
    [ "$status" -eq 0 ]
    [ -f "$MEDIA_DIR/installer-reference.dmg.sha256" ]
    want=$(sha256sum "$BATS_TEST_TMPDIR/fake.dmg" | cut -d' ' -f1)
    got=$(cat "$MEDIA_DIR/installer-reference.dmg.sha256")
    [ "$want" = "$got" ]
}

@test "import refuses to clobber an existing import" {
    "$REPO/media/import-reference-dmg.sh" "$BATS_TEST_TMPDIR/fake.dmg"
    run "$REPO/media/import-reference-dmg.sh" "$BATS_TEST_TMPDIR/fake.dmg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already"* ]]
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bats tests/import_dmg.bats`

Expected: FAIL — `media/import-reference-dmg.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `media/import-reference-dmg.sh`:

```bash
#!/usr/bin/env bash
# Import the Mac-produced installer dmg and convert it to a raw image.
#
# This is installer Approach C: get.sh run unmodified on a Mac, which is the
# path Kostarelas actually proved. Its output is the reference that P4's
# Linux-native build gets diffed against -- so when the Linux build produces
# something that will not boot, we can tell whether the media or the
# configuration is at fault.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

MEDIA_DIR=${MEDIA_DIR:-$MQG_REPO_ROOT/media/images}

[ $# -eq 1 ] || die "usage: media/import-reference-dmg.sh <InstallMacOSXMavericks.dmg>"
src=$1
[ -f "$src" ] || die "no such file: $src"

mkdir -p "$MEDIA_DIR"
dmg="$MEDIA_DIR/installer-reference.dmg"
img="$MEDIA_DIR/installer-reference.img"

[ ! -e "$dmg" ] || die "$dmg already exists; remove it deliberately if you mean to re-import"

log "copying $src to $dmg"
cp --reflink=auto "$src" "$dmg"
sha256_file "$dmg" > "$dmg.sha256"
log "dmg sha256: $(cat "$dmg.sha256")"

if [ "${MQG_SKIP_CONVERT:-0}" = "1" ]; then
    log "MQG_SKIP_CONVERT set; stopping before dmg2img"
    exit 0
fi

require_cmd dmg2img
log "converting to raw (this takes a while and needs ~7 GB)"
dmg2img -i "$dmg" -o "$img"
sha256_file "$img" > "$img.sha256"
log "raw image sha256: $(cat "$img.sha256")"

chmod 0444 "$dmg" "$img"
log "imported. Both files are read-only; record the checksums in NOTES.md."
```

Make it executable: `chmod +x media/import-reference-dmg.sh`

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bats tests/import_dmg.bats`

Expected: 4 tests, all passing.

- [ ] **Step 5: Import the real dmg**

Run: `./media/import-reference-dmg.sh /path/to/InstallMacOSXMavericks.dmg`

Expected: a raw image of roughly 6.6 GB in `media/images/`, plus checksums for
both files.

If `dmg2img` fails, record the exact error in `NOTES.md` before trying
anything else. A dmg that will not convert is evidence about the dmg.

- [ ] **Step 6: Record and commit**

Append both checksums and the image size to `NOTES.md`. Add the reference
image to `vendor/sources.tsv` as a local entry so its checksum is pinned
alongside everything else:

```tsv
installer-reference-dmg	local:media/images/installer-reference.dmg	<the sha256>
```

```bash
git add media/import-reference-dmg.sh tests/import_dmg.bats \
        vendor/sources.tsv NOTES.md
git commit -m "Import the Mac-produced installer image

Approach C, the path Kostarelas proved. Its value is not that it is the
final answer -- P4 replaces it with a Linux-native build -- but that it
gives that build something to be wrong against.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: First boot under KVM

**This task cannot be test-driven.** It is a bring-up procedure. Its
deliverable is a working command line *and* a record of everything that did
not work on the way there.

**Files:**
- Create: `vm/profiles/p1-reference.args`
- Modify: `NOTES.md` (after every attempt, not at the end)

**Exit criterion:** the OpenCore picker appears, the Mavericks installer is
selectable, and it boots to its GUI under `-enable-kvm`.

- [ ] **Step 1: Provide the OSK**

`isa-applesmc` needs Apple's OSK string. Take it from kholia/OSX-KVM's
`OpenCore-Boot-macOS.sh`. Since this host is itself a Mac, reading the value
from its own hardware is also legitimate and arguably cleaner.

Write it to `vendor/osk.txt` and keep it out of git:

```bash
echo 'vendor/osk.txt' >> .gitignore
```

**Whether this device is needed at all is an open question Task 10 answered.**
If the bundle's OpenCore emulates the SMC itself, leave `isa-applesmc` out and
record that we depend on the OpenCore image for it — that becomes a constraint
on P3, because our own OpenCore build will have to do the same thing.

- [ ] **Step 2: Prepare writable NVRAM**

OVMF's variable store must be writable and per-VM. Never point `unit=1` at the
file in `/usr/share/OVMF` or at anything in the quarantine:

```bash
mkdir -p work
cp /usr/share/OVMF/OVMF_VARS_4M.fd work/OVMF_VARS.fd
chmod u+w work/OVMF_VARS.fd
```

If Task 10 found the bundle ships its own OVMF as a **combined** image, use
that as `unit=0` instead and note that the split/combined mismatch is now a
P3 problem.

- [ ] **Step 3: Write the profile**

Create `vm/profiles/p1-reference.args`. The firmware and OpenCore filenames
below must be the ones Task 10 actually unpacked — read them out of
`docs/utm-bundle-config.md` and the `find` output recorded in `NOTES.md`.
Do not invent filenames.

```
# p1-reference -- reproduce Kostarelas's working configuration under KVM.
#
# TIER 2: this profile deliberately references vendor/reference/. That is
# the point of P1 -- boot something known to have worked, so that a failure
# is ours rather than the firmware's. bin/tier-check.sh will flag it, which
# is correct. P3 replaces every one of these paths.
#
# Provenance: docs/utm-bundle-config.md (Kostarelas, March 2026), translated
# from UTM/TCG to plain QEMU/KVM. CPU string from khronokernel 2021.

@include base-kvm

# CPU: Penryn is what khronokernel used and what 10.9 is happy with. The
# host is Coffee Lake, so this is a mask downward; 'check' makes QEMU tell
# us if it cannot provide a requested flag rather than silently dropping it.
-cpu
Penryn,vendor=GenuineIntel,+ssse3,+sse4.1,+sse4.2,+popcnt,+xsave,+xsaveopt,check

# Firmware. unit=1 is a writable per-VM copy -- never the packaged file.
-drive
if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
-drive
if=pflash,format=raw,unit=1,file=%REPO%/work/OVMF_VARS.fd

# OpenCore, from the reference bundle. Substitute the real filename.
-drive
id=opencore,if=none,format=raw,file=%REPO%/vendor/reference/utm-bundle/<OPENCORE_IMAGE>
-device
ide-hd,bus=ide.0,drive=opencore

# The installer, from Approach C.
-drive
id=installer,if=none,format=raw,readonly=on,file=%REPO%/media/images/installer-reference.img
-device
ide-hd,bus=ide.1,drive=installer

# Target disk, created in step 4.
-drive
id=target,if=none,format=qcow2,file=%REPO%/work/mavericks.qcow2
-device
ide-hd,bus=ide.2,drive=target

# DarwinKVM specifies this NIC for 10.9.
-netdev
user,id=net0
-device
e1000-82545em,netdev=net0

# Somlo's input devices. usb-tablet is a P5 experiment, not a P1 one.
-usb
-device
usb-kbd
-device
usb-mouse

# Kostarelas saw ~3 MB of VRAM under UTM and could not change it. Plain QEMU
# can, so find out early whether 10.9 notices.
-device
VGA,vgamem_mb=64

-display
gtk
```

- [ ] **Step 4: Create the target disk**

```bash
qemu-img create -f qcow2 work/mavericks.qcow2 60G
```

60G rather than the brief's 40G: this guest is for building and testing
software, Xcode-era toolchains are not small, and qcow2 only allocates what
is used.

- [ ] **Step 5: Check the command line before running it**

Run: `MQG_DRY_RUN=1 ./vm/run.sh p1-reference`

Read the output. Confirm every `file=` path exists:

```bash
MQG_DRY_RUN=1 ./vm/run.sh p1-reference | tr ' ' '\n' \
    | sed -n 's/.*file=\([^,]*\).*/\1/p' | while read -r f; do
        [ -e "$f" ] && echo "OK   $f" || echo "MISS $f"
      done
```

Expected: every line `OK`. Fix any `MISS` before booting — a missing file
produces a QEMU error that looks like a firmware problem.

- [ ] **Step 6: Boot**

Run: `./vm/run.sh p1-reference`

Expected: OVMF starts, OpenCore's picker appears, the Mavericks installer is
among the entries, and selecting it reaches the installer GUI.

- [ ] **Step 7: Work the failure tree, recording every attempt**

Prior art predicts these specific failures. Try them **one at a time**, make
each one a profile that `@include`s `p1-reference`, and write down what
happened in `NOTES.md` after every single attempt — including the ones that
changed nothing.

| Symptom | What prior art says | What to try |
|---|---|---|
| Immediate reset or `KVM: entry failed` | `ignore_msrs` | Set it (needs sudo — **ask**): `echo 1 \| sudo tee /sys/module/kvm/parameters/ignore_msrs` |
| OpenCore picker is empty, or the installer is absent | OVMF cannot read HFS+ | Confirm the OpenCore image carries an HFS+ driver. If the bundle's does not, this is the `OpenHfsPlus.efi` question arriving early. |
| No disks visible at all in the picker | khronokernel attached everything over USB | Replace the three `ide-hd` devices with `usb-storage`, one profile change. |
| Kernel panic naming the CPU or an unsupported instruction | CPU model | Fall back to Somlo's `core2duo,vendor=GenuineIntel`. If that works and Penryn does not, record it — it constrains P5's CPU experiments. |
| Panic mentioning SMC, or a "this computer is not supported" stop | applesmc | Add `-device isa-applesmc,osk=<value>` if Task 10 said the OpenCore image does not provide it. |
| Boots but hangs partway through | SMP | Somlo reports first boot needs SMP. Confirm `-smp 2` is present; try `-smp 4`. |
| Mouse does not respond under OpenCore | Known | khronokernel: navigate with Ctrl+Option+arrows. Not a bug to fix now. |

**Stop and ask if three materially different attempts at the same symptom all
fail.** That is a design stop-and-ask condition, not a suggestion.

- [ ] **Step 8: Record the working command line**

Once the installer GUI appears, append to `NOTES.md`: the full expanded
command line (from `run.log`), which of the failure-tree changes were needed,
and — importantly — which were tried and made no difference.

- [ ] **Step 9: Run the tier check, expecting it to complain**

Run: `./bin/tier-check.sh`

Expected: it reports `TIER2  p1-reference` and exits 0 with an explanation.
That is the correct result right now. Copy that output into `NOTES.md` as the
starting state P3 has to clear.

- [ ] **Step 10: Commit — this closes P1**

```bash
git add vm/profiles/ .gitignore NOTES.md
git commit -m "Reach the Mavericks installer under KVM

Closes P1. The profile deliberately references the Tier 2 quarantine and
tier-check flags it; clearing that is P3's job.

NOTES.md records what was tried and made no difference as well as what
worked, because the next person to hit this needs both.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: The instrumented manual install

**This task cannot be test-driven either.** Its real deliverable is the
click-log: P4's unattended pipeline is written against this document, so an
undocumented step becomes an automation bug months later.

**Files:**
- Create: `docs/install-log.md`
- Modify: `NOTES.md`

- [ ] **Step 1: Start the click-log before installing anything**

Create `docs/install-log.md` with this skeleton, and fill it in **as you go**,
not afterwards from memory:

```markdown
# Mavericks install: the click-log

Every step of the P2 manual install, in order, with enough detail that P4's
automation can be written against it. Anything not written here will have to
be rediscovered.

- Profile used:
- Date:
- QEMU command line: see run.log, entry at <timestamp>

## Boot to installer

| # | Screen | Action | Notes / duration |
|---|---|---|---|
| 1 | OpenCore picker | | |

## Disk Utility

Record exactly: partition scheme (GPT vs APM), format (Mac OS Extended
Journaled?), volume name, and whether any option was not the default.

| # | Screen | Action | Notes |
|---|---|---|---|

## Installer

| # | Screen | Action | Notes |
|---|---|---|---|

Wall-clock duration of the install itself:

## First boot and Setup Assistant

Every screen, every field. This is the part P4 replaces with
`.AppleSetupDone` and a first-boot payload, so the list of what Setup
Assistant actually asks is the specification.

| # | Screen | Action | Notes |
|---|---|---|---|

## Post-install state

- Account name / uid:
- Hostname:
- Network: DHCP? DNS resolving?
- Clock correct?
- Version: output of `sw_vers`
```

- [ ] **Step 2: Install**

Run: `./vm/run.sh p1-reference`

Boot the installer, use Disk Utility to format the 60G target, and install.
Fill in the click-log as you go.

Note the design's warning: **keep SMP enabled for the first boot after
install.** Somlo reports 10.9's first boot fails without it.

- [ ] **Step 3: Complete first boot and Setup Assistant**

Record every screen. If Setup Assistant cannot reach Apple's servers, **check
the guest clock first** — that is the documented first suspect.

- [ ] **Step 4: Get networking working**

Inside the guest, confirm DHCP and DNS. Kostarelas needed to set the resolver
to 1.1.1.1. If DNS fails in the installer environment rather than the
installed system, khronokernel's `scutil` recipe is the equivalent:

```
d.init
d.add ServerAddresses * 1.1.1.1
set State:/Network/Service/<PRIMARY_SERVICE_ID>/DNS
```

Record which was needed, and whether it survives a reboot.

- [ ] **Step 5: Reboot cleanly, twice**

Shut down from the Apple menu, boot again with the same profile, log in.
Do it twice. One clean reboot can be luck.

Record both boot times.

- [ ] **Step 6: Write the capability census**

The umbrella design requires this at P2, not at the end: it is the
honest-limitations list the final report owes the user, and writing it early
stops it reading like an excuse.

Append to `docs/install-log.md`:

```markdown
## Capability census

| Capability | State | Notes |
|---|---|---|
| Sound | | |
| Resolution changes | | which resolutions are offered? does 10.9 see vgamem_mb=64? |
| Sleep | | |
| Shutdown from the Apple menu | | |
| Reboot | | |
| Networking | | |
| DNS | | |
| Clock accuracy across a reboot | | |
| Safari / TLS against a modern site | | Kostarelas found the modern web mostly broken |
| Pointer feel | | qualitative; this is P5's baseline |
| App Store / Apple ID | | |
```

- [ ] **Step 7: List, but do not apply, the post-install changes**

Kostarelas recommends Apple's 2016 security update and Mavericks Forever's
optional post-install hardening script. Both are candidates, and neither gets
applied here.

Read what each one changes and write the list into `docs/install-log.md` under
a `## Deferred post-install changes` heading. Then **stop and ask** before
applying either.

The reason is measurement, not caution for its own sake: golden #1 is the
baseline every P5 experiment is compared against. A hardening script that
silently disables a service makes every later number unattributable, and
nobody will remember it was applied.

Record for each: what it changes, whether it is reversible, and whether it
would plausibly affect performance.

- [ ] **Step 8: Commit**

```bash
git add docs/install-log.md NOTES.md
git commit -m "Complete and document the first manual install

The click-log is the deliverable, not the disk image. P4's unattended
pipeline is written against this document, so a step nobody wrote down
becomes an automation bug months from now.

The capability census lands here rather than in the final report, so that
the known limitations are on the record before anyone has an incentive to
soften them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Promote golden #1 and close P2

**Files:**
- Modify: `NOTES.md`
- Modify: `docs/host-profile.md`

- [ ] **Step 1: Shut the guest down cleanly**

A golden taken from a running or crashed guest has a dirty filesystem.
Shut down from the Apple menu and wait for QEMU to exit on its own.

- [ ] **Step 2: Promote**

```bash
./vm/golden.sh promote work/mavericks.qcow2 p2-manual-install \
    "First manual install: 10.9.x via reference OpenCore + Approach C media, clean double reboot"
```

Expected: `golden/p2-manual-install.qcow2` exists, is mode 0444, and has
`.sha256` and `.meta` sidecars.

- [ ] **Step 3: Verify the promotion**

```bash
./vm/golden.sh list
./vm/golden.sh verify p2-manual-install
cat golden/p2-manual-install.meta
```

Expected: `verify` passes and the metadata records the description, date,
checksum, and `qemu-img info` output.

- [ ] **Step 4: Prove the clone workflow end to end**

This is the step that validates the whole golden/clone premise. If it does not
work, every later phase is built on sand.

```bash
./vm/clone.sh --verify p2-manual-install scratch-1
```

Then write a profile that boots the clone. Create
`vm/profiles/p2-clone-scratch1.args`:

```
# Boot the scratch-1 clone of golden p2-manual-install.
#
# Same as p1-reference but without the installer attached and pointed at a
# throwaway overlay. This profile is the template every P5 experiment
# copies: include the baseline, change one thing.

@include p1-reference-noinstaller

-drive
id=target,if=none,format=qcow2,file=%REPO%/work/scratch-1.qcow2
-device
ide-hd,bus=ide.2,drive=target
```

This needs a baseline without the installer or the target disk. Copy
`p1-reference.args` to `p1-reference-noinstaller.args`, deleting the
`installer` and `target` drive/device blocks. Do not try to make one profile
serve both roles with conditionals — the format has none, deliberately.

Boot it:

```bash
./vm/run.sh p2-clone-scratch1
```

Expected: the clone boots to the same desktop.

- [ ] **Step 5: Prove the golden was not written**

```bash
./vm/golden.sh verify p2-manual-install
```

Expected: PASS. If this fails, something wrote to the golden and the clone
mechanism is broken — **stop and fix it before going further.** Everything
after this point assumes goldens are immutable.

- [ ] **Step 6: Discard the scratch clone**

```bash
rm work/scratch-1.qcow2
```

Cheap to discard is the entire point.

- [ ] **Step 7: Update the generalization ledger**

Add to the table in `docs/host-profile.md` every host-specific thing P1 and P2
turned out to depend on. At minimum consider: the CPU model that worked, the
OVMF path and split/combined form, whether `ignore_msrs` was needed, the disk
interface that worked, and anything attributable to the `t2` kernel.

- [ ] **Step 8: Write the P0–P2 report in `NOTES.md`**

A short section covering:

- the exact working command line;
- which installer approach and which boot path were used;
- which third-party binaries are still required, and why — this is P3's
  worklist;
- what is known broken, from the capability census;
- wall-clock: install duration and both boot times.

- [ ] **Step 9: Run the whole test suite one more time**

Run: `./bin/run-tests.sh`

Expected: everything passes. None of the manual work should have broken the
library tests; if it did, find out why rather than adjusting the test.

- [ ] **Step 10: Commit — this closes P2**

```bash
git add NOTES.md docs/host-profile.md vm/profiles/
git commit -m "Promote golden #1, closing P2

The clone round-trip is verified rather than assumed: boot a clone, then
re-verify the golden's checksum. Every phase after this one assumes
goldens are immutable, so that assumption gets tested once, here, while
it is still cheap to find out otherwise.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Done means

- [ ] `./bin/run-tests.sh` passes.
- [ ] `./bin/preconditions.sh` reports GO.
- [ ] `./vm/run.sh p1-reference` reaches the Mavericks installer under KVM.
- [ ] Mavericks is installed, reboots cleanly twice, and has working networking.
- [ ] `docs/install-log.md` records every screen and click, plus the capability census.
- [ ] `golden/p2-manual-install.qcow2` exists, verifies, and a clone of it boots.
- [ ] Verifying the golden **after** booting a clone still passes.
- [ ] `./bin/tier-check.sh` names exactly the profiles that still use reference blobs — P3's worklist.
- [ ] `NOTES.md` records every attempt, including the ones that changed nothing.
- [ ] `docs/host-profile.md`'s ledger has grown.

## What comes next

P3 — the reproducible boot stack — gets its own plan. Its inputs are this
plan's outputs: golden #1 as the baseline to swap components against, and
`tier-check.sh`'s output as the list of blobs to eliminate.
