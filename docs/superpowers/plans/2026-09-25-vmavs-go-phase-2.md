# vmavs in Go, Phase 2: pins, `vmavs fetch`, and the first-boot payload

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- `vmavs fetch [esd|openssh|updates]` fetches and verifies every
  Apple and OpenSSH input the image needs, using Go's own HTTP and TLS
  (no curl, openssl, xxd or od).
- `internal/payload` builds the first-boot flat package in Go (no
  python3), with the same contents the shell tree's package has.
- Both run from one binary that carries its pins inside it.

**Architecture:**
- The binary embeds its data from where it lives today (`embed.go` at
  the repository root). Moving files into `assets/` waits for phase 6,
  because the shell tree, Renovate and the ingredient fingerprints all
  depend on the current paths.
- `internal/pins` reads the registry and computes the ingredient digest,
  byte-identical to `bin/ingredient-fingerprint.sh`.
- `internal/fetch` has one verified-download primitive (`Getter.Get`):
  - a content-addressed cache, `cache/<sha256>/<filename>`;
  - verify before rename;
  - retries;
  - adoption of files the shell tree already downloaded.

  On top of it sit three fetchers: `OpenSSH`, `Updates` and
  `InstallESD` (Apple's osrecovery handshake).
- `internal/payload` writes odc cpio, a deterministic gzip and a xar
  archive. It also assembles `firstboot.conf` and `postinstall` exactly
  the way `build-firstboot-pkg.sh` does.

**Tech Stack:**
- Go 1.26 standard library: `net/http`, `crypto/sha256`, `crypto/sha1`,
  `compress/zlib`, `compress/gzip`, `embed`.
- The same third-party modules as phase 1, with no new ones.

**Spec:** `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`:
- §2: `vmavs fetch`, and the conventions;
- §3: layout, embedded data;
- §5: `cache/` and state;
- §7: parity tests, and carrying the bats knowledge into Go;
- §9: phase 2.

Also `docs/decisions/0013-vmavs-is-a-go-program.md`.

## Global Constraints

- `go.mod` stays `go 1.26.0`. Use plain `go` commands; never set
  `GOFLAGS`. Add no new module dependency.
- **The shell tree must keep working unchanged.**
  - Don't edit shell files, `NOTES.md` history, `assets/pins/sources.tsv`,
    `components/`, `boot/config/`, `image/payload/` or
    `media/apple-packages.sha256`.
  - `./bin/run-tests.sh` exits 0 (check the code directly:
    `./bin/run-tests.sh >FILE 2>&1; echo $?`).
  - `bin/ingredient-fingerprint.sh` prints the same digest before and
    after, `a864536bf4402c760eb1b284a7b0f64f5f691485b3971a0f1cd7797554aa1d82`
    as of 2026-09-25.
- **Never publish or embed Apple's bytes.** Test fixtures are fake:
  files beginning `xar!` followed by filler text. No test downloads from
  the network; use `httptest`. Only Task 11 touches the real network.
- **Packages have fixed jobs.**
  - Flags and argv live only in `internal/cli`.
  - Every path under `VMAVS_HOME` comes from `internal/config`.
  - External programs run through `proc.Runner`.
  - The phase 1 final review asked for all three; Task 1 finishes the
    flags one.
- **Conventions are spec §2's:** exit codes 0/1/2, signals, `vmavs <cmd>:`
  logging on stderr, and stdout carrying only output.
- **Every claim is MEASURED, INHERITED or REASONED, and says which.**
  - A measurement records `date -u +%FT%TZ` when it is taken; the phase 1
    review found two date slips.
  - A task that changes CI, or the source of a MEASURED claim, greps for
    every claim that depends on it and updates them in the same task.
  - A task that declares a phase exit met quotes the exit criterion and
    checks each clause.
- **Deletion:** only delete what you can prove you created.
- `go test -race ./...`, `go vet ./...` and
  `go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` are clean,
  and the build succeeds for linux/amd64, darwin/amd64, darwin/arm64 and
  netbsd/amd64.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QX6srqxQqri25igdYHqmNo
  ```

## Facts this plan relies on

MEASURED on 2026-09-25, by reading the files named, unless marked
otherwise.

- **The registry, `assets/pins/sources.tsv` (read by `lib/vendor.sh`).**
  - Each row is `name<TAB>url<TAB>sha256`.
  - A line whose first character is `#` is a comment. A blank line is
    ignored.
  - `sha256` = `TOFU` means "not yet known" (a developer-time feature).
    Lookup is an exact match on name; the first matching row wins.
  - Missing sha column: `source_field` returns an empty string with
    status 0.
  - Every ingredient row a release depends on has a real checksum today.
- **The ingredient digest (`bin/ingredient-fingerprint.sh`).**
  1. It collects rows `name<TAB>value` from three places:
     - every sources.tsv line that is not a comment, has ≥3 tab-separated
       fields and a non-empty name, giving `name<TAB>field3`;
     - each `components/*/version`, whose value is its first
       non-comment, non-blank line with all whitespace removed;
     - `config.plist<TAB><sha256 of boot/config/config.plist>`.
  2. It sorts the rows in `LC_ALL=C` order.
  3. It joins them with a newline after every row.
  4. The digest is the lowercase hex SHA-256 of that text.

  Today: 28 rows, digest
  `a864536bf4402c760eb1b284a7b0f64f5f691485b3971a0f1cd7797554aa1d82`.
- **`components/openssh/version`** is `10.5p1-mavericks.2`.
- **fetch-openssh.sh.**
  - Download base: `https://github.com/Mavergreen/openssh/releases/download/<tag>/`.
  - It fetches `SHA256SUMS` from there. Each line is
    `<hex><whitespace><name>`; only names ending `.pkg` count.
  - A name containing `System-Replace` or `system-replace` is the
    replacement package; the other `.pkg` is the base.
  - It dies on two of either kind, or on a missing one.
  - Each package is verified against its SUMS line, then checked for the
    `xar!` magic.
  - Output order: base first, then replace.
- **fetch-updates.sh.**
  - The selection is `none`, `security` or `all`; the image default is
    `security` (`docs/decisions/0011`).
  - `security` = `apple-secupd-2016-004`.
  - `all` = that, then `apple-safari-9.1.3`, `apple-itunes-12.6.2-corefp`,
    `-mobiledevice`, `-itunesaccess`, `-itunesx` and `-coreadi`, in
    install order.
  - Each package is fetched through the registry and must start with
    `xar!`.
  - It is presented to the payload as `staged/mqg-update-NN-<basename>`,
    where NN is the 1-based install order, two digits.
- **fetch-installesd.sh** (the handshake from Mavericks Forever's
  `get.sh`; INHERITED there, MEASURED working in this project's
  installs).
  1. GET `http://osrecovery.apple.com/`. Its cookie value is the server
     id, which must contain `~`.
  2. `client_id` = 8 random bytes, as uppercase hex.
  3. `key` = uppercase hex of SHA-256 over the concatenation of:
     - `client_id` bytes;
     - the hex-decoded part of `server_id` after `~`;
     - the hex-decoded ROM `003EE1E6AC14`;
     - SHA-256(`C0243070168G3M91F` + `Mac-3CBD00234E554E41`);
     - ten `0xCC` bytes.
  4. POST `http://osrecovery.apple.com/InstallationPayload/OSInstaller`
     with:
     - header `Content-Type: text/plain`;
     - cookie `session=<server_id>`;
     - body `cid=<client_id>\nsn=C0243070168G3M91F\nbid=Mac-3CBD00234E554E41\nk=<key>`.
  5. The response has lines `AU: <asset url>` and `AT: <token>`.
  6. The asset URL must equal the registry's
     `apple-installesd-10.9.5` URL.
  7. Download the asset with header `Cookie: AssetToken=<token>` over
     plain HTTP. Verify before renaming into place.

  Known-answer vector, computed on 2026-09-25 with the shell pipeline
  itself (openssl, xxd, od): for `client_id=0123456789ABCDEF` and
  `server_id=001~0A1B2C3D4E5F60718293A4B5C6D7E8F9`, the key is
  `1DAC930DE453BFCF3A196011CEB952D85B53C72E6D8C8340E7D35D1F3CD5079F`.
- **`image/payload/mkflatpkg.py`.** The xar layout:
  - The header is `xar!`, then u16 28, u16 1, u64 compressed TOC length,
    u64 uncompressed TOC length, u32 1 (SHA-1), all big-endian.
  - The TOC is zlib level 9. Its XML is exactly the template in Task 9.
  - The heap starts with the 20-byte SHA-1 of the *compressed* TOC.
    Members follow, stored raw and sorted by name.
  - Every timestamp is `1970-01-01T00:00:00Z`, and `creation-time` is
    `1970-01-01T00:00:00`.

  The members:
  - `PackageInfo`, in the template in Task 9;
  - `Scripts`, a gzip (level 9, mtime 0) of an odc cpio with entries `.`
    (040755), `./postinstall` (100755 if executable) and `TRAILER!!!`.
    Every entry has ino from 1, uid/gid 0, nlink 1 and mtime 0.
- **`image/payload/build-firstboot-pkg.sh`.**
  - Defaults: user `mavsuser`, uid 501, gid 20, realname
    `Mavericks User`, hostname `mavericks`, shell `/bin/bash`, autologin
    1, no password.
  - `firstboot.conf` lines are `printf '%q'`-quoted, in the order Task 10
    shows.
  - `postinstall` is the template `image/payload/postinstall` with its
    `#MQG_EMBEDDED_FILES\n` line replaced (once) by four heredoc blocks
    written by `embed()`.
  - The script runs `sh -n` on the result.
  - The key rules: an Ed25519 key is refused without the OpenSSH
    packages; a `.pub` that looks PRIVATE is refused.
  - Package names containing whitespace are refused, and so are packages
    without the `xar!` magic.
  - It writes a `<out>.sha256` sidecar, `<hex>  <basename>`.
- **The shell tree's download locations on this host**, under
  `$HOME/.local/share/mavericks-qemu-guest` (the old home):
  - `media/InstallESD.dmg`;
  - `openssh/10.5p1-mavericks.2/{SHA256SUMS,*.pkg}`;
  - `updates/<basename>.pkg`;
  - `build/<basename>` for the firmware sources.

## File structure

| Path | Responsibility |
|---|---|
| `embed.go`, `embed_test.go` (root package `vmguest`) | embed the pins, the OpenSSH version, `config.plist`, `apple-packages.sha256` and the three payload templates; the test checks the embedded bytes equal the files on disk |
| `internal/cli/machineflags.go` | `registerMachine`: machine flags move here from config (Task 1) |
| `internal/pins/pins.go`, `pins_test.go` | registry parse/lookup, component versions, ingredient rows and digest |
| `internal/config/config.go` | `Paths.CacheFile`, `LegacyHome`, the update-selection constants |
| `internal/fetch/get.go`, `get_test.go` | `Getter`, `Item`, `Filename`, `SHA256File`, `HasXarMagic` |
| `internal/fetch/openssh.go`, `openssh_test.go` | the OpenSSH release fetch |
| `internal/fetch/updates.go`, `updates_test.go` | update selections, `StagedName` |
| `internal/fetch/esd.go`, `esd_test.go` | the osrecovery handshake, `InstallESD`, `Probe` |
| `internal/cli/fetch.go`, `fetch_test.go` | the `vmavs fetch` subcommand |
| `internal/doctor/doctor.go` | a `fetch` readiness row |
| `internal/payload/cpio.go`, `xar.go`, `container_test.go` | odc cpio, deterministic gzip, xar writer, and readers for tests |
| `internal/payload/payload.go`, `quote.go`, `payload_test.go` | `Config`, `Conf`, `Postinstall`, `Build`, `bashQuote` |
| `.github/workflows/ci.yml` | a `go-macos` job |

---

### Task 1: Flags only in `cli`, and CI tests on macOS

**Files:**
- Create: `internal/cli/machineflags.go`, `internal/cli/machineflags_test.go`
- Modify: `internal/config/machine.go` (delete `Register`), `internal/config/config_test.go` (move `TestMachineFlagsOverrideOnlyWhatWasSet` out), `internal/cli/run.go`, `internal/cli/emit.go`, `internal/cli/cli.go` (package comment), `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `config.Machine`, `config.NICChoices`.
- Produces: `registerMachine(fs *flag.FlagSet, m *config.Machine)` in package `cli`. `config.Machine` keeps `Override` and `Validate`; its `Register` method is gone.

- [ ] **Step 1: Move the test first, rewritten against the new home**

Delete `TestMachineFlagsOverrideOnlyWhatWasSet` from `internal/config/config_test.go` (and any import it leaves unused). Create `internal/cli/machineflags_test.go`:

```go
package cli

import (
	"flag"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
)

func TestMachineFlagsOverrideOnlyWhatWasSet(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	flagged := config.DefaultMachine()
	registerMachine(fs, &flagged)
	if err := fs.Parse([]string{"--memory", "8192"}); err != nil {
		t.Fatal(err)
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	fromImage := config.DefaultMachine()
	fromImage.NIC = "usb-net"
	fromImage.Override(flagged, func(n string) bool { return set[n] })
	if fromImage.MemoryMB != 8192 || fromImage.NIC != "usb-net" {
		t.Fatalf("got %+v", fromImage)
	}
}

func TestEveryMachineFlagIsRegistered(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	m := config.DefaultMachine()
	registerMachine(fs, &m)
	for _, name := range []string{"accel", "cpu", "memory", "smp", "nic", "ssh-port", "display"} {
		if fs.Lookup(name) == nil {
			t.Errorf("no --%s", name)
		}
	}
}
```

Run: `go test ./internal/cli/ -run Machine` → FAIL (`registerMachine` undefined).

- [ ] **Step 2: Implement `internal/cli/machineflags.go`; delete `config.Machine.Register`**

```go
package cli

import (
	"flag"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
)

// registerMachine adds the machine flags every machine-using subcommand
// shares, bound to m. It lives here, not in config, because flags are the
// command line's business: config owns the defaults, cli owns argv.
func registerMachine(fs *flag.FlagSet, m *config.Machine) {
	fs.StringVar(&m.Accel, "accel", m.Accel, "accelerator: kvm, hvf, nvmm or tcg")
	fs.StringVar(&m.CPU, "cpu", m.CPU, "QEMU -cpu line (docs/decisions/0009)")
	fs.IntVar(&m.MemoryMB, "memory", m.MemoryMB, "guest memory in MiB")
	fs.IntVar(&m.SMP, "smp", m.SMP, "guest CPUs")
	fs.StringVar(&m.NIC, "nic", m.NIC, "network device: "+strings.Join(config.NICChoices, ", "))
	fs.IntVar(&m.SSHPort, "ssh-port", m.SSHPort, "host port forwarded to the guest's port 22")
	fs.StringVar(&m.Display, "display", m.Display, "QEMU -display: none, gtk, sdl or cocoa")
}
```

- Delete the `Register` method from `internal/config/machine.go` and drop the `flag` import if nothing else uses it.
- Replace `flagged.Register(fs)` in `run.go` and `hw.Register(fs)` in `emit.go` with `registerMachine(fs, &flagged)` and `registerMachine(fs, &hw)`.
- Rewrite `cli.go`'s package comment to say that `cli` is the only package that knows about flags or argv. The parenthetical about `config.Machine.Register` is now false.
- Run `grep -rn 'Register' internal/ docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` and fix any claim that `config` registers flags.

Run: `go test -race ./... && go vet ./...` → PASS.

- [ ] **Step 3: A macOS test job**

The `go` job cross-builds for darwin but never runs the tests there, so flock and `sun_path` behaviour on macOS go untested (phase 1 final review, M15). Append to `.github/workflows/ci.yml`:

```yaml

  # The go job cross-builds for darwin; this one RUNS the tests there.
  # flock semantics, sun_path's 104-byte limit and signal delivery are
  # host behaviour a cross-build cannot check.
  go-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-go@v7.0.0
        with:
          go-version-file: go.mod

      - name: Test
        run: go test -race ./...
```

Validate the YAML. You cannot run macOS here. Before committing, run `GOOS=darwin go vet ./...` and read every test that uses Linux-only paths (`/proc`, `/sys`, `/dev/kvm`) or tools. They must be injected (as `doctor`'s tests are) or build-tagged `linux` (as the TERM/pty tests are). Tag any that aren't, and say which in the report.

- [ ] **Step 4: Run all checks; commit**

```bash
go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
for t in linux/amd64 darwin/amd64 darwin/arm64 netbsd/amd64; do GOOS=${t%/*} GOARCH=${t#*/} go build -o /dev/null ./cmd/vmavs; done
git add internal .github/workflows/ci.yml docs
git commit   # subject: "cli owns the machine flags; CI runs the Go tests on macOS too"
```

---

### Task 2: The binary carries its data (`embed.go`)

**Files:**
- Modify: `embed.go` (root package `vmguest`)
- Create: `embed_test.go` (root package)

**Interfaces:**
- Produces: `vmguest.Files embed.FS`, holding repository-relative paths:
  - `assets/pins/sources.tsv`
  - `components/openssh/version`
  - `boot/config/config.plist`
  - `media/apple-packages.sha256`
  - `image/payload/firstboot.sh`
  - `image/payload/postinstall`
  - `image/payload/com.mqg.firstboot.plist`

  `vmguest.UpstreamVersion` is unchanged.

**Why these files stay where they are:** spec §3 puts them under `assets/`. But the shell tree reads them at these paths, and so do Renovate (`managerFilePatterns`) and CI (`verify-changed-sources.sh`). The ingredient fingerprints hash them by path too: `tree_digest payload image/payload`. Moving them now would change every stage digest of every built image. The move happens in phase 6, with the shell tree. Step 3 amends the spec.

- [ ] **Step 1: Write the failing test**

`embed_test.go` (package `vmguest`, at the repository root, so the working directory is the root):

```go
package vmguest

import (
	"bytes"
	"io/fs"
	"os"
	"testing"
)

// The embedded copies must be the files in this tree: a binary built from
// this commit carries exactly what this commit says.
func TestEmbeddedFilesAreTheFilesOnDisk(t *testing.T) {
	want := []string{
		"assets/pins/sources.tsv",
		"components/openssh/version",
		"boot/config/config.plist",
		"media/apple-packages.sha256",
		"image/payload/firstboot.sh",
		"image/payload/postinstall",
		"image/payload/com.mqg.firstboot.plist",
	}
	for _, p := range want {
		emb, err := fs.ReadFile(Files, p)
		if err != nil {
			t.Errorf("%s not embedded: %v", p, err)
			continue
		}
		disk, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(emb, disk) || len(emb) == 0 {
			t.Errorf("%s: embedded copy differs from the file on disk", p)
		}
	}
}
```

Run: `go test .` → FAIL (`Files` undefined).

- [ ] **Step 2: Add `Files` to `embed.go`**

Keep `UpstreamVersion` as it is, and add:

```go
import "embed"

// Files is the data vmavs carries inside its binary, at the paths the
// repository keeps them (spec §3; the move to assets/ waits for phase 6,
// because the shell tree, Renovate and the ingredient fingerprints all
// read these paths today).
//
//go:embed assets/pins/sources.tsv components/openssh/version boot/config/config.plist media/apple-packages.sha256 image/payload/firstboot.sh image/payload/postinstall image/payload/com.mqg.firstboot.plist
var Files embed.FS
```

(Keep the existing `_ "embed"` import if `UpstreamVersion` needs it; one `embed` import covers both.)

- [ ] **Step 3: Amend spec §3**

In `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` §3, after the `assets/` paragraph, add one short paragraph:
- until phase 6, `embed.go` embeds these files from their current paths;
- the move to `assets/` happens with the shell tree's removal;
- the reason is that the shell tree, Renovate's `managerFilePatterns`, CI's `verify-changed-sources.sh` and the path-keyed ingredient fingerprints all read them there today.

- [ ] **Step 4: Run; commit**

```bash
go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add embed.go embed_test.go docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md
git commit   # subject: "vmavs carries its pins and payload templates in its binary"
```

---

### Task 3: `internal/pins`: the registry and the ingredient digest

**Files:**
- Create: `internal/pins/pins.go`, `internal/pins/pins_test.go`

**Interfaces:**
- Consumes: `vmguest.Files`.
- Produces:
  - `pins.Source{Name, URL, SHA256 string}`
  - `pins.Registry`, with:
    - `pins.Parse(r io.Reader) (*Registry, error)`
    - `pins.Embedded() (*Registry, error)`
    - `(*Registry).Lookup(name string) (Source, error)`: refuses `TOFU` and empty checksums
    - `(*Registry).Rows() []Source`
  - `pins.ComponentVersion(data []byte) string`
  - `pins.Ingredients() ([]string, error)`: the sorted `name\tvalue` rows, from the embedded files
  - `pins.Digest(rows []string) string`

- [ ] **Step 1: Write the failing tests**

`internal/pins/pins_test.go`:

```go
package pins

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const tsv = "# comment\n" +
	"alpha\thttps://example.test/a.tar.gz\t1111\n" +
	"\n" +
	"alpha.beta\thttps://example.test/ab.zip\t2222\n" +
	"tofu\thttps://example.test/t.zip\tTOFU\n" +
	"nosha\thttps://example.test/n.zip\n" +
	"alpha\thttps://example.test/second.tar.gz\t3333\n"

func reg(t *testing.T) *Registry {
	r, err := Parse(strings.NewReader(tsv))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestLookupIsExactAndFirstMatchWins(t *testing.T) {
	s, err := reg(t).Lookup("alpha")
	if err != nil || s.URL != "https://example.test/a.tar.gz" || s.SHA256 != "1111" {
		t.Fatalf("%+v %v", s, err)
	}
	if _, err := reg(t).Lookup("alph"); err == nil {
		t.Fatal("a prefix must not match")
	}
	if _, err := reg(t).Lookup("alpha.beta"); err != nil {
		t.Fatal("a dotted name is a literal, not a pattern")
	}
	if _, err := reg(t).Lookup("alphaXbeta"); err == nil {
		t.Fatal("a dot must not match any character")
	}
}

func TestLookupRefusesAnUnpinnedSource(t *testing.T) {
	for _, n := range []string{"tofu", "nosha"} {
		_, err := reg(t).Lookup(n)
		if err == nil || !strings.Contains(err.Error(), n) || !strings.Contains(err.Error(), "pinned") {
			t.Errorf("%s: err = %v", n, err)
		}
	}
	if _, err := reg(t).Lookup("#"); err == nil {
		t.Fatal("a comment is not a source")
	}
}

func TestComponentVersion(t *testing.T) {
	if v := ComponentVersion([]byte("# pin\n\n  10.5p1-mavericks.2  # note\n")); v != "10.5p1-mavericks.2" {
		t.Fatalf("got %q", v)
	}
}

func TestEmbeddedRegistryHasEveryReleasePin(t *testing.T) {
	r, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"apple-installesd-10.9.5", "apple-secupd-2016-004", "opencorepkg-src"} {
		if _, err := r.Lookup(n); err != nil {
			t.Errorf("%s: %v", n, err)
		}
	}
}

// Parity with bin/ingredient-fingerprint.sh: every built image's manifest
// records that digest, and bin/image-staleness.sh compares against it, so
// Go and shell must agree to the byte.
func TestIngredientsMatchTheShellFingerprint(t *testing.T) {
	_, here, _, _ := runtime.Caller(0)
	root := filepath.Join(filepath.Dir(here), "..", "..")
	script := filepath.Join(root, "bin", "ingredient-fingerprint.sh")
	if _, err := exec.LookPath("sha256sum"); err != nil {
		t.Skip("sha256sum not available; CI runs this")
	}
	list, err := exec.Command(script, "--list").Output()
	if err != nil {
		t.Fatal(err)
	}
	digest, err := exec.Command(script).Output()
	if err != nil {
		t.Fatal(err)
	}
	rows, err := Ingredients()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(rows, "\n") + "\n"; got != string(list) {
		t.Fatalf("rows differ from `ingredient-fingerprint.sh --list`:\n%s\nvs\n%s", got, list)
	}
	if got := Digest(rows); got != strings.TrimSpace(string(digest)) {
		t.Fatalf("digest %s, shell says %s", got, digest)
	}
}
```

Run: `go test ./internal/pins/` → FAIL (package missing).

- [ ] **Step 2: Implement `internal/pins/pins.go`**

```go
// Package pins reads what this repository pins: the source registry
// (assets/pins/sources.tsv), whole-file component versions
// (components/*/version), and the ingredient digest over all of it, which
// every built image's manifest records. The rules are lib/vendor.sh's and
// bin/ingredient-fingerprint.sh's, to the byte.
package pins

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"sort"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
)

type Source struct{ Name, URL, SHA256 string }

type Registry struct {
	rows []Source
	// fields counts each row's tab-separated fields: the ingredient digest
	// counts only rows with three or more, exactly as awk NF >= 3 does.
	fields []int
}

// Parse reads sources.tsv: name<TAB>url<TAB>sha256, lines starting with #
// are comments, blank lines are ignored.
func Parse(r io.Reader) (*Registry, error) {
	reg := &Registry{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		s := Source{Name: f[0]}
		if len(f) > 1 {
			s.URL = f[1]
		}
		if len(f) > 2 {
			s.SHA256 = f[2]
		}
		reg.rows = append(reg.rows, s)
		reg.fields = append(reg.fields, len(f))
	}
	return reg, sc.Err()
}

// Embedded is the registry this binary was built with.
func Embedded() (*Registry, error) {
	f, err := vmguest.Files.Open("assets/pins/sources.tsv")
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Parse(f)
}

// Lookup is the first row named exactly name. A source whose checksum is
// not yet known (TOFU, or no column at all) is refused: this binary
// verifies what it downloads, and pinning a new source is a developer's
// job (the shell tree's lib/vendor.sh pin_checksum, until phase 6).
func (r *Registry) Lookup(name string) (Source, error) {
	if name == "" || strings.HasPrefix(name, "#") {
		return Source{}, fmt.Errorf("no source named %q", name)
	}
	for _, s := range r.rows {
		if s.Name != name {
			continue
		}
		if s.SHA256 == "" || s.SHA256 == "TOFU" {
			return Source{}, fmt.Errorf("source %s is not pinned (sha256 %q); pin it before fetching", name, s.SHA256)
		}
		return s, nil
	}
	return Source{}, fmt.Errorf("no source named %q in the registry", name)
}

func (r *Registry) Rows() []Source { return append([]Source(nil), r.rows...) }

// ComponentVersion is a components/<name>/version file's pin: the first
// line that is not blank once # comments and all whitespace are removed.
func ComponentVersion(data []byte) string {
	for _, line := range strings.Split(string(data), "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		line = strings.Join(strings.Fields(line), "")
		if line != "" {
			return line
		}
	}
	return ""
}

// Ingredients is bin/ingredient-fingerprint.sh --list: every registry row
// with three or more fields and a name, every component version, and
// config.plist's checksum, as name<TAB>value, sorted bytewise.
func Ingredients() ([]string, error) {
	reg, err := Embedded()
	if err != nil {
		return nil, err
	}
	var rows []string
	for i, s := range reg.rows {
		if reg.fields[i] >= 3 && s.Name != "" {
			rows = append(rows, s.Name+"\t"+s.SHA256)
		}
	}
	versions, err := fs.Glob(vmguest.Files, "components/*/version")
	if err != nil {
		return nil, err
	}
	for _, v := range versions {
		data, err := fs.ReadFile(vmguest.Files, v)
		if err != nil {
			return nil, err
		}
		name := strings.TrimSuffix(strings.TrimPrefix(v, "components/"), "/version")
		rows = append(rows, name+"\t"+ComponentVersion(data))
	}
	plist, err := fs.ReadFile(vmguest.Files, "boot/config/config.plist")
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(plist)
	rows = append(rows, "config.plist\t"+hex.EncodeToString(sum[:]))
	sort.Strings(rows)
	return rows, nil
}

// Digest is sha256sum over the rows, one per line, each newline-terminated.
func Digest(rows []string) string {
	h := sha256.New()
	for _, r := range rows {
		io.WriteString(h, r+"\n")
	}
	return hex.EncodeToString(h.Sum(nil))
}
```

Note: `embed.go` embeds `components/openssh/version` by exact path. When a second component is added, the embed pattern must name it, or this glob will silently miss it. Add that warning as a comment beside the `//go:embed` line in `embed.go`.

- [ ] **Step 3: Run; commit**

Run: `go test -race ./internal/pins/` → PASS. The parity test must *run*, not skip, on this host (sha256sum is present). Paste its output in the report.

```bash
go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add internal/pins embed.go
git commit   # subject: "pins: the registry, and an ingredient digest identical to the shell's"
```

---

### Task 4: `internal/fetch`: one verified download, cached by checksum

**Files:**
- Create: `internal/fetch/get.go`, `internal/fetch/get_test.go`
- Modify: `internal/config/config.go`: add `Paths.CacheFile`, `LegacyHome`

**Interfaces:**
- Produces:
  - `config.Paths.CacheFile(sha256, filename string) string` = `<home>/cache/<sha256>/<filename>`
  - `config.LegacyHome(getenv) string`, the shell tree's home (`$HOME/.local/share/mavericks-qemu-guest`), or ""
  - `fetch.Getter{Client *http.Client; Paths config.Paths; Log func(string, ...any); Retries int; Backoff time.Duration}`
  - `fetch.Item{Name, URL, SHA256, Filename string; Header http.Header; Adopt []string}`
  - `(*Getter).Get(ctx, Item) (string, error)`
  - `fetch.Filename(url string) (string, error)`
  - `fetch.SHA256File(path string) (string, error)`
  - `fetch.HasXarMagic(path string) (bool, error)`

**The rules** (from `lib/vendor.sh fetch_source`, adapted to a content-addressed cache):
- The filename comes from the URL's last path segment, with the query string kept verbatim. A URL with no path (`https://host`) or a trailing `/` is refused, and the error says why.
- If the cache already holds the file, it is verified. A match is returned without touching the network. A mismatch is an error naming both checksums, and the file is left alone.
- Otherwise each `Adopt` path is tried in order: a file that exists and matches is hard-linked into the cache, or copied if a link fails, via `.part` then rename, and logged as "adopted". A mismatching one is logged and skipped.
- Otherwise the file is downloaded to `<dest>.part` while being hashed, verified, and renamed into place. A checksum mismatch is an error; the `.part` stays for inspection and the next attempt truncates it. **Nothing unverified is ever renamed to its final name.**
- Retries: 3 attempts after the first, backing off (1 s, 2 s, 4 s by default; tests set `Backoff` to 1 ms). Network errors and HTTP 5xx are retried; 4xx is not, and the error names the status and URL.
- A download over 64 MiB logs progress every 10 s to `Log`.

- [ ] **Step 1: Write the failing tests**

`internal/fetch/get_test.go`:

```go
package fetch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

func sum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func getter(t *testing.T) *Getter {
	return &Getter{Paths: config.Paths{Home: t.TempDir()}, Backoff: time.Millisecond, Log: func(string, ...any) {}}
}

func TestFilenameRules(t *testing.T) {
	for url, want := range map[string]string{
		"https://h/x/a.zip":       "a.zip",
		"https://h/x/a.zip?v=2":   "a.zip?v=2",
		"http://h/InstallESD.dmg": "InstallESD.dmg",
	} {
		if got, err := Filename(url); err != nil || got != want {
			t.Errorf("%s: %q %v", url, got, err)
		}
	}
	for _, bad := range []string{"https://h", "https://h/x/"} {
		if _, err := Filename(bad); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
}

func TestGetDownloadsVerifiesAndCaches(t *testing.T) {
	body := []byte("payload bytes")
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	it := Item{Name: "x", URL: srv.URL + "/d/x.zip", SHA256: sum(body)}
	p, err := g.Get(context.Background(), it)
	if err != nil || p != g.Paths.CacheFile(sum(body), "x.zip") {
		t.Fatalf("%q %v", p, err)
	}
	if _, err := g.Get(context.Background(), it); err != nil || hits != 1 {
		t.Fatalf("second Get must use the cache: hits=%d err=%v", hits, err)
	}
}

func TestAMismatchedDownloadNeverTakesItsFinalName(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("evil")) }))
	defer srv.Close()
	g := getter(t)
	want := sum([]byte("good"))
	_, err := g.Get(context.Background(), Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: want})
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(g.Paths.CacheFile(want, "x.zip")); !os.IsNotExist(err) {
		t.Fatal("an unverified download was renamed into place")
	}
}

func TestARotCachedFileIsAnErrorNotARedownload(t *testing.T) {
	g := getter(t)
	want := sum([]byte("good"))
	dest := g.Paths.CacheFile(want, "x.zip")
	os.MkdirAll(filepath.Dir(dest), 0o755)
	os.WriteFile(dest, []byte("rotted"), 0o644)
	_, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: want})
	if err == nil || !strings.Contains(err.Error(), dest) {
		t.Fatalf("err = %v", err)
	}
}

func TestAdoptionReusesAVerifiedFileWithoutTheNetwork(t *testing.T) {
	g := getter(t)
	body := []byte("already downloaded by the shell tree")
	old := filepath.Join(t.TempDir(), "x.zip")
	os.WriteFile(old, body, 0o644)
	bad := filepath.Join(t.TempDir(), "x.zip")
	os.WriteFile(bad, []byte("wrong"), 0o644)
	var logged []string
	g.Log = func(f string, a ...any) { logged = append(logged, f) }
	p, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: sum(body), Adopt: []string{bad, old}})
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != string(body) {
		t.Fatal("adopted file differs")
	}
	if b, _ := os.ReadFile(old); string(b) != string(body) {
		t.Fatal("adoption must not disturb the original")
	}
}

func TestRetriesServerErrorsButNotClientErrors(t *testing.T) {
	body := []byte("ok")
	var n int32
	flaky := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&n, 1) < 3 {
			w.WriteHeader(503)
			return
		}
		w.Write(body)
	}))
	defer flaky.Close()
	g := getter(t)
	if _, err := g.Get(context.Background(), Item{Name: "f", URL: flaky.URL + "/f", SHA256: sum(body)}); err != nil || n != 3 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	var m int32
	gone := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&m, 1)
		w.WriteHeader(404)
	}))
	defer gone.Close()
	_, err := g.Get(context.Background(), Item{Name: "g", URL: gone.URL + "/g", SHA256: sum(body)})
	if err == nil || m != 1 || !strings.Contains(err.Error(), "404") {
		t.Fatalf("m=%d err=%v", m, err)
	}
}

func TestHeadersAreSent(t *testing.T) {
	body := []byte("tok")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "AssetToken=abc" {
			w.WriteHeader(403)
			return
		}
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	h := http.Header{}
	h.Set("Cookie", "AssetToken=abc")
	if _, err := g.Get(context.Background(), Item{Name: "t", URL: srv.URL + "/t", SHA256: sum(body), Header: h}); err != nil {
		t.Fatal(err)
	}
}

func TestHasXarMagic(t *testing.T) {
	d := t.TempDir()
	good, bad := filepath.Join(d, "g.pkg"), filepath.Join(d, "b.pkg")
	os.WriteFile(good, []byte("xar!fake"), 0o644)
	os.WriteFile(bad, []byte("PK\x03\x04"), 0o644)
	if ok, _ := HasXarMagic(good); !ok {
		t.Fatal("xar! not recognised")
	}
	if ok, _ := HasXarMagic(bad); ok {
		t.Fatal("zip taken for xar")
	}
}
```

Run: `go test ./internal/fetch/` → FAIL.

- [ ] **Step 2: Add the config paths**

In `internal/config/config.go`:

```go
// CacheFile is where a downloaded input with this checksum and filename
// lives: content-addressed, so a changed pin is a different file and a
// cached file can always be re-verified against its own directory name.
func (p Paths) CacheFile(sha256, filename string) string {
	return filepath.Join(p.Cache(), sha256, filename)
}

// LegacyHome is the shell tree's state directory, whose downloads vmavs
// fetch adopts (verified) instead of downloading again. "" without HOME.
func LegacyHome(getenv func(string) string) string {
	if h := getenv("HOME"); h != "" {
		return filepath.Join(h, ".local", "share", "mavericks-qemu-guest")
	}
	return ""
}
```

Refactor `LegacyHint` to use `LegacyHome` rather than rebuilding the path, and add tests for both new functions to `config_test.go`.

- [ ] **Step 3: Implement `internal/fetch/get.go`**

```go
// Package fetch downloads this project's pinned inputs, verified. One
// primitive, Getter.Get, does every download; the fetchers for Apple's
// installer, the updates and the guest's OpenSSH are built on it.
package fetch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

type Getter struct {
	Client  *http.Client // nil: http.DefaultClient
	Paths   config.Paths
	Log     func(format string, a ...any)
	Retries int           // attempts after the first; 0 means 3
	Backoff time.Duration // first retry's wait, doubling; 0 means 1s
}

type Item struct {
	Name     string // for messages
	URL      string
	SHA256   string
	Filename string // "" derives it from URL
	Header   http.Header
	Adopt    []string // existing files to verify and reuse before downloading
}

// Filename is the URL's last path segment, query string and all, as
// lib/vendor.sh fetch_source derives it.
func Filename(url string) (string, error) {
	i := strings.Index(url, "://")
	if i < 0 || !strings.Contains(url[i+3:], "/") {
		return "", fmt.Errorf("cannot derive a filename from %s -- it has no path; add one to the registry entry", url)
	}
	name := url[strings.LastIndex(url, "/")+1:]
	if name == "" {
		return "", fmt.Errorf("cannot derive a filename from %s -- it ends in \"/\"", url)
	}
	return name, nil
}

func (g *Getter) Get(ctx context.Context, it Item) (string, error) {
	name := it.Filename
	if name == "" {
		var err error
		if name, err = Filename(it.URL); err != nil {
			return "", err
		}
	}
	dest := g.Paths.CacheFile(it.SHA256, name)
	if _, err := os.Stat(dest); err == nil {
		got, err := SHA256File(dest)
		if err != nil {
			return "", err
		}
		if got != it.SHA256 {
			return "", fmt.Errorf("checksum mismatch for %s: want %s, got %s (remove it to fetch again)", dest, it.SHA256, got)
		}
		return dest, nil
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}
	for _, old := range it.Adopt {
		if got, err := SHA256File(old); err == nil {
			if got == it.SHA256 {
				if err := adopt(old, dest); err != nil {
					return "", err
				}
				g.logf("%s: adopted %s (verified)", it.Name, old)
				return dest, nil
			}
			g.logf("%s: not adopting %s: checksum %s, want %s", it.Name, old, got, it.SHA256)
		}
	}
	if err := g.download(ctx, it, dest); err != nil {
		return "", err
	}
	return dest, nil
}

func adopt(src, dest string) error {
	part := dest + ".part"
	os.Remove(part)
	if err := os.Link(src, part); err != nil {
		if err := copyFile(src, part); err != nil {
			return err
		}
	}
	return os.Rename(part, dest)
}

func (g *Getter) download(ctx context.Context, it Item, dest string) error {
	retries, wait := g.Retries, g.Backoff
	if retries == 0 {
		retries = 3
	}
	if wait == 0 {
		wait = time.Second
	}
	part := dest + ".part"
	var err error
	for attempt := 0; attempt <= retries; attempt++ {
		if attempt > 0 {
			g.logf("%s: retrying in %v (%v)", it.Name, wait, err)
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return ctx.Err()
			}
			wait *= 2
		}
		var retry bool
		retry, err = g.once(ctx, it, part)
		if err == nil || !retry {
			break
		}
	}
	if err != nil {
		return err
	}
	got, err := SHA256File(part)
	if err != nil {
		return err
	}
	if got != it.SHA256 {
		return fmt.Errorf("checksum mismatch for %s: want %s, got %s; nothing was renamed into place (%s kept for inspection)", it.URL, it.SHA256, got, part)
	}
	return os.Rename(part, dest)
}

// once is one attempt. retry reports whether a failure is worth another.
func (g *Getter) once(ctx context.Context, it Item, part string) (retry bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, it.URL, nil)
	if err != nil {
		return false, err
	}
	for k, vs := range it.Header {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	c := g.Client
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		return ctx.Err() == nil, fmt.Errorf("%s: %w", it.URL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return resp.StatusCode >= 500, fmt.Errorf("%s: HTTP %s", it.URL, resp.Status)
	}
	f, err := os.Create(part)
	if err != nil {
		return false, err
	}
	var src io.Reader = resp.Body
	if resp.ContentLength > 64<<20 {
		src = &progress{r: resp.Body, total: resp.ContentLength, name: it.Name, log: g.logf, next: time.Now().Add(10 * time.Second)}
	}
	_, err = io.Copy(f, src)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return ctx.Err() == nil, fmt.Errorf("%s: %w", it.URL, err)
	}
	return false, nil
}

type progress struct {
	r          io.Reader
	done, total int64
	name       string
	log        func(string, ...any)
	next       time.Time
}

func (p *progress) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.done += int64(n)
	if time.Now().After(p.next) {
		p.log("%s: %d of %d MiB", p.name, p.done>>20, p.total>>20)
		p.next = time.Now().Add(10 * time.Second)
	}
	return n, err
}

func (g *Getter) logf(format string, a ...any) {
	if g.Log != nil {
		g.Log(format, a...)
	}
}

func SHA256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	var h hash.Hash = sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// HasXarMagic reports whether path starts with "xar!", the flat-package
// magic every .pkg this project handles must carry.
func HasXarMagic(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	b := make([]byte, 4)
	if _, err := io.ReadFull(f, b); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
			return false, nil
		}
		return false, err
	}
	return string(b) == "xar!", nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
```

The adoption check in `Get` hashes large files fully, which is intended: 5.9 GB of Apple's installer is worth a minute of hashing to avoid a 5.9 GB download.

- [ ] **Step 4: Run; commit**

```bash
go test -race ./internal/fetch/ ./internal/config/ && go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add internal/fetch internal/config
git commit   # subject: "fetch: one verified download, cached by checksum, that adopts the shell tree's"
```

---

### Task 5: The guest's OpenSSH (`fetch.OpenSSH`)

**Files:**
- Create: `internal/fetch/openssh.go`, `internal/fetch/openssh_test.go`

**Interfaces:**
- Consumes: `Getter`, `Item`, `HasXarMagic`, `pins.ComponentVersion`, `vmguest.Files`.
- Produces:
  - `fetch.DefaultOpenSSHReleases = "https://github.com/Mavergreen/openssh/releases/download"`
  - `fetch.OpenSSHTag() (string, error)`, from the embedded `components/openssh/version`
  - `fetch.OpenSSHPkgs{Tag, Base, Replace string}`, whose `Base` and `Replace` are cache paths
  - `(*Getter).OpenSSH(ctx, releases, tag string, adoptDir string) (OpenSSHPkgs, error)`, where `adoptDir` is the shell tree's `openssh/<tag>` directory, or ""

**The rules** (from `fetch-openssh.sh`):
- `SHA256SUMS` is fetched from `<releases>/<tag>/SHA256SUMS` into `cache/openssh/<tag>/SHA256SUMS`. It is reused if already present and non-empty, and adopted from `adoptDir/SHA256SUMS` if that is non-empty.
- A 404 is an error naming the tag and asking whether it is a real release.
- Only `.pkg` names count. The classification, the two error cases and the missing-kind errors are exactly as in the shell script, with messages naming `System-Replace`.
- Each package goes through `Getter.Get`, with its checksum from SUMS and `Adopt: adoptDir/<name>`. It must then carry the `xar!` magic.
- The result is the base package first, then the replacement.

- [ ] **Step 1: Write the failing tests**

These carry `tests/openssh.bats`' fetch cases into Go. `internal/fetch/openssh_test.go`:

```go
package fetch

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// release serves <tag>/SHA256SUMS and the named packages.
func release(t *testing.T, tag string, pkgs map[string][]byte, sumsOverride map[string]string) *httptest.Server {
	var sums strings.Builder
	for name, body := range pkgs {
		s := sum(body)
		if o, ok := sumsOverride[name]; ok {
			s = o
		}
		fmt.Fprintf(&sums, "%s  %s\n", s, name)
	}
	fmt.Fprintf(&sums, "%s  %s\n", sum([]byte("notes")), "RELEASE-NOTES.md")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/"+tag+"/")
		if p == "SHA256SUMS" {
			w.Write([]byte(sums.String()))
			return
		}
		if b, ok := pkgs[p]; ok {
			w.Write(b)
			return
		}
		w.WriteHeader(404)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func xar(s string) []byte { return []byte("xar!" + s) }

func TestOpenSSHFetchesByTheNamesSUMSGivesBaseFirst(t *testing.T) {
	pkgs := map[string][]byte{
		"OpenSSH-10.5p1-mavericks.2.pkg":                xar("base"),
		"OpenSSH-10.5p1-mavericks.2-System-Replace.pkg": xar("replace"),
	}
	srv := release(t, "10.5p1-mavericks.2", pkgs, nil)
	got, err := getter(t).OpenSSH(context.Background(), srv.URL, "10.5p1-mavericks.2", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got.Base, "OpenSSH-10.5p1-mavericks.2.pkg") || !strings.HasSuffix(got.Replace, "-System-Replace.pkg") {
		t.Fatalf("%+v", got)
	}
}

func TestARenamedAssetPrefixDoesNotBreakTheFetch(t *testing.T) {
	// The golang incident: an asset renamed across a pin bump must not 404
	// because a name was constructed from a prefix.
	pkgs := map[string][]byte{"ssh10-a.pkg": xar("b"), "ssh10-a-system-replace.pkg": xar("r")}
	srv := release(t, "t", pkgs, nil)
	if _, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", ""); err != nil {
		t.Fatal(err)
	}
}

func TestOpenSSHRefusals(t *testing.T) {
	cases := map[string]struct {
		pkgs map[string][]byte
		over map[string]string
		want string
	}{
		"bytes differ from SUMS": {map[string][]byte{"a.pkg": xar("b"), "a-System-Replace.pkg": xar("r")}, map[string]string{"a.pkg": sum([]byte("other"))}, "checksum mismatch"},
		"no replacement":         {map[string][]byte{"a.pkg": xar("b")}, nil, "System-Replace"},
		"two bases":              {map[string][]byte{"a.pkg": xar("b"), "b.pkg": xar("c"), "a-System-Replace.pkg": xar("r")}, nil, "two base"},
		"not a flat package":     {map[string][]byte{"a.pkg": []byte("PK\x03\x04"), "a-System-Replace.pkg": xar("r")}, nil, "xar"},
	}
	for name, c := range cases {
		srv := release(t, "t", c.pkgs, c.over)
		_, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", "")
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}

func TestAMissingReleaseNamesTheTag(t *testing.T) {
	srv := release(t, "real", nil, nil)
	_, err := getter(t).OpenSSH(context.Background(), srv.URL, "9.9p9-mavericks.9", "")
	if err == nil || !strings.Contains(err.Error(), "9.9p9-mavericks.9") {
		t.Fatalf("err = %v", err)
	}
}

func TestOpenSSHTagIsTheEmbeddedPin(t *testing.T) {
	tag, err := OpenSSHTag()
	if err != nil || !strings.Contains(tag, "-mavericks.") {
		t.Fatalf("%q %v", tag, err)
	}
}
```

Run: `go test ./internal/fetch/ -run OpenSSH` → FAIL.

- [ ] **Step 2: Implement `internal/fetch/openssh.go`**

```go
package fetch

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const DefaultOpenSSHReleases = "https://github.com/Mavergreen/openssh/releases/download"

type OpenSSHPkgs struct{ Tag, Base, Replace string }

// OpenSSHTag is the release components/openssh/version pins (Renovate
// bumps it; the -mavericks.N suffix is the family's).
func OpenSSHTag() (string, error) {
	b, err := fs.ReadFile(vmguest.Files, "components/openssh/version")
	if err != nil {
		return "", err
	}
	tag := pins.ComponentVersion(b)
	if tag == "" {
		return "", fmt.Errorf("components/openssh/version names no release tag")
	}
	return tag, nil
}

// OpenSSH fetches the release's two packages, verified against the
// release's own SHA256SUMS. Nothing constructs an asset name from a
// prefix: the names are whatever SUMS says, so a renamed prefix cannot
// 404 across a pin bump.
func (g *Getter) OpenSSH(ctx context.Context, releases, tag, adoptDir string) (OpenSSHPkgs, error) {
	url := releases + "/" + tag
	sums, err := g.openSSHSums(ctx, url, tag, adoptDir)
	if err != nil {
		return OpenSSHPkgs{}, err
	}
	var base, replace string
	want := map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(sums))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 || !strings.HasSuffix(f[1], ".pkg") {
			continue
		}
		name := f[1]
		want[name] = f[0]
		if strings.Contains(name, "System-Replace") || strings.Contains(name, "system-replace") {
			if replace != "" {
				return OpenSSHPkgs{}, fmt.Errorf("two replacement packages in SHA256SUMS: %s and %s", replace, name)
			}
			replace = name
		} else {
			if base != "" {
				return OpenSSHPkgs{}, fmt.Errorf("two base packages in SHA256SUMS: %s and %s", base, name)
			}
			base = name
		}
	}
	if base == "" {
		return OpenSSHPkgs{}, fmt.Errorf("no base .pkg named in SHA256SUMS -- release %s looks wrong", tag)
	}
	if replace == "" {
		return OpenSSHPkgs{}, fmt.Errorf("no System-Replace .pkg named in SHA256SUMS -- release %s looks wrong", tag)
	}
	out := OpenSSHPkgs{Tag: tag}
	for _, p := range []struct {
		name string
		dst  *string
	}{{base, &out.Base}, {replace, &out.Replace}} {
		it := Item{Name: p.name, URL: url + "/" + p.name, SHA256: want[p.name]}
		if adoptDir != "" {
			it.Adopt = []string{filepath.Join(adoptDir, p.name)}
		}
		path, err := g.Get(ctx, it)
		if err != nil {
			return OpenSSHPkgs{}, err
		}
		if ok, err := HasXarMagic(path); err != nil || !ok {
			return OpenSSHPkgs{}, fmt.Errorf("%s is not a flat package (no xar magic)", path)
		}
		*p.dst = path
	}
	g.logf("OpenSSH %s verified: %s, %s", tag, base, replace)
	return out, nil
}

func (g *Getter) openSSHSums(ctx context.Context, url, tag, adoptDir string) ([]byte, error) {
	dest := filepath.Join(g.Paths.Cache(), "openssh", tag, "SHA256SUMS")
	if b, err := os.ReadFile(dest); err == nil && len(b) > 0 {
		return b, nil
	}
	if adoptDir != "" {
		if b, err := os.ReadFile(filepath.Join(adoptDir, "SHA256SUMS")); err == nil && len(b) > 0 {
			return b, writeAtomic(dest, b)
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url+"/SHA256SUMS", nil)
	if err != nil {
		return nil, err
	}
	c := g.Client
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("cannot fetch %s/SHA256SUMS: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cannot fetch %s/SHA256SUMS (%s) -- is %s a real release?", url, resp.Status, tag)
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(resp.Body); err != nil {
		return nil, err
	}
	return buf.Bytes(), writeAtomic(dest, buf.Bytes())
}

func writeAtomic(dest string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(dest+".part", b, 0o644); err != nil {
		return err
	}
	return os.Rename(dest+".part", dest)
}
```

SHA256SUMS itself is not pinned: it is trusted as the release's statement of its own checksums (INHERITED from `fetch-openssh.sh`), and it comes over TLS from GitHub. Say so in a comment on `openSSHSums`.

- [ ] **Step 3: Run; commit**

```bash
go test -race ./internal/fetch/ && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add internal/fetch
git commit   # subject: "fetch: the guest's OpenSSH, by the names its release's SHA256SUMS gives"
```

---

### Task 6: Apple's post-10.9.5 updates (`fetch.Updates`)

**Files:**
- Create: `internal/fetch/updates.go`, `internal/fetch/updates_test.go`
- Modify: `internal/config/config.go` (update-selection constants)

**Interfaces:**
- Produces:
  - `config.UpdateChoices = []string{"none", "security", "all"}`
  - `config.DefaultUpdates = "security"`
  - `fetch.UpdateNames(selection string) ([]string, error)`
  - `fetch.Update{Name, Path, Staged string}`
  - `(*Getter).Updates(ctx, reg *pins.Registry, selection string, adoptDir string) ([]Update, error)`, in install order
  - `fetch.StagedName(n int, path string) string`

- [ ] **Step 1: Write the failing tests**

These carry the fetch cases from `tests/updates.bats` into Go. `internal/fetch/updates_test.go`:

```go
package fetch

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

func TestSelectionsNest(t *testing.T) {
	none, _ := UpdateNames("none")
	sec, _ := UpdateNames("security")
	all, _ := UpdateNames("all")
	if len(none) != 0 || !slices.Equal(sec, []string{"apple-secupd-2016-004"}) || len(all) != 7 || all[0] != sec[0] {
		t.Fatalf("none=%v security=%v all=%v", none, sec, all)
	}
	if _, err := UpdateNames("most"); err == nil || !strings.Contains(err.Error(), "most") {
		t.Fatalf("err = %v", err)
	}
}

func TestEveryUpdateIsPinnedWithARealChecksum(t *testing.T) {
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	all, _ := UpdateNames("all")
	for _, n := range all {
		if _, err := reg.Lookup(n); err != nil {
			t.Error(err)
		}
	}
}

func TestUpdatesFetchInInstallOrderWithStagedNames(t *testing.T) {
	bodies := map[string][]byte{"/SecUpd.pkg": xar("s"), "/Safari.pkg": xar("f")}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if b, ok := bodies[r.URL.Path]; ok {
			w.Write(b)
			return
		}
		w.WriteHeader(404)
	}))
	defer srv.Close()
	reg, _ := pins.Parse(strings.NewReader(fmt.Sprintf(
		"apple-secupd-2016-004\t%s/SecUpd.pkg\t%s\n", srv.URL, sum(bodies["/SecUpd.pkg"]))))
	got, err := getter(t).Updates(context.Background(), reg, "security", "")
	if err != nil || len(got) != 1 || got[0].Staged != "mqg-update-01-SecUpd.pkg" {
		t.Fatalf("%+v %v", got, err)
	}
	if none, err := getter(t).Updates(context.Background(), reg, "none", ""); err != nil || len(none) != 0 {
		t.Fatalf("none must fetch nothing: %+v %v", none, err)
	}
}

func TestAnUpdateThatIsNotAFlatPackageIsRefused(t *testing.T) {
	body := []byte("PK\x03\x04zip")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	defer srv.Close()
	reg, _ := pins.Parse(strings.NewReader(fmt.Sprintf("apple-secupd-2016-004\t%s/S.pkg\t%s\n", srv.URL, sum(body))))
	_, err := getter(t).Updates(context.Background(), reg, "security", "")
	if err == nil || !strings.Contains(err.Error(), "xar") {
		t.Fatalf("err = %v", err)
	}
}

func TestStagedName(t *testing.T) {
	if StagedName(3, "/c/x/iTunesX.pkg") != "mqg-update-03-iTunesX.pkg" {
		t.Fatal(StagedName(3, "/c/x/iTunesX.pkg"))
	}
}
```

Run → FAIL.

- [ ] **Step 2: Implement**

Add to `internal/config/config.go`:

```go
// Which post-10.9.5 updates an image carries (docs/decisions/0011): a
// build-time choice whose default is a decision.
var UpdateChoices = []string{"none", "security", "all"}

const DefaultUpdates = "security"
```

`internal/fetch/updates.go`:

```go
package fetch

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

// updateSources is image/fetch-updates.sh's table, in install order.
var updateSources = map[string][]string{
	"none":     nil,
	"security": {"apple-secupd-2016-004"},
	"all": {
		"apple-secupd-2016-004",
		"apple-safari-9.1.3",
		"apple-itunes-12.6.2-corefp",
		"apple-itunes-12.6.2-mobiledevice",
		"apple-itunes-12.6.2-itunesaccess",
		"apple-itunes-12.6.2-itunesx",
		"apple-itunes-12.6.2-coreadi",
	},
}

func UpdateNames(selection string) ([]string, error) {
	names, ok := updateSources[selection]
	if !ok {
		return nil, fmt.Errorf("unknown updates selection %q: choose one of %s", selection, strings.Join(config.UpdateChoices, ", "))
	}
	return append([]string(nil), names...), nil
}

type Update struct{ Name, Path, Staged string }

// StagedName is how the installer media presents the n-th update
// (1-based): the install order is legible in the name, and the prefix
// keeps it from colliding with Apple's own packages on the media.
func StagedName(n int, path string) string {
	return fmt.Sprintf("mqg-update-%02d-%s", n, filepath.Base(path))
}

// Updates fetches one selection, verified against the registry, in the
// order the guest must install them. "none" fetches nothing.
func (g *Getter) Updates(ctx context.Context, reg *pins.Registry, selection, adoptDir string) ([]Update, error) {
	names, err := UpdateNames(selection)
	if err != nil {
		return nil, err
	}
	var out []Update
	for i, n := range names {
		src, err := reg.Lookup(n)
		if err != nil {
			return nil, err
		}
		it := Item{Name: n, URL: src.URL, SHA256: src.SHA256}
		if adoptDir != "" {
			if fn, err := Filename(src.URL); err == nil {
				it.Adopt = []string{filepath.Join(adoptDir, fn)}
			}
		}
		path, err := g.Get(ctx, it)
		if err != nil {
			return nil, err
		}
		if ok, err := HasXarMagic(path); err != nil || !ok {
			return nil, fmt.Errorf("%s is not a flat package (no xar magic)", path)
		}
		out = append(out, Update{Name: n, Path: path, Staged: StagedName(i+1, path)})
	}
	return out, nil
}
```

Creating the staged links is a media concern (phase 4). This phase computes the names, because the payload's `firstboot.conf` records them.

- [ ] **Step 3: Run; commit**

```bash
go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add internal/fetch internal/config
git commit   # subject: "fetch: Apple's post-10.9.5 updates, in install order, verified"
```

---

### Task 7: Apple's installer (`fetch.InstallESD`): the osrecovery handshake

**Files:**
- Create: `internal/fetch/esd.go`, `internal/fetch/esd_test.go`

**Interfaces:**
- Consumes: `Getter`, `pins.Registry`.
- Produces:
  - `fetch.ESDSource = "apple-installesd-10.9.5"`
  - `fetch.DefaultRecovery = "http://osrecovery.apple.com"`
  - `fetch.Recovery{Base string; Client *http.Client; Rand io.Reader}`
  - `(Recovery).Handshake(ctx) (assetURL, token string, err error)`
  - `deriveKey(clientID, serverID string) (string, error)`
  - `(*Getter).InstallESD(ctx, reg *pins.Registry, rc Recovery, adopt []string) (string, error)`
  - `(Recovery).Probe(ctx, reg, c *http.Client) (assetURL string, size int64, err error)`

**The rules:**
- **The registry is the single source of truth** for the expected URL and checksum. The shell script also hardcoded both, and cross-checked the copies; the Go binary embeds the registry, so one copy is enough.
- **Adopt, then handshake.** The cache is checked first, then each `adopt` path (the shell tree's `media/InstallESD.dmg`), and only then does the handshake happen. The handshake yields a URL, which must equal the registry's, and a token, sent as `Cookie: AssetToken=<token>`.
- **Every download error names that nothing was renamed into place**, because `Getter.Get` already guarantees it.
- **`Probe`** performs the handshake, checks the URL, then sends `HEAD` to it with the token and returns the reported size. It downloads nothing. Task 11 uses it to measure the real handshake.

- [ ] **Step 1: Write the failing tests**

`internal/fetch/esd_test.go`:

```go
package fetch

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// Known answer, computed 2026-09-25 by running fetch-installesd.sh's own
// openssl/xxd/od pipeline on these inputs -- not by this code.
func TestDeriveKeyKnownAnswer(t *testing.T) {
	got, err := deriveKey("0123456789ABCDEF", "001~0A1B2C3D4E5F60718293A4B5C6D7E8F9")
	if err != nil || got != "1DAC930DE453BFCF3A196011CEB952D85B53C72E6D8C8340E7D35D1F3CD5079F" {
		t.Fatalf("%s %v", got, err)
	}
	if _, err := deriveKey("0123456789ABCDEF", "no-tilde"); err == nil {
		t.Fatal("a server id without ~ must be refused")
	}
}

// fakeApple is osrecovery plus the CDN: it checks the handshake the way
// Apple's servers must be satisfied, then serves the asset only with the
// token.
func fakeApple(t *testing.T, asset []byte) (*httptest.Server, *pins.Registry) {
	const serverID = "001~0A1B2C3D4E5F60718293A4B5C6D7E8F9"
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/":
			http.SetCookie(w, &http.Cookie{Name: "session", Value: serverID})
		case r.Method == "POST" && r.URL.Path == "/InstallationPayload/OSInstaller":
			c, err := r.Cookie("session")
			body, _ := io.ReadAll(r.Body)
			want := "cid=0123456789ABCDEF\nsn=C0243070168G3M91F\nbid=Mac-3CBD00234E554E41\nk=1DAC930DE453BFCF3A196011CEB952D85B53C72E6D8C8340E7D35D1F3CD5079F"
			if err != nil || c.Value != serverID || r.Header.Get("Content-Type") != "text/plain" || string(body) != want {
				w.WriteHeader(403)
				return
			}
			fmt.Fprintf(w, "AP: x\nAU: %s/content/InstallESD.dmg\nAT: tok123\n", srv.URL)
		case r.URL.Path == "/content/InstallESD.dmg":
			if r.Header.Get("Cookie") != "AssetToken=tok123" {
				w.WriteHeader(403)
				return
			}
			w.Header().Set("Content-Length", fmt.Sprint(len(asset)))
			if r.Method == "GET" {
				w.Write(asset)
			}
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(srv.Close)
	reg, _ := pins.Parse(strings.NewReader(fmt.Sprintf("%s\t%s/content/InstallESD.dmg\t%s\n", ESDSource, srv.URL, sum(asset))))
	return srv, reg
}

func fixedRand() io.Reader { return bytes.NewReader([]byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF}) }

func TestInstallESDHandshakesDownloadsAndVerifies(t *testing.T) {
	asset := []byte("not really Apple's installer")
	srv, reg := fakeApple(t, asset)
	g := getter(t)
	p, err := g.InstallESD(context.Background(), reg, Recovery{Base: srv.URL, Rand: fixedRand()}, nil)
	if err != nil || !strings.HasSuffix(p, "/InstallESD.dmg") {
		t.Fatalf("%q %v", p, err)
	}
}

func TestAnOfferOfADifferentOSIsRefused(t *testing.T) {
	asset := []byte("x")
	srv, _ := fakeApple(t, asset)
	reg, _ := pins.Parse(strings.NewReader(fmt.Sprintf("%s\thttp://oscdn.apple.com/other/InstallESD.dmg\t%s\n", ESDSource, sum(asset))))
	_, err := getter(t).InstallESD(context.Background(), reg, Recovery{Base: srv.URL, Rand: fixedRand()}, nil)
	if err == nil || !strings.Contains(err.Error(), "not the Mavericks") {
		t.Fatalf("err = %v", err)
	}
}

func TestAnAdoptedInstallerNeedsNoHandshake(t *testing.T) {
	asset := []byte("already here")
	_, reg := fakeApple(t, asset)
	old := t.TempDir() + "/InstallESD.dmg"
	if err := writeAtomic(old, asset); err != nil {
		t.Fatal(err)
	}
	// An unreachable recovery server proves no handshake happened.
	p, err := getter(t).InstallESD(context.Background(), reg, Recovery{Base: "http://127.0.0.1:1"}, []string{old})
	if err != nil || p == "" {
		t.Fatalf("%q %v", p, err)
	}
}

func TestProbeReportsTheSizeAndDownloadsNothing(t *testing.T) {
	asset := []byte("0123456789")
	srv, reg := fakeApple(t, asset)
	url, size, err := Recovery{Base: srv.URL, Rand: fixedRand()}.Probe(context.Background(), reg, nil)
	if err != nil || size != int64(len(asset)) || !strings.HasSuffix(url, "/InstallESD.dmg") {
		t.Fatalf("%q %d %v", url, size, err)
	}
}
```

Run → FAIL.

- [ ] **Step 2: Implement `internal/fetch/esd.go`**

```go
package fetch

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

const (
	ESDSource       = "apple-installesd-10.9.5"
	DefaultRecovery = "http://osrecovery.apple.com"
	// From Mavericks Forever's get.sh, donated by dosdude1 from a broken
	// Mac (INHERITED; media/fetch-installesd.sh records the credit). They
	// are not this machine's and are not secrets.
	boardSerial = "C0243070168G3M91F"
	boardID     = "Mac-3CBD00234E554E41"
	rom         = "003EE1E6AC14"
)

// Recovery is Apple's osrecovery service. The transfer is plain HTTP by
// Apple's design (the token is a cookie and the payload is unencrypted),
// so the checksum is the only thing between this and a middlebox.
type Recovery struct {
	Base   string       // "" means DefaultRecovery
	Client *http.Client // nil means http.DefaultClient
	Rand   io.Reader    // nil means crypto/rand
}

func (rc Recovery) base() string {
	if rc.Base == "" {
		return DefaultRecovery
	}
	return rc.Base
}

func (rc Recovery) client() *http.Client {
	if rc.Client == nil {
		return http.DefaultClient
	}
	return rc.Client
}

// deriveKey is SHA-256 over client id, the server id's hex half, the ROM,
// SHA-256(serial+board id) and ten 0xCC bytes, as uppercase hex.
func deriveKey(clientID, serverID string) (string, error) {
	_, half, ok := strings.Cut(serverID, "~")
	if !ok {
		return "", fmt.Errorf("osrecovery returned no usable session id (got %q)", serverID)
	}
	h := sha256.New()
	for _, x := range []string{clientID, half, rom} {
		b, err := hex.DecodeString(x)
		if err != nil {
			return "", fmt.Errorf("bad hex %q: %w", x, err)
		}
		h.Write(b)
	}
	inner := sha256.Sum256([]byte(boardSerial + boardID))
	h.Write(inner[:])
	h.Write([]byte(strings.Repeat("\xcc", 10)))
	return strings.ToUpper(hex.EncodeToString(h.Sum(nil))), nil
}

// Handshake asks osrecovery for the installer's URL and a download token.
func (rc Recovery) Handshake(ctx context.Context) (assetURL, token string, err error) {
	rnd := rc.Rand
	if rnd == nil {
		rnd = rand.Reader
	}
	cid := make([]byte, 8)
	if _, err := io.ReadFull(rnd, cid); err != nil {
		return "", "", err
	}
	clientID := strings.ToUpper(hex.EncodeToString(cid))

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, rc.base()+"/", nil)
	resp, err := rc.client().Do(req)
	if err != nil {
		return "", "", fmt.Errorf("cannot reach osrecovery for a session id: %w", err)
	}
	resp.Body.Close()
	serverID := ""
	for _, c := range resp.Cookies() {
		serverID = c.Value // the shell took the jar's last cookie; prefer "session"
		if c.Name == "session" {
			break
		}
	}
	key, err := deriveKey(clientID, serverID)
	if err != nil {
		return "", "", err
	}
	body := fmt.Sprintf("cid=%s\nsn=%s\nbid=%s\nk=%s", clientID, boardSerial, boardID, key)
	req, _ = http.NewRequestWithContext(ctx, http.MethodPost, rc.base()+"/InstallationPayload/OSInstaller", strings.NewReader(body))
	req.Header.Set("Content-Type", "text/plain")
	req.AddCookie(&http.Cookie{Name: "session", Value: serverID})
	resp, err = rc.client().Do(req)
	if err != nil {
		return "", "", fmt.Errorf("InstallationPayload request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("InstallationPayload request was refused: %s", resp.Status)
	}
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "AU: "); ok {
			assetURL = v
		}
		if v, ok := strings.CutPrefix(sc.Text(), "AT: "); ok {
			token = v
		}
	}
	if assetURL == "" || token == "" {
		return "", "", fmt.Errorf("Apple's installation payload had no asset URL or token")
	}
	return assetURL, token, nil
}

func (rc Recovery) offer(ctx context.Context, reg *pins.Registry) (pins.Source, string, error) {
	src, err := reg.Lookup(ESDSource)
	if err != nil {
		return pins.Source{}, "", err
	}
	url, token, err := rc.Handshake(ctx)
	if err != nil {
		return pins.Source{}, "", err
	}
	// The same handshake serves whatever OS Apple decides that board is
	// entitled to; silently installing a different one would be a long
	// afternoon (get.sh checks this too).
	if url != src.URL {
		return pins.Source{}, "", fmt.Errorf("Apple offered %s, not the Mavericks InstallESD URL %s", url, src.URL)
	}
	return src, token, nil
}

// InstallESD is Apple's InstallESD.dmg, verified: from the cache, else
// adopted from an earlier download, else fetched from Apple.
func (g *Getter) InstallESD(ctx context.Context, reg *pins.Registry, rc Recovery, adopt []string) (string, error) {
	src, err := reg.Lookup(ESDSource)
	if err != nil {
		return "", err
	}
	fn, err := Filename(src.URL)
	if err != nil {
		return "", err
	}
	// Cache and adoption first: no handshake for a file already here. A
	// rotten cached file is an error, never a reason to fetch 5 GB again.
	p, err := g.Get(ctx, Item{Name: ESDSource, SHA256: src.SHA256, Filename: fn, Adopt: adopt, noFetch: true})
	if err == nil {
		return p, nil
	}
	if !errors.Is(err, errNotCached) {
		return "", err
	}
	_, token, err := rc.offer(ctx, reg)
	if err != nil {
		return "", err
	}
	h := http.Header{}
	h.Set("Cookie", "AssetToken="+token)
	g.logf("downloading InstallESD.dmg (about 5.2 GB, over plain HTTP)")
	return g.Get(ctx, Item{Name: ESDSource, URL: src.URL, SHA256: src.SHA256, Filename: fn, Header: h})
}

// Probe performs the handshake and asks the CDN for the size, downloading
// nothing: a measurement of Apple's side without 5 GB of traffic.
func (rc Recovery) Probe(ctx context.Context, reg *pins.Registry, c *http.Client) (string, int64, error) {
	src, token, err := rc.offer(ctx, reg)
	if err != nil {
		return "", 0, err
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodHead, src.URL, nil)
	req.Header.Set("Cookie", "AssetToken="+token)
	if c == nil {
		c = rc.client()
	}
	resp, err := c.Do(req)
	if err != nil {
		return "", 0, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("HEAD %s: %s", src.URL, resp.Status)
	}
	return src.URL, resp.ContentLength, nil
}
```

`InstallESD` needs a way to say "check the cache and adopt, but don't download". In `internal/fetch/get.go`:

- Add an unexported field `noFetch bool` to `Item`.
- Declare `var errNotCached = errors.New("not in the cache and no adoptable copy")`.
- In `Get`, immediately after the adoption loop and before `g.download`, add:

```go
	if it.noFetch {
		return "", errNotCached
	}
```

Add a test in `get_test.go`: with `noFetch` set, nothing cached and nothing adoptable, `Get` returns `errNotCached` and makes no request. Use a server that fails the test if it is contacted.

- [ ] **Step 3: Run; commit**

```bash
go test -race ./internal/fetch/ && go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add internal/fetch
git commit   # subject: "fetch: Apple's installer, by the osrecovery handshake, verified before it has a name"
```

---

### Task 8: `vmavs fetch`

**Files:**
- Create: `internal/cli/fetch.go`, `internal/cli/fetch_test.go`
- Modify: `internal/cli/cli.go` (command table; `Env.HTTP`, `Env.Endpoints`, `Env.Registry`), `internal/doctor/doctor.go` (+ test), `README.md` (the Go section), spec §2

**Interfaces:**
- Consumes: everything in `fetch`, `pins.Embedded`, `config.Paths`, `config.LegacyHome`, `config.DefaultUpdates`, `config.UpdateChoices`.
- Produces:
  - `vmavs fetch [esd|openssh|updates ...] [--updates none|security|all] [--probe]`
  - `Env.HTTP *http.Client`
  - `Env.Endpoints *Endpoints{Recovery, OpenSSHReleases string}`
  - `Env.Registry *pins.Registry`

  For all three new `Env` fields, nil means the real one.

**Behaviour:**
- No positional arguments means all three. `--updates` defaults to `security`; with `none`, `updates` fetches nothing and prints nothing.
- Each fetched file's path is printed on stdout, one per line, in this order: esd, the OpenSSH base, the OpenSSH replacement, then the updates in install order. Progress and adoption go to stderr as `vmavs fetch: …`.
- **Adoption.** It adopts from the shell tree's layout inside `VMAVS_HOME`: `media/InstallESD.dmg`, `openssh/<tag>/` and `updates/`.
  - `VMAVS_HOME` may itself be the shell tree's home (phase 1's documented way of booting shell-built images).
  - If `config.LegacyHome` differs from `VMAVS_HOME`, it adopts from there too.
  - Adoption never moves or deletes anything in the old home. It hard-links, or copies.
- **`--probe`** is for esd only; anything else is a usage error. It prints `<asset url>\t<bytes>` and downloads nothing.
- An unknown fetch target is a usage error that lists the three.

- [ ] **Step 1: Write the failing tests**

`internal/cli/fetch_test.go`:
- Build fake servers from the `fetch` package's test helpers. Those are unexported in another package, so write local ones in the same style: a fake osrecovery+CDN, a fake OpenSSH release, and a registry naming them.
- Pass them in through `Env.Endpoints`, `Env.Registry` and `Env.HTTP`.
- Every test sets `VMAVS_HOME` and `HOME` to temp dirs.

Cases:
1. `vmavs fetch openssh` prints two paths (base, then replace) and exits 0.
2. `vmavs fetch updates --updates none` prints nothing and exits 0.
3. `vmavs fetch esd` with `media/InstallESD.dmg` present in `VMAVS_HOME` adopts it:
   - no handshake (the recovery endpoint is `http://127.0.0.1:1`);
   - "adopted" on stderr;
   - the original file is still in place.
4. `vmavs fetch bogus` → exit 2, and the message names `esd, openssh, updates`.
5. `vmavs fetch openssh --probe` → exit 2.
6. `vmavs fetch esd --probe` prints the URL and size and creates no cache file.
7. `vmavs fetch --help` begins `usage: vmavs fetch`. This is covered already by `TestEverySubcommandTakesHelp` once the row exists.

Run → FAIL.

- [ ] **Step 2: Implement `internal/cli/fetch.go`**

Parse flags, validate the targets and `--updates` (both are usage errors), then build a `fetch.Getter`:
- `Paths` from `paths(e)`;
- `Client` = `e.HTTP`;
- `Log` = `logf(e, "fetch", …)`.

Resolve the registry (`e.Registry` or `pins.Embedded()`), the endpoints, and the adoption directories. Run the requested fetches in the order esd, openssh, updates, printing each path. Put the help text beside the command, as the other commands do. It must say:
- adoption of the shell tree's downloads is verified and never moves anything;
- Apple's installer comes over plain HTTP, by Apple's design, which is why its checksum is checked before it has a name;
- `--probe` measures the handshake without the 5 GB.

Add `{"fetch", "Fetch and verify the pinned inputs (Apple's installer, updates, OpenSSH)", cmdFetch}` to `commandTable()` after `doctor`.

- [ ] **Step 3: `doctor` gets a `fetch` row**

In `internal/doctor/doctor.go`, `fetch` is always READY: the Go binary needs no external tool for it. Give it a note: "needs the network, unless the shell tree's downloads can be adopted". Update the doctor tests and `TestRunNeedsAnImageFirmwareAndQEMU`'s verdict expectation, which is now `ready: fetch run …`.

- [ ] **Step 4: Docs**

- **README's "The Go vmavs (in progress)" section:** add `fetch` to the list of what exists, and say it adopts the shell tree's downloads.
- **Spec §2:** the `fetch` line gains `[--updates …] [--probe]`.
- **Claims:** run `grep -rn "vmavs fetch\|bin/vmavs fetch" README.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md internal/` and fix any claim this changes, for example help text or `doctor` messages that say `bin/vmavs` for fetching.

- [ ] **Step 5: Run; commit**

```bash
go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
bats tests/release.bats
git add internal README.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md
git commit   # subject: "vmavs fetch: Apple's installer, the updates and the guest's OpenSSH, verified"
```

---

### Task 9: The flat-package container (`internal/payload`: cpio, gzip, xar)

**Files:**
- Create: `internal/payload/cpio.go`, `internal/payload/xar.go`, `internal/payload/container_test.go`

**Interfaces:**
- Produces:
  - `cpioEntry{Name string; Mode uint32; Data []byte; Dir bool}`
  - `makeODC([]cpioEntry) []byte`
  - `readODC([]byte) ([]cpioEntry, error)`
  - `gzipDeterministic([]byte) ([]byte, error)`
  - `member{Name string; Mode uint32; Data []byte}`
  - `buildXar([]member) ([]byte, error)`
  - `readXar([]byte) (toc string, members map[string][]byte, err error)`
  - `packageInfo(identifier, version string) []byte`
  - `flatPackage(postinstall []byte, identifier, version string) ([]byte, error)`

**What must match `mkflatpkg.py`, and what cannot.** Everything *inside* the compressed streams must be identical to the Python writer: the TOC XML (bar the Scripts member's lengths and checksums), PackageInfo, and the decompressed cpio. The compressed bytes themselves cannot be identical. Go's `compress/zlib` and `compress/gzip` are different deflate implementations from Python's zlib, so the same input compresses to different bytes (REASONED from how deflate encoders work; the parity test records what it finds). Go's own output must be byte-identical across runs.

- [ ] **Step 1: Write the failing tests**

`internal/payload/container_test.go`:

```go
package payload

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"testing"
)

func repoRoot() string {
	_, here, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(here), "..", "..")
}

func gunzip(t *testing.T, b []byte) []byte {
	r, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestCPIOEntriesCarryFileTypeBits(t *testing.T) {
	// Without them PackageKit's cpio reader fails "copier error 21 ... bad
	// file format" (NOTES.md, P4): 040755 and 100755, never 000755.
	b := makeODC([]cpioEntry{{Name: ".", Mode: 0o755, Dir: true}, {Name: "./postinstall", Mode: 0o755, Data: []byte("#!/bin/sh\n")}})
	es, err := readODC(b)
	if err != nil || len(es) != 2 {
		t.Fatalf("%+v %v", es, err)
	}
	if !bytes.Contains(b, []byte("070707000000000001040755")) || !bytes.Contains(b, []byte("000002100755")) || !bytes.Contains(b, []byte("TRAILER!!!")) {
		t.Fatalf("headers: %q", b[:160])
	}
}

func TestTheXarHeaderAndTOCChecksum(t *testing.T) {
	blob, err := flatPackage([]byte("#!/bin/sh\nexit 0\n"), "com.mqg.firstboot", "1.0")
	if err != nil {
		t.Fatal(err)
	}
	if string(blob[:4]) != "xar!" || binary.BigEndian.Uint16(blob[4:]) != 28 || binary.BigEndian.Uint16(blob[6:]) != 1 || binary.BigEndian.Uint32(blob[24:]) != 1 {
		t.Fatalf("header % x", blob[:28])
	}
	toc, members, err := readXar(blob)
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 2 || members["PackageInfo"] == nil || members["Scripts"] == nil {
		t.Fatalf("members %v", members)
	}
	if !regexp.MustCompile(`<creation-time>1970-01-01T00:00:00</creation-time>`).MatchString(toc) {
		t.Fatal("creation-time is not the fixed epoch")
	}
}

func TestTheSameInputsGiveAByteIdenticalPackage(t *testing.T) {
	a, _ := flatPackage([]byte("x\n"), "com.mqg.firstboot", "1.0")
	b, _ := flatPackage([]byte("x\n"), "com.mqg.firstboot", "1.0")
	if !bytes.Equal(a, b) {
		t.Fatal("two builds differ")
	}
}

// Structural parity with image/payload/mkflatpkg.py: the same TOC (bar
// the Scripts member's compressed length and checksums), the same
// PackageInfo, the same decompressed cpio.
func TestSameContentsAsMkflatpkg(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available; CI runs this")
	}
	dir := t.TempDir()
	scripts := filepath.Join(dir, "scripts")
	os.MkdirAll(scripts, 0o755)
	post := []byte("#!/bin/sh\necho hello\nexit 0\n")
	os.WriteFile(filepath.Join(scripts, "postinstall"), post, 0o755)
	pyOut := filepath.Join(dir, "py.pkg")
	cmd := exec.Command("python3", filepath.Join(repoRoot(), "image", "payload", "mkflatpkg.py"),
		"--scripts", scripts, "--identifier", "com.mqg.firstboot", "--version", "1.0", "--out", pyOut)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	py, _ := os.ReadFile(pyOut)
	gob, err := flatPackage(post, "com.mqg.firstboot", "1.0")
	if err != nil {
		t.Fatal(err)
	}
	pyTOC, pyM, err := readXar(py)
	if err != nil {
		t.Fatal(err)
	}
	goTOC, goM, _ := readXar(gob)
	if !bytes.Equal(pyM["PackageInfo"], goM["PackageInfo"]) {
		t.Fatalf("PackageInfo differs:\n%s\n%s", pyM["PackageInfo"], goM["PackageInfo"])
	}
	if !bytes.Equal(gunzip(t, pyM["Scripts"]), gunzip(t, goM["Scripts"])) {
		t.Fatal("decompressed Scripts differ")
	}
	norm := regexp.MustCompile(`(<(length|size|extracted-checksum|archived-checksum)[^>]*>)[^<]*`)
	if norm.ReplaceAllString(pyTOC, "$1*") != norm.ReplaceAllString(goTOC, "$1*") {
		t.Fatalf("TOCs differ beyond lengths and checksums:\n%s\n---\n%s", pyTOC, goTOC)
	}
	t.Logf("compressed sizes: python %d bytes, go %d bytes (deflate implementations differ)", len(py), len(gob))
}
```

Run: `go test ./internal/payload/` → FAIL.

- [ ] **Step 2: Implement `internal/payload/cpio.go`**

```go
// Package payload builds the first-boot flat package: the xar container,
// its odc cpio Scripts archive, and the postinstall script that carries
// everything, as image/payload/mkflatpkg.py and build-firstboot-pkg.sh
// build them. Read those two files' comments for the format's history;
// the rules here are theirs.
package payload

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"strconv"
)

// File-type bits: NOT optional (see TestCPIOEntriesCarryFileTypeBits).
const (
	sIFDIR = 0o040000
	sIFREG = 0o100000
)

type cpioEntry struct {
	Name string
	Mode uint32 // permission bits; the type bits come from Dir
	Data []byte
	Dir  bool
}

func odcEntry(e cpioEntry, ino int) []byte {
	data := e.Data
	typ := uint32(sIFREG)
	if e.Dir {
		data, typ = nil, sIFDIR
	}
	name := append([]byte(e.Name), 0)
	h := fmt.Sprintf("070707%06o%06o%06o%06o%06o%06o%06o%011o%06o%011o",
		0, ino&0o777777, typ|(e.Mode&0o7777), 0, 0, 1, 0, 0, len(name), len(data))
	return append(append([]byte(h), name...), data...)
}

// makeODC is a POSIX.1 "odc" cpio (magic 070707): fixed mtimes, uid and
// gid 0, inodes numbered from 1, then the TRAILER!!! entry.
func makeODC(entries []cpioEntry) []byte {
	var b bytes.Buffer
	ino := 1
	for _, e := range entries {
		b.Write(odcEntry(e, ino))
		ino++
	}
	b.Write(odcEntry(cpioEntry{Name: "TRAILER!!!", Mode: 0o644}, ino))
	return b.Bytes()
}

func readODC(b []byte) ([]cpioEntry, error) {
	var out []cpioEntry
	for pos := 0; pos+76 <= len(b); {
		if string(b[pos:pos+6]) != "070707" {
			return nil, fmt.Errorf("not an odc cpio header at offset %d", pos)
		}
		f := string(b[pos+6 : pos+76])
		mode, _ := strconv.ParseUint(f[12:18], 8, 32)
		namesize, _ := strconv.ParseUint(f[53:59], 8, 32)
		filesize, _ := strconv.ParseUint(f[59:70], 8, 64)
		pos += 76
		if pos+int(namesize)+int(filesize) > len(b) {
			return nil, fmt.Errorf("truncated cpio entry at offset %d", pos-76)
		}
		name := string(b[pos : pos+int(namesize)-1])
		pos += int(namesize)
		data := b[pos : pos+int(filesize)]
		pos += int(filesize)
		if name == "TRAILER!!!" {
			break
		}
		out = append(out, cpioEntry{Name: name, Mode: uint32(mode) & 0o7777, Data: data, Dir: mode&0o170000 == sIFDIR})
	}
	return out, nil
}

// gzipDeterministic: level 9 and a zero mtime, so identical input gives
// identical output.
func gzipDeterministic(data []byte) ([]byte, error) {
	var b bytes.Buffer
	w, err := gzip.NewWriterLevel(&b, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := w.Write(data); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
```

- [ ] **Step 3: Implement `internal/payload/xar.go`**

```go
package payload

import (
	"bytes"
	"compress/zlib"
	"crypto/sha1"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const epoch = "1970-01-01T00:00:00Z"

type member struct {
	Name string
	Mode uint32
	Data []byte
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

// buildXar writes a xar archive whose members are stored raw, exactly as
// mkflatpkg.py's build_xar does, TOC template and all.
func buildXar(members []member) ([]byte, error) {
	ms := append([]member(nil), members...)
	sort.Slice(ms, func(i, j int) bool { return ms[i].Name < ms[j].Name })
	var heap bytes.Buffer
	heap.Write(make([]byte, sha1.Size)) // the TOC's own checksum goes here
	var entries strings.Builder
	for i, m := range ms {
		id := i + 1
		offset := heap.Len()
		heap.Write(m.Data)
		d := sha1.Sum(m.Data)
		sum := hex.EncodeToString(d[:])
		fmt.Fprintf(&entries, "  <file id=\"%d\">\n"+
			"   <data>\n"+
			"    <length>%d</length>\n"+
			"    <offset>%d</offset>\n"+
			"    <size>%d</size>\n"+
			"    <encoding style=\"application/octet-stream\"/>\n"+
			"    <extracted-checksum style=\"sha1\">%s</extracted-checksum>\n"+
			"    <archived-checksum style=\"sha1\">%s</archived-checksum>\n"+
			"   </data>\n"+
			"   <ctime>%s</ctime>\n"+
			"   <mtime>%s</mtime>\n"+
			"   <atime>%s</atime>\n"+
			"   <group>wheel</group>\n"+
			"   <gid>0</gid>\n"+
			"   <user>root</user>\n"+
			"   <uid>0</uid>\n"+
			"   <mode>%04o</mode>\n"+
			"   <deviceno>0</deviceno>\n"+
			"   <inode>%d</inode>\n"+
			"   <type>file</type>\n"+
			"   <name>%s</name>\n"+
			"  </file>\n",
			id, len(m.Data), offset, len(m.Data), sum, sum, epoch, epoch, epoch, m.Mode, id, xmlEscape(m.Name))
	}
	toc := fmt.Sprintf("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"+
		"<xar>\n"+
		" <toc>\n"+
		"  <creation-time>%s</creation-time>\n"+
		"  <checksum style=\"sha1\">\n"+
		"   <offset>0</offset>\n"+
		"   <size>%d</size>\n"+
		"  </checksum>\n"+
		"%s"+
		" </toc>\n"+
		"</xar>\n", strings.TrimSuffix(epoch, "Z"), sha1.Size, entries.String())
	var ztoc bytes.Buffer
	zw, err := zlib.NewWriterLevel(&ztoc, zlib.BestCompression)
	if err != nil {
		return nil, err
	}
	zw.Write([]byte(toc))
	if err := zw.Close(); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	out.WriteString("xar!")
	binary.Write(&out, binary.BigEndian, uint16(28))
	binary.Write(&out, binary.BigEndian, uint16(1))
	binary.Write(&out, binary.BigEndian, uint64(ztoc.Len()))
	binary.Write(&out, binary.BigEndian, uint64(len(toc)))
	binary.Write(&out, binary.BigEndian, uint32(1)) // sha1
	out.Write(ztoc.Bytes())
	h := heap.Bytes()
	tsum := sha1.Sum(ztoc.Bytes())
	copy(h[:sha1.Size], tsum[:])
	out.Write(h)
	return out.Bytes(), nil
}

var (
	fileRE = regexp.MustCompile(`(?s)<file id="\d+">(.*?)</file>`)
	nameRE = regexp.MustCompile(`(?s)<name>(.*?)</name>`)
	offRE  = regexp.MustCompile(`<offset>(\d+)</offset>`)
	sizeRE = regexp.MustCompile(`<size>(\d+)</size>`)
)

// readXar reads back what buildXar writes: enough of the format for tests
// and for later phases to inspect a package. It verifies the TOC checksum.
func readXar(blob []byte) (string, map[string][]byte, error) {
	if len(blob) < 28 || string(blob[:4]) != "xar!" {
		return "", nil, fmt.Errorf("not a xar archive")
	}
	hsize := int(binary.BigEndian.Uint16(blob[4:]))
	clen := int(binary.BigEndian.Uint64(blob[8:]))
	zr, err := zlib.NewReader(bytes.NewReader(blob[hsize : hsize+clen]))
	if err != nil {
		return "", nil, err
	}
	tb, err := io.ReadAll(zr)
	if err != nil {
		return "", nil, err
	}
	heap := blob[hsize+clen:]
	if want := sha1.Sum(blob[hsize : hsize+clen]); !bytes.Equal(heap[:sha1.Size], want[:]) {
		return "", nil, fmt.Errorf("TOC checksum mismatch")
	}
	toc := string(tb)
	members := map[string][]byte{}
	for _, m := range fileRE.FindAllStringSubmatch(toc, -1) {
		n, o, s := nameRE.FindStringSubmatch(m[1]), offRE.FindStringSubmatch(m[1]), sizeRE.FindStringSubmatch(m[1])
		if n == nil || o == nil || s == nil {
			continue
		}
		off, _ := strconv.Atoi(o[1])
		size, _ := strconv.Atoi(s[1])
		// <offset>/<size> of the TOC checksum element also match; entries
		// come from <file> bodies only, whose first <offset> is the data's.
		members[n[1]] = heap[off : off+size]
	}
	return toc, members, nil
}

// packageInfo is mkflatpkg.py's PACKAGE_INFO, formatted.
func packageInfo(identifier, version string) []byte {
	return []byte("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n" +
		"<pkg-info format-version=\"2\" identifier=\"" + identifier + "\" version=\"" + version + "\" install-location=\"/\" auth=\"root\">\n" +
		"    <payload installKBytes=\"0\" numberOfFiles=\"0\"/>\n" +
		"    <scripts>\n" +
		"        <postinstall file=\"./postinstall\"/>\n" +
		"    </scripts>\n" +
		"</pkg-info>\n")
}

// flatPackage is a payload-free component package: PackageInfo, and
// Scripts holding exactly one file, ./postinstall (mode 0755).
func flatPackage(postinstall []byte, identifier, version string) ([]byte, error) {
	scripts, err := gzipDeterministic(makeODC([]cpioEntry{
		{Name: ".", Mode: 0o755, Dir: true},
		{Name: "./postinstall", Mode: 0o755, Data: postinstall},
	}))
	if err != nil {
		return nil, err
	}
	return buildXar([]member{
		{Name: "PackageInfo", Mode: 0o644, Data: packageInfo(identifier, version)},
		{Name: "Scripts", Mode: 0o644, Data: scripts},
	})
}
```

- [ ] **Step 4: Run; commit**

The parity test must *run* here (python3 is present). Paste its logged compressed sizes in the report.

```bash
go test -race ./internal/payload/ -v -run 'Mkflatpkg|CPIO|Xar|Identical' && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add internal/payload
git commit   # subject: "payload: the xar and cpio writers, with mkflatpkg.py's contents to the byte"
```

---

### Task 10: The first-boot package (`payload.Build`)

**Files:**
- Create: `internal/payload/payload.go`, `internal/payload/quote.go`, `internal/payload/payload_test.go`

**Interfaces:**
- Consumes: `flatPackage`, `readXar`, `readODC`, `vmguest.Files`, `proc.Runner`, `fetch.HasXarMagic`, `fetch.SHA256File`, `config.UpdateChoices`.
- Produces:
  - `payload.Config{User, RealName, Hostname, Shell string; UID, GID int; AutoLogin bool; Password string; SSHKey string; OpenSSHPkgs []string; OpenSSHTag string; UpdatePkgs []string; Updates string}`
  - `payload.DefaultConfig() Config`
  - `payload.Identifier = "com.mqg.firstboot"`, `payload.Version = "1.0"`
  - `payload.Conf(c Config) ([]byte, error)`
  - `payload.Postinstall(conf, key []byte) ([]byte, error)`
  - `payload.Build(ctx, r proc.Runner, c Config, out string, log func(string, ...any)) (sha256 string, err error)`, which writes `out` and `out.sha256`
  - `bashQuote(s string) (string, error)`

**The rules** (from `build-firstboot-pkg.sh`):
- **Defaults:** user `mavsuser`, uid 501, gid 20, realname `Mavericks User`, hostname `mavericks`, shell `/bin/bash`, autologin on, no password, updates `none`.
- **`firstboot.conf`**, byte for byte, in this order:
  - the header comment line;
  - `MQG_FB_USER`, `UID`, `GID`, then `MQG_FB_ADMIN_GID=80`;
  - `REALNAME`, `SHELL`, `HOSTNAME`, `AUTOLOGIN` (1 or 0);
  - then either `MQG_FB_OPENSSH=1`, `MQG_FB_OPENSSH_TAG` and `MQG_FB_EXTRA_PKGS` (each basename followed by one space), or `MQG_FB_OPENSSH=0`;
  - then, only if there are update packages, `MQG_FB_UPDATES` and `MQG_FB_UPDATE_PKGS` (basenames, install order, each followed by a space);
  - then, only if set, `MQG_FB_PASSWORD`.

  Every value is `bashQuote`d. The header line stays
  `# Generated by image/payload/build-firstboot-pkg.sh. Do not edit.` until phase 6: the parity test compares against the shell tree's output, and `--updates none`'s conf must stay byte-identical to the baseline (docs/decisions/0011).
- **`bashQuote`** equals bash's `printf '%q'` for printable ASCII:
  - an empty string becomes `''`;
  - these characters are escaped with a backslash: space `'` `"` `\` `|` `&` `;` `(` `)` `<` `>` `!` `{` `}` `*` `[` `?` `]` `^` `$` `` ` `` `,`;
  - `#` is escaped at position 0;
  - `~` is escaped at position 0, or after `=` or `:`.

  Anything else that isn't printable ASCII (control characters, non-ASCII) is an error naming the value's field. The parity test against the host's bash settles the exact set: if bash on this host escapes something this list misses, or doesn't escape something it lists, the test shows it. Fix the list and record the bash version in a comment.
- **`postinstall`** is the embedded `image/payload/postinstall`, with its first `#MQG_EMBEDDED_FILES\n` replaced by four blocks. Each block is exactly:

  ```
  say "writing <dst>"
  cat > "<dst>" <<'MQG_EOF_<VAR>'
  <content>MQG_EOF_<VAR>
  chmod <mode> "<dst>" 2>/dev/null

  ```

  The four blocks, in order:

  | Variable | Content | Destination | Mode |
  |---|---|---|---|
  | `FIRSTBOOT_SH` | embedded `firstboot.sh` | `$CONF_DIR/firstboot.sh` | 755 |
  | `FIRSTBOOT_CONF` | the conf | `$CONF_DIR/firstboot.conf` | 600 |
  | `AUTHORIZED_KEYS` | the key file's bytes | `$CONF_DIR/authorized_keys` | 644 |
  | `LAUNCHDAEMON` | embedded `com.mqg.firstboot.plist` | `$DAEMON` | 644 |

  `$CONF_DIR` and `$DAEMON` are literal: the guest expands them. A missing marker is an error.

  **One deliberate difference from the shell:** if a content doesn't end in `\n`, append one. The shell's `cat` would otherwise glue the heredoc terminator onto the last line, which silently breaks the heredoc. Test it, and note it in the code.
- **Before packaging:** `sh -n <tempfile>` via the Runner, where a failure is an error saying "the assembled postinstall is not valid shell". The package is written to `out.tmp` and renamed. The sidecar `out.sha256` is `<hex>  <basename(out)>\n`.
- **Validation:**
  - The SSH key file must exist.
  - Some line must start with `ssh-` or `ecdsa-`.
  - If its first 64 bytes contain `PRIVATE`, refuse it and say to pass the `.pub`.
  - Its type is the first field of its first line. Without OpenSSH packages, a type containing `ed25519` is refused (the message names OpenSSH 6.2, Ed25519 arriving in 6.5, and `ssh-keygen -t rsa -b 4096`). `ssh-rsa`, `ssh-dss` and `ecdsa-sha2-*` pass, and anything else is logged as a warning.
  - With OpenSSH packages, `ssh-ed25519`, `ssh-rsa`, `ssh-dss`, `ecdsa-sha2-*` and `sk-*` pass, and anything else is a warning.
  - Every OpenSSH or update package must exist, carry the `xar!` magic, and have a basename without whitespace.
  - OpenSSH packages without a tag are refused.
  - `Updates` must be one of the choices. Packages with `none` are refused ("carry packages it does not admit to"), and so is no packages with `security` or `all`.

- [ ] **Step 1: Write the failing tests**

`internal/payload/payload_test.go`. The helpers:
- a key writer that produces an RSA or an Ed25519 `.pub` with x/crypto's `ssh.MarshalAuthorizedKey`, which ends in `\n`;
- a fake-package writer (`xar!` plus filler);
- `extractPostinstall(pkg []byte) []byte`, via `readXar`, `gunzip` and `readODC`;
- `shellPostinstall(t, args...) []byte`: runs `image/payload/build-firstboot-pkg.sh --out <tmp>/sh.pkg <args>` with `MQG_IMAGE_DIR` set to a temp dir, and extracts its postinstall. Skip when python3 or sha256sum is absent; CI has both.

The tests:
1. **`TestBashQuoteMatchesBash`.** A corpus: `mavsuser`, `Mavericks User`, `/bin/bash`, `a.pkg b.pkg `, `it's`, `$HOME`, `~root`, `a=~b`, `#x`, `x#`, `100%`, `a,b`, `semi;colon`, `""`, `back\slash`. Each must equal `bash -c 'printf %q "$1"' _ <s>` (skip if bash is absent). Control characters are refused.
2. **`TestConfDefaultsAreTheShellTreesByteForByte`.** Parity: `Postinstall(Conf(DefaultConfig()), rsaKey)` equals the shell's postinstall for `--ssh-key rsa.pub`, byte for byte.
3. **`TestConfWithOpenSSHAndUpdatesMatchesTheShell`.** The same parity with an Ed25519 key, two fake OpenSSH packages, `--openssh-tag 10.5p1-mavericks.2`, `--updates security` and one fake `mqg-update-01-SecUpd2016-004Mavericks.pkg`.
4. **`TestANoneConfSaysNothingAboutUpdates`.** No `MQG_FB_UPDATES` line appears.
5. **`TestKeyRules`.**
   - Ed25519 without OpenSSH is refused, and the message contains `6.5`.
   - Ed25519 with OpenSSH is accepted.
   - A file containing `-----BEGIN OPENSSH PRIVATE KEY-----` is refused (`PRIVATE`).
   - `not a key` is refused.
   - A missing file is refused.
6. **`TestPackageRules`.**
   - A whitespace basename is refused.
   - A non-xar file is refused.
   - OpenSSH packages without a tag are refused.
   - Updates `none` with packages is refused.
   - `security` without packages is refused.
   - `sometimes` is refused.
7. **`TestAMissingTrailingNewlineStillTerminatesTheHeredoc`.** A key file without a final `\n` gives a postinstall where `MQG_EOF_AUTHORIZED_KEYS` is on its own line.
8. **`TestBuildWritesThePackageAndSidecarDeterministically`.** Build twice with the real `proc.Exec`, which runs `sh -n`. Same sha both times; the sidecar reads `<sha>  mqg-firstboot.pkg\n`; the package starts `xar!`.
9. **`TestTheBuiltPostinstallInstallsThePayloadOnATargetOffline`.** Port of the bats test of the same name:
   - Extract the postinstall from a Build and run `sh postinstall <out> / <target> /` (argument 3 is the target volume) against a temp directory.
   - Assert that `private/var/db/.mqg-firstboot/firstboot.sh` equals the embedded `firstboot.sh`.
   - Assert that `authorized_keys` equals the key.
   - Assert that `firstboot.conf` contains `MQG_FB_USER=mavsuser` and no `MQG_FB_PASSWORD`.
   - Assert that `Library/LaunchDaemons/com.mqg.firstboot.plist` equals the embedded plist.
   - Assert that `private/var/db/.AppleSetupDone` exists.
   - Assert that the modes are 755, 600, 644 and 644. `chown` failing as non-root is expected and ignored by the script.
10. **`TestBuildRefusesAnInvalidPostinstall`.** A `proc.Fake` whose `sh -n` fails makes Build return an error containing "not valid shell" and writes no package.

Run → FAIL.

- [ ] **Step 2: Implement `quote.go`, then `payload.go`, to those rules**

`bashQuote` is a straightforward loop over the rules above.

For `Build`, the order is:
1. Validate.
2. Build the conf.
3. Read the key.
4. Build the postinstall.
5. Write it to a temp file and run `sh -n` through `r`.
6. `flatPackage(post, Identifier, Version)`.
7. Write `out.tmp`, `fsync`, rename to `out`.
8. `fetch.SHA256File(out)`, then write the sidecar.
9. `log` the built size and sha, and the key's type plus its first 16 characters, as the shell does.

Use the embedded files through `fs.ReadFile(vmguest.Files, "image/payload/…")`. Every error names the field or path it concerns.

- [ ] **Step 3: Run; commit**

Every parity test must *run* here (bash, python3 and sha256sum are present). Paste their output in the report.

```bash
go test -race ./internal/payload/ -v && go test -race ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
./bin/run-tests.sh >/tmp/suite-phase2.log 2>&1; echo "shell suite $?"
git add internal/payload
git commit   # subject: "payload: the first-boot package in Go, the shell tree's postinstall to the byte"
```

---

### Task 11: Measure it, and say so

**Files:**
- Modify: `NOTES.md` (append only), `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` (§9: phase 2's status), `README.md` (only if a claim changes)

This task uses the real network. Record `date -u +%FT%TZ` before each measurement.

- [ ] **Step 1: Build and prepare**

```bash
go build -o out/vmavs ./cmd/vmavs
date -u +%FT%TZ
```

- [ ] **Step 2: The guest's OpenSSH, from GitHub, into a fresh home**

```bash
export VMAVS_HOME=$(mktemp -d /tmp/vmavs-p2.XXXXXX)
time ./out/vmavs fetch openssh
```

Record the two paths, their sizes and the time. Verify each file's sha256 against the release's `SHA256SUMS` independently: `sha256sum` against the cached `SHA256SUMS`.

- [ ] **Step 3: Apple's handshake, without the 5 GB**

```bash
./out/vmavs fetch esd --probe
```

Record the URL and size. The URL must equal the registry's. If Apple refuses the handshake, record the exact error. It is a finding, not something to work around.

- [ ] **Step 4: Adoption of the shell tree's downloads, with no network traffic**

```bash
export VMAVS_HOME=$HOME/.local/share/mavericks-qemu-guest
stat -c '%n %s %Y %i' $VMAVS_HOME/media/InstallESD.dmg $VMAVS_HOME/updates/*.pkg
time ./out/vmavs fetch --updates security
stat -c '%n %s %Y %i' $VMAVS_HOME/media/InstallESD.dmg $VMAVS_HOME/updates/*.pkg
ls -li $VMAVS_HOME/cache/*/
```

Expected:
- every input is "adopted" on stderr and nothing is downloaded (the time is dominated by hashing 5 GB);
- the old files have unchanged size, mtime and inode;
- the cache entries are hard links to them (same inode).

This creates `cache/` in the shell tree's home, which is new files only. Say so in NOTES.md. Remove that `cache/` directory afterwards only if the user asks: it is ours, and it takes no extra space.

- [ ] **Step 5: NOTES.md, and the spec**

Append a dated entry (the date from Step 1) in NOTES.md's format:
`## <date> — P8 — vmavs fetch and the Go payload`.

What it contains:
- Steps 2–4, verbatim, labelled MEASURED.
- The payload's parity results (Tasks 9 and 10: which parity tests ran, and the compressed sizes).
- What was not measured: an install using the Go-built payload happens in phase 5, when the Go pipeline can build an image.

In spec §9's phase table, mark phase 2 delivered, dated, with a pointer to the NOTES entry. Quote phase 2's row and check each item it lists against what shipped. If one is missing, say so rather than marking it delivered.

- [ ] **Step 6: Run everything; commit**

```bash
go test -race ./... && ./bin/run-tests.sh >/tmp/suite.log 2>&1; echo "shell $?"; bats tests/release.bats
git add NOTES.md docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md README.md
git commit   # subject: "NOTES: vmavs fetch reaches Apple and GitHub, and adopts the shell tree's downloads"
```

---

## Self-review

**Spec coverage** (spec §9, phase 2 row: `pins`, `fetch`, `payload` with a xar writer):

| Requirement | Covered by |
|---|---|
| `pins` | Task 3 |
| `fetch`: esd, openssh, updates; `vmavs fetch` | Tasks 4–8 |
| `payload` with a xar writer | Tasks 9–10 |
| embedded data (§3) | Task 2, with the path deviation amended in the spec |
| `cache/` keyed by sha256 (§5) | Task 4 |
| parity tests (§7) | Tasks 3, 9, 10 |
| carrying the bats knowledge (§7) | Tasks 4–7 and 10 name the bats cases they port |
| measurement (§10's discipline) | Task 11 |

Phase 1 review carry-overs:
- flags only in cli: Task 1;
- a macOS runner: Task 1;
- the date and claims-grep rules: Global Constraints and Task 11;
- "only delete what you created": adoption links or copies and never moves.

**Out of phase:**
- Firmware sources (edk2, opencorepkg, kexts, `fetch_source` for the build dir): phase 3, with their consumer.
- Staging update links on the media: phase 4.
- Stage digests and the manifest: phase 5.
- TOFU pinning: stays in the shell tree until phase 6.

**Types:**
- `Getter` and `Item` (Task 4) are used by Tasks 5–8.
- `Item.noFetch` and `errNotCached` are added in Task 7.
- `pins.Registry.Lookup` is used by Tasks 6–8.
- `config.UpdateChoices`/`DefaultUpdates` (Task 6) are used by Tasks 8 and 10.
- `flatPackage`, `readXar` and `readODC` (Task 9) are used by Task 10.
