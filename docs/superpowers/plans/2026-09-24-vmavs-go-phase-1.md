# vmavs in Go, Phase 1: skeleton, `run`, `ssh`, `emit packer`, `doctor`, `version`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a Go `vmavs` binary that can boot an image the shell pipeline
already built (`vmavs run`), open a shell in it (`vmavs ssh`), emit a
Packer template for the same machine (`vmavs emit packer`), report what the
host can do (`vmavs doctor`), and print its version. Close the P8 exit, "a
clean checkout to a shell in a guest", for any host that has a built image.

**Architecture:**
- `cmd/vmavs` is ten lines. `internal/cli` owns the flags, help and exit
  codes, and calls plain domain packages:
  - `config`, `manifest` and `machine` describe what to run;
  - `proc` runs external commands;
  - `vm` prepares a run directory;
  - `guest` speaks SSH;
  - `emit` writes HCL;
  - `doctor` judges the host.
- Every external command goes through `proc.Runner`, so every command is
  testable with a fake.

**Tech Stack:**
- Go 1.26 (the family's toolchain is 1.26.8).
- `golang.org/x/crypto/ssh`.
- `golang.org/x/term`.
- `github.com/hashicorp/hcl/v2/hclwrite`, with `github.com/zclconf/go-cty`.
- Standard `testing`.

**Spec:** `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` (read
§2–§5, §7–§9). Decision record: `docs/decisions/0013-vmavs-is-a-go-program.md`.

## Global Constraints

- `go.mod` says `module github.com/Mavergreen/vm-guest` and `go 1.26.0`.
  On this host the installed Go is 1.22.2; `GOTOOLCHAIN=auto` (the
  default) downloads go1.26 on the first build, and the user approved
  that.
- Dependencies:
  - the standard library;
  - `golang.org/x/crypto`;
  - `golang.org/x/term`;
  - `github.com/hashicorp/hcl/v2`;
  - `github.com/zclconf/go-cty`, required by hclwrite.

  Nothing else. Nothing from `github.com/hashicorp/packer` (BUSL-1.1).
  No CLI framework: use `flag`.
- The binary builds to `out/vmavs`, never `bin/vmavs`. The shell
  `bin/vmavs` and everything it dispatches to stay untouched and working
  in this phase. They are the reference until phase 6.
- Exit codes: 0 for success, 1 for failure, 2 for a usage error. For
  `vmavs ssh -- CMD`, the remote command's own status.
- Log lines go to stderr as `vmavs <subcommand>: …`, and errors as
  `vmavs <subcommand>: error: …`. Stdout carries only a command's output.
- Environment variables: `VMAVS_HOME` (default `~/.local/share/vmavs`),
  `VMAVS_QEMU` (default `qemu-system-x86_64`), `VMAVS_SSH_KEY`. Do not
  read `MQG_*`.
- **Never publish or embed Apple's bytes.** No test fixture contains Apple
  data. The Packer template names local paths only and never carries
  `osk=`.
- **Every claim is MEASURED, INHERITED or REASONED, and says which** —
  in comments, help text, the template header and NOTES.md.
- Tests must pass on `ubuntu-latest` with no QEMU, no KVM, no packer and
  no Apple media. Anything needing those is a fake, or it is in Task 9's
  manual measurement.
- `go vet ./...`, `go test ./...` and `staticcheck ./...` are clean. The
  shell suite `./bin/run-tests.sh` stays green (this phase does not touch
  shell files, except where noted).
- Each commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QX6srqxQqri25igdYHqmNo
  ```

## Facts this plan relies on

All MEASURED on 2026-09-24, from files in this repository or on this host.

- **The machine.** The canonical QEMU command line is `qemu_args()` in
  `image/build-image.sh:406-452`. Task 3 reproduces it exactly.
- **Manifests.** They live at `images/<name>.manifest` beside
  `<name>.qcow2`, as `key<TAB>value` lines with `#` comments. The fields
  Phase 1 uses:
  - `name`.
  - `nic`: absent in manifests built before commit a9f8c61 (2026-09-21);
    those images were installed with `usb-net`.
  - `openssh`: absent, or `none`, when the guest runs Apple's OpenSSH
    6.2. It was absent before commit 3bde057.
  - `sshkey`: the first token is a `SHA256:` fingerprint.
  - `accel`: for example
    `kvm machine=q35 cpu=Penryn,+ssse3,+sse4.1,+sse4.2 ram=4096 smp=2 disk=60G`.
- **The shell tree's state on this host** is under
  `~/.local/share/mavericks-qemu-guest`:
  - `images/mavericks-20260922.{qcow2,manifest}` (has `openssh` and `nic`);
  - `images/mavericks-a.{qcow2,manifest}` (neither `openssh` nor `nic`);
  - `build/firmware/OVMF_CODE.fd` and `OVMF_VARS.fd`;
  - `work/opencore-p3.img`;
  - `keys/mqg_rsa{,.pub}`.

  `images/u-none.manifest` has no `.qcow2` beside it.
- **Defaults** (`image/build-image.sh:97-130`, `lib/cpu.sh:90`,
  `lib/smbios.sh:77`):
  - accel `kvm`, machine `q35`;
  - cpu `Penryn,+ssse3,+sse4.1,+sse4.2`, smbios `iMac14,2`;
  - ram 4096, smp 2, disk 60 GB;
  - ssh port 2222, user `mavsuser`;
  - nic `e1000-82545em`, with choices `usb-net e1000-82545em virtio-net-pci`.
- **Packer 1.16.1** (qemu plugin 1.1.6, vagrant plugin 1.1.7) accepted a
  template with:
  - both plugins in `required_plugins`;
  - `host_port_min`/`host_port_max`, not the deprecated `ssh_host_port_*`;
  - `machine_type = "q35,vmport=off"`;
  - drives kept in `qemuargs`;
  - `-var` placeholders for every variable, and a real parseable key file
    for `ssh_private_key_file`.

  See NOTES.md, 2026-09-24.
- **This host** has `/dev/kvm` and QEMU 8.2.2.

## File structure

| Path | Responsibility |
|---|---|
| `go.mod`, `go.sum` | module, dependencies |
| `embed.go` | root package `vmguest`: embeds `UPSTREAM_VERSION` (go:embed cannot reach parent directories) |
| `cmd/vmavs/main.go` | signals → context, `cli.Run`, `os.Exit` |
| `internal/version/version.go` | `vmavs version` text |
| `internal/cli/cli.go` | command table, `Env`, errors, help, exit codes, logging |
| `internal/cli/{version,run,ssh,emit,doctor}.go` | one file per subcommand: flags + wiring |
| `internal/config/config.go` | defaults, `Paths`, `Home`, `LegacyHint`, `QEMU` |
| `internal/config/machine.go` | `Machine` options, flag registration, validation, overrides |
| `internal/manifest/manifest.go` | parse, find, list, hardware, SSH facts |
| `internal/proc/proc.go` | `Runner`, `Exec`, `Fake`, `Cmd` |
| `internal/machine/machine.go` | `Spec`, roles, `Args()` — the one machine definition |
| `internal/guest/ssh.go`, `keys.go` | SSH client config, dial, exec, interactive shell, key choice |
| `internal/guest/guesttest/server.go` | in-process SSH server for tests |
| `internal/vm/vm.go` | run directory: overlay, NVRAM, state file, live runs |
| `internal/emit/packer.go`, `hcl.go` | Packer HCL via hclwrite |
| `internal/doctor/doctor.go` | host rows, subcommand readiness, verdict |
| `.github/workflows/ci.yml` | new `go` job; `packer-validate` switches to Go |
| `.gitignore` | `/out/` |

---

### Task 1: Module skeleton, `vmavs version`, `vmavs help`, and CI

**Files:**
- Create: `go.mod`, `embed.go`, `cmd/vmavs/main.go`, `internal/version/version.go`, `internal/version/version_test.go`, `internal/cli/cli.go`, `internal/cli/version.go`, `internal/cli/cli_test.go`
- Modify: `.gitignore`, `.github/workflows/ci.yml`, `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` (package-name amendment, Step 9)

**Interfaces:**
- Produces:
  - `cli.Run(ctx context.Context, args []string, e *cli.Env) int`
  - `cli.Env{Stdin io.Reader; Stdout, Stderr io.Writer; Getenv func(string) string}`.
    Task 3 adds `Runner proc.Runner`, and Task 5 adds `PID int`.
  - `cli.UsageError`, `cli.ExitError{Code int}`, `usagef`
  - `newFlags(name string) *flag.FlagSet`
  - `parse(fs, e, help string, args []string) error`
  - `logf(e, cmd, format, ...)`
  - `commandTable() []command`, where `command{name, summary string; run func(ctx, *Env, []string) error}`
  - `version.String() string`, `version.Full`

- [ ] **Step 1: Create the module and the embed package**

```bash
cd /home/schmonz/Documents/trees/mavergreen-vm-guest
cat > go.mod <<'EOF'
module github.com/Mavergreen/vm-guest

go 1.26.0
EOF
printf '\n# The Go vmavs builds here; bin/vmavs is still the shell dispatcher\n# until phase 6 of docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md.\n/out/\n' >> .gitignore
```

`embed.go`:

```go
// Package vmguest is the repository root. It exists to carry files into
// the vmavs binary with go:embed, which cannot reach outside the directory
// of the package that uses it.
package vmguest

import _ "embed"

// UpstreamVersion is this product's own version line, a bare YYYYMMDD,
// exactly as UPSTREAM_VERSION holds it (docs/decisions/0012).
//
//go:embed UPSTREAM_VERSION
var UpstreamVersion string
```

- [ ] **Step 2: Write the failing version test**

`internal/version/version_test.go`:

```go
package version

import (
	"regexp"
	"testing"
)

func TestDevBuildSaysItIsADevBuild(t *testing.T) {
	// A development build must never print something that looks like a
	// release: YYYYMMDD.N is what a release tag looks like.
	Full = ""
	got := String()
	re := regexp.MustCompile(`^[0-9]{8}\.0-dev(\+[0-9a-f]{1,12}(\.dirty)?)?$`)
	if !re.MatchString(got) {
		t.Fatalf("String() = %q, want YYYYMMDD.0-dev[+rev[.dirty]]", got)
	}
}

func TestReleaseBuildPrintsTheReleaseVersion(t *testing.T) {
	Full = "20260922.3"
	defer func() { Full = "" }()
	if got := String(); got != "20260922.3" {
		t.Fatalf("String() = %q, want 20260922.3", got)
	}
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `go test ./internal/version/`
Expected: FAIL. `String` and `Full` are undefined. The first `go`
invocation downloads the go1.26 toolchain.

- [ ] **Step 4: Implement `internal/version/version.go`**

```go
// Package version answers `vmavs version`.
package version

import (
	"runtime/debug"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
)

// Full is the release version, YYYYMMDD.N. It is set only when a release
// is built:
//
//	go build -ldflags "-X github.com/Mavergreen/vm-guest/internal/version.Full=$FULL"
//
// with FULL from build/version.sh. It is empty in a development build.
var Full string

// String is the release version. For a development build it is the
// version line with ".0-dev" and the commit it was built from, so it can
// never be mistaken for a release.
func String() string {
	if Full != "" {
		return Full
	}
	s := strings.TrimSpace(vmguest.UpstreamVersion) + ".0-dev"
	if rev, dirty := vcs(); rev != "" {
		if len(rev) > 12 {
			rev = rev[:12]
		}
		s += "+" + rev
		if dirty {
			s += ".dirty"
		}
	}
	return s
}

func vcs() (rev string, dirty bool) {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "", false
	}
	for _, kv := range info.Settings {
		switch kv.Key {
		case "vcs.revision":
			rev = kv.Value
		case "vcs.modified":
			dirty = kv.Value == "true"
		}
	}
	return rev, dirty
}
```

Run: `go test ./internal/version/` → PASS.

- [ ] **Step 5: Write the failing CLI tests**

`internal/cli/cli_test.go`:

```go
package cli

import (
	"bytes"
	"context"
	"regexp"
	"strings"
	"testing"
)

// vmavs runs the CLI in-process and returns what a shell would see.
func vmavs(t *testing.T, env map[string]string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	e := &Env{
		Stdin:  strings.NewReader(""),
		Stdout: &out,
		Stderr: &errb,
		Getenv: func(k string) string { return env[k] },
	}
	code := Run(context.Background(), args, e)
	return code, out.String(), errb.String()
}

func TestNoArgumentsIsAUsageError(t *testing.T) {
	code, _, stderr := vmavs(t, nil)
	if code != 2 || !strings.Contains(stderr, "usage: vmavs") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestHelpListsEverySubcommandAndGoesToStdout(t *testing.T) {
	code, stdout, _ := vmavs(t, nil, "help")
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	for _, c := range commandTable() {
		if !strings.Contains(stdout, "  "+c.name) {
			t.Errorf("help omits %q", c.name)
		}
	}
}

func TestUnknownSubcommandNamesItself(t *testing.T) {
	code, _, stderr := vmavs(t, nil, "instal")
	if code != 2 || !strings.Contains(stderr, `"instal"`) {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestVersionPrintsOneLine(t *testing.T) {
	for _, arg := range []string{"version", "--version"} {
		code, stdout, stderr := vmavs(t, nil, arg)
		if code != 0 || stderr != "" {
			t.Fatalf("%s: code=%d stderr=%q", arg, code, stderr)
		}
		if !regexp.MustCompile(`^[0-9]{8}\.[0-9]+[^\n]*\n$`).MatchString(stdout) {
			t.Fatalf("%s: stdout=%q", arg, stdout)
		}
	}
}

func TestEverySubcommandTakesHelp(t *testing.T) {
	for _, c := range commandTable() {
		code, stdout, _ := vmavs(t, nil, c.name, "--help")
		if code != 0 || !strings.HasPrefix(stdout, "usage: vmavs "+c.name) {
			t.Errorf("%s --help: code=%d stdout=%q", c.name, code, stdout)
		}
	}
}

func TestVersionRefusesArguments(t *testing.T) {
	code, _, stderr := vmavs(t, nil, "version", "extra")
	if code != 2 || !strings.Contains(stderr, "vmavs version:") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}
```

Run: `go test ./internal/cli/` → FAIL (package has no code).

- [ ] **Step 6: Implement `internal/cli/cli.go` and `internal/cli/version.go`**

`internal/cli/cli.go`:

```go
// Package cli is vmavs's command line: the subcommand table, flag
// parsing, help, logging and exit codes. It is the only package that knows
// about flags or argv; everything it calls takes plain values.
package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
)

// Env is everything a subcommand may touch outside its arguments, so that
// tests can run the whole CLI in-process.
type Env struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
	Getenv func(string) string
}

type command struct {
	name    string
	summary string
	run     func(ctx context.Context, e *Env, args []string) error
}

// commandTable is every subcommand, in the order help lists them.
func commandTable() []command {
	return []command{
		{"version", "Print this vmavs's version", cmdVersion},
	}
}

// UsageError is a mistake in how vmavs was invoked: exit status 2.
type UsageError struct{ msg string }

func (u *UsageError) Error() string { return u.msg }

func usagef(format string, a ...any) error {
	return &UsageError{fmt.Sprintf(format, a...)}
}

// ExitError carries another program's exit status out of vmavs unchanged:
// `vmavs ssh -- false` exits 1 because false did.
type ExitError struct{ Code int }

func (x *ExitError) Error() string { return fmt.Sprintf("exit status %d", x.Code) }

// Run is vmavs. It returns the process exit status.
func Run(ctx context.Context, args []string, e *Env) int {
	if len(args) == 0 {
		usage(e.Stderr)
		return 2
	}
	name, rest := args[0], args[1:]
	switch name {
	case "help", "-h", "--help":
		usage(e.Stdout)
		return 0
	case "--version":
		name = "version"
	}
	for _, c := range commandTable() {
		if c.name == name {
			return exitCode(e.Stderr, name, c.run(ctx, e, rest))
		}
	}
	fmt.Fprintf(e.Stderr, "vmavs: unknown subcommand %q\n\n", name)
	usage(e.Stderr)
	return 2
}

func exitCode(w io.Writer, name string, err error) int {
	var ue *UsageError
	var xe *ExitError
	switch {
	case err == nil, errors.Is(err, flag.ErrHelp):
		return 0
	case errors.As(err, &xe):
		return xe.Code
	case errors.As(err, &ue):
		fmt.Fprintf(w, "vmavs %s: %v\nrun 'vmavs %s --help' for usage\n", name, err, name)
		return 2
	default:
		fmt.Fprintf(w, "vmavs %s: error: %v\n", name, err)
		return 1
	}
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: vmavs <subcommand> [options]")
	fmt.Fprintln(w)
	for _, c := range commandTable() {
		fmt.Fprintf(w, "  %-10s %s\n", c.name, c.summary)
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Every subcommand takes --help.")
}

// newFlags is a FlagSet that reports its errors instead of printing them;
// parse turns those into UsageErrors, and -h/--help into help on stdout.
func newFlags(name string) *flag.FlagSet {
	fs := flag.NewFlagSet("vmavs "+name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.Usage = func() {}
	return fs
}

// parse parses args. Asking for help prints help, which begins
// "usage: vmavs <name>", to stdout and returns flag.ErrHelp, which exits 0.
func parse(fs *flag.FlagSet, e *Env, help string, args []string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(e.Stdout, help)
			hasFlags := false
			fs.VisitAll(func(*flag.Flag) { hasFlags = true })
			if hasFlags {
				fmt.Fprintln(e.Stdout, "\noptions:")
				fs.SetOutput(e.Stdout)
				fs.PrintDefaults()
				fs.SetOutput(io.Discard)
			}
			return flag.ErrHelp
		}
		return usagef("%v", err)
	}
	return nil
}

// logf writes one "vmavs <cmd>: ..." line to stderr.
func logf(e *Env, cmd, format string, a ...any) {
	fmt.Fprintf(e.Stderr, "vmavs %s: %s\n", cmd, fmt.Sprintf(format, a...))
}
```

`internal/cli/version.go`:

```go
package cli

import (
	"context"
	"fmt"

	"github.com/Mavergreen/vm-guest/internal/version"
)

const versionHelp = `usage: vmavs version

Print this vmavs's version: YYYYMMDD.N for a release, or
YYYYMMDD.0-dev+<commit> for a development build.
`

func cmdVersion(_ context.Context, e *Env, args []string) error {
	fs := newFlags("version")
	if err := parse(fs, e, versionHelp, args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usagef("version takes no arguments")
	}
	fmt.Fprintln(e.Stdout, version.String())
	return nil
}
```

- [ ] **Step 7: Write `cmd/vmavs/main.go`; run the tests**

```go
// Command vmavs runs OS X 10.9 Mavericks in a VM.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/Mavergreen/vm-guest/internal/cli"
)

func main() {
	// Ctrl-C cancels the context: a VM stops, a run directory is cleaned
	// up, and vmavs exits, instead of vmavs dying first and leaking both.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := cli.Run(ctx, os.Args[1:], &cli.Env{
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Getenv: os.Getenv,
	})
	stop()
	os.Exit(code)
}
```

Run: `go vet ./... && go test ./... && go build -o out/vmavs ./cmd/vmavs && ./out/vmavs version && ./out/vmavs help`
Expected: tests PASS. `version` prints e.g. `20260922.0-dev+<rev>.dirty`,
and help lists `version`.

- [ ] **Step 8: Add the `go` CI job**

Append to `.github/workflows/ci.yml`, after the `packer-validate` job:

```yaml

  # The Go vmavs (docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md).
  # Builds for every host the tool targets, not only the one CI runs on:
  # a darwin or netbsd build break is found here, not by a user.
  go:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-go@v7.0.0
        with:
          go-version-file: go.mod

      - name: Vet
        run: go vet ./...

      - name: Test
        run: go test ./...

      - name: Staticcheck
        run: go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...

      - name: Cross-build
        run: |
          set -eu
          for target in linux/amd64 darwin/amd64 darwin/arm64 netbsd/amd64; do
              GOOS=${target%/*} GOARCH=${target#*/} go build -o /dev/null ./cmd/vmavs
          done
```

Validate: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`.
Run the staticcheck command locally too; it must be clean.

- [ ] **Step 9: Amend the spec's package names**

In `docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md` §3, make the
layout match this plan, which is what the code will have:

- rename `run/` to `proc/`, since a package named `run` reads as the `run`
  subcommand;
- add `manifest/` (built-image manifests: parse, find, hardware, SSH
  facts);
- add `vm/` (run directories: overlay, NVRAM, state);
- add `golang.org/x/term` to Dependencies, for the interactive shell's raw
  mode.

In the §3 layout block and the Dependencies list, and `run.Runner` in §6
becomes `proc.Runner`.

- [ ] **Step 10: Run all checks and commit**

```bash
go vet ./... && go test ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
git add go.mod embed.go cmd internal .gitignore .github/workflows/ci.yml docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md
git commit   # subject: "vmavs (Go): the module, version, help, and a CI job for three OSes"
```

---

### Task 2: `config` and `manifest`

**Files:**
- Create: `internal/config/config.go`, `internal/config/machine.go`, `internal/config/config_test.go`, `internal/manifest/manifest.go`, `internal/manifest/manifest_test.go`, `internal/manifest/testdata/images/{current.manifest,current.qcow2,legacy.manifest,legacy.qcow2,orphan.manifest}`

**Interfaces:**
- Produces:
  - `config.Default*` constants
  - `config.NICChoices []string`
  - `config.Paths{Home string}`, with `Images() Build() Firmware() OVMFCode() OVMFVarsTemplate() Work() Run() Keys() Cache() OpenCoreImage()`
  - `config.Home(getenv) (string, error)`
  - `config.LegacyHint(getenv, exists func(string) bool) string`
  - `config.QEMU(getenv) string`
  - `config.Machine{Accel, Type, CPU, NIC, Display string; MemoryMB, SMP, SSHPort int}`
  - `config.DefaultMachine() Machine`
  - `(*Machine).Register(fs *flag.FlagSet)`
  - `(Machine).Validate() error`
  - `(*Machine).Override(from Machine, set func(name string) bool)`
  - `manifest.Manifest{Name, Path string; ModTime time.Time}`, with `Get(key) string`, `Image() string`, `Hardware() config.Machine`, `LegacySSH() bool`, `SSHKeyFingerprint() string`
  - `manifest.Load(path) (Manifest, error)`
  - `manifest.List(imagesDir) ([]Manifest, error)`, newest first, only those with a `.qcow2`
  - `manifest.Find(imagesDir, name) (Manifest, error)`

- [ ] **Step 1: Write the fixtures**

`internal/manifest/testdata/images/current.manifest`, copied from the real
`mavericks-20260922.manifest` with the fields Phase 1 reads, plus a comment
header:

```
# mavericks-qemu-guest image manifest
name	current
sshkey	SHA256:20V3dlDtWnv2FKbn3sB6ljy2Zb24Ka0RWHf4tjQbPqs build
openssh	10.5p1-mavericks.2
nic	e1000-82545em
accel	kvm machine=q35 cpu=Penryn,+ssse3,+sse4.1,+sse4.2 ram=4096 smp=2 disk=60G
```

`legacy.manifest`, shaped like `mavericks-a.manifest` (no `nic`, no
`openssh`), with non-default hardware so the test proves the values are
read:

```
name	legacy
sshkey	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAAA build
accel	tcg machine=q35 cpu=Nehalem ram=2048 smp=1 disk=60G
```

`orphan.manifest`: `name	orphan`, with no `.qcow2` beside it.
`current.qcow2` and `legacy.qcow2` are empty files (`: > …`); tests never
open them.

- [ ] **Step 2: Write the failing tests**

`internal/config/config_test.go`:

```go
package config

import (
	"flag"
	"path/filepath"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestHomeIsVMAVS_HOMEElseXDGStyleDefault(t *testing.T) {
	if h, _ := Home(env(map[string]string{"VMAVS_HOME": "/x", "HOME": "/h"})); h != "/x" {
		t.Fatalf("got %q", h)
	}
	if h, _ := Home(env(map[string]string{"HOME": "/h"})); h != "/h/.local/share/vmavs" {
		t.Fatalf("got %q", h)
	}
	if _, err := Home(env(nil)); err == nil {
		t.Fatal("no HOME and no VMAVS_HOME must be an error")
	}
}

func TestLegacyHintOnlyWhenOnlyTheOldHomeExists(t *testing.T) {
	old := "/h/.local/share/mavericks-qemu-guest"
	exists := func(p string) bool { return p == old }
	hint := LegacyHint(env(map[string]string{"HOME": "/h"}), exists)
	if !strings.Contains(hint, "export VMAVS_HOME="+old) || !strings.Contains(hint, "mv "+old) {
		t.Fatalf("hint = %q", hint)
	}
	if LegacyHint(env(map[string]string{"HOME": "/h", "VMAVS_HOME": "/x"}), exists) != "" {
		t.Fatal("an explicit VMAVS_HOME needs no hint")
	}
	both := func(p string) bool { return true }
	if LegacyHint(env(map[string]string{"HOME": "/h"}), both) != "" {
		t.Fatal("no hint once the new home exists")
	}
}

func TestOpenCoreImageFallsBackToTheShellTreesPath(t *testing.T) {
	home := t.TempDir()
	p := Paths{Home: home}
	if got := p.OpenCoreImage(); got != filepath.Join(home, "build", "opencore.img") {
		t.Fatalf("with neither present, want the new path, got %q", got)
	}
	mustWrite(t, filepath.Join(home, "work", "opencore-p3.img"))
	if got := p.OpenCoreImage(); got != filepath.Join(home, "work", "opencore-p3.img") {
		t.Fatalf("legacy only: got %q", got)
	}
	mustWrite(t, filepath.Join(home, "build", "opencore.img"))
	if got := p.OpenCoreImage(); got != filepath.Join(home, "build", "opencore.img") {
		t.Fatalf("both: the new path wins, got %q", got)
	}
}

func TestMachineFlagsOverrideOnlyWhatWasSet(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	flagged := DefaultMachine()
	flagged.Register(fs)
	if err := fs.Parse([]string{"--memory", "8192"}); err != nil {
		t.Fatal(err)
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	fromImage := DefaultMachine()
	fromImage.NIC = "usb-net"
	fromImage.Override(flagged, func(n string) bool { return set[n] })
	if fromImage.MemoryMB != 8192 || fromImage.NIC != "usb-net" {
		t.Fatalf("got %+v", fromImage)
	}
}

func TestMachineValidateRefusesAnUnknownNIC(t *testing.T) {
	m := DefaultMachine()
	m.NIC = "rtl8139"
	if err := m.Validate(); err == nil || !strings.Contains(err.Error(), "e1000-82545em") {
		t.Fatalf("err = %v", err)
	}
}

func TestQEMUHonoursVMAVS_QEMU(t *testing.T) {
	if QEMU(env(nil)) != "qemu-system-x86_64" || QEMU(env(map[string]string{"VMAVS_QEMU": "/q"})) != "/q" {
		t.Fatal("VMAVS_QEMU not honoured")
	}
}
```

(`mustWrite(t, path)` creates the parent directories and an empty file.
Define it at the bottom of the test file.)

`internal/manifest/manifest_test.go`:

```go
package manifest

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const images = "testdata/images"

func TestListSkipsManifestsWithoutAnImageAndSortsNewestFirst(t *testing.T) {
	now := time.Now()
	os.Chtimes(filepath.Join(images, "legacy.manifest"), now, now)
	os.Chtimes(filepath.Join(images, "current.manifest"), now.Add(-time.Hour), now.Add(-time.Hour))
	ms, err := List(images)
	if err != nil {
		t.Fatal(err)
	}
	if len(ms) != 2 || ms[0].Name != "legacy" || ms[1].Name != "current" {
		t.Fatalf("got %v", names(ms))
	}
}

func TestHardwareIsWhatTheImageWasInstalledWith(t *testing.T) {
	cur, _ := Find(images, "current")
	h := cur.Hardware()
	if h.Accel != "kvm" || h.Type != "q35" || h.CPU != "Penryn,+ssse3,+sse4.1,+sse4.2" ||
		h.MemoryMB != 4096 || h.SMP != 2 || h.NIC != "e1000-82545em" {
		t.Fatalf("current: %+v", h)
	}
	leg, _ := Find(images, "legacy")
	h = leg.Hardware()
	// No nic line: built before a9f8c61, when usb-net was the only NIC.
	if h.Accel != "tcg" || h.CPU != "Nehalem" || h.MemoryMB != 2048 || h.SMP != 1 || h.NIC != "usb-net" {
		t.Fatalf("legacy: %+v", h)
	}
}

func TestSSHFacts(t *testing.T) {
	cur, _ := Find(images, "current")
	leg, _ := Find(images, "legacy")
	if cur.LegacySSH() || !leg.LegacySSH() {
		t.Fatal("openssh line present → modern; absent → Apple's 6.2")
	}
	if cur.SSHKeyFingerprint() != "SHA256:20V3dlDtWnv2FKbn3sB6ljy2Zb24Ka0RWHf4tjQbPqs" {
		t.Fatalf("fingerprint %q", cur.SSHKeyFingerprint())
	}
	if cur.Image() != filepath.Join(images, "current.qcow2") {
		t.Fatalf("image %q", cur.Image())
	}
}

func TestFindNamesWhatIsAvailable(t *testing.T) {
	_, err := Find(images, "nonesuch")
	if err == nil || !contains(err.Error(), "current") || !contains(err.Error(), "legacy") {
		t.Fatalf("err = %v", err)
	}
}
```

(`names` and `contains` are two-line helpers at the bottom of the test
file.)

Run: `go test ./internal/config/ ./internal/manifest/` → FAIL (undefined).

- [ ] **Step 3: Implement `internal/config/config.go`**

```go
// Package config holds every default vmavs has, and the layout of
// VMAVS_HOME. No other package decides a default or builds a path under
// VMAVS_HOME itself.
package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Machine defaults, MEASURED: each is the value image/build-image.sh used
// for the installs recorded in NOTES.md.
const (
	DefaultAccel = "kvm"
	DefaultType  = "q35"
	// DefaultCPU is the only -cpu line with completed installs behind it
	// (docs/decisions/0009).
	DefaultCPU = "Penryn,+ssse3,+sse4.1,+sse4.2"
	// DefaultSMBIOS is baked into OpenCore's config.plist, not passed to
	// QEMU (docs/decisions/0010).
	DefaultSMBIOS   = "iMac14,2"
	DefaultMemoryMB = 4096
	DefaultSMP      = 2
	DefaultDiskGB   = 60
	DefaultNIC      = "e1000-82545em"
	// LegacyNIC is what every image built before commit a9f8c61
	// (2026-09-21) was installed with. Their manifests have no nic line.
	LegacyNIC      = "usb-net"
	DefaultSSHPort = 2222
	DefaultSSHUser = "mavsuser"
	DefaultQEMU    = "qemu-system-x86_64"
	DefaultDisplay = "none"
)

// NICChoices are the network devices a guest has been installed with
// (docs/open-questions.md Q2).
var NICChoices = []string{"usb-net", "e1000-82545em", "virtio-net-pci"}

// Paths is the layout of VMAVS_HOME (spec §5).
type Paths struct{ Home string }

func (p Paths) Images() string           { return filepath.Join(p.Home, "images") }
func (p Paths) Build() string            { return filepath.Join(p.Home, "build") }
func (p Paths) Firmware() string         { return filepath.Join(p.Build(), "firmware") }
func (p Paths) OVMFCode() string         { return filepath.Join(p.Firmware(), "OVMF_CODE.fd") }
func (p Paths) OVMFVarsTemplate() string { return filepath.Join(p.Firmware(), "OVMF_VARS.fd") }
func (p Paths) Work() string             { return filepath.Join(p.Home, "work") }
func (p Paths) Run() string              { return filepath.Join(p.Home, "run") }
func (p Paths) Keys() string             { return filepath.Join(p.Home, "keys") }
func (p Paths) Cache() string            { return filepath.Join(p.Home, "cache") }

// OpenCoreImage is build/opencore.img. Until the shell tree is retired
// (spec §5, phase 6), an image it built keeps OpenCore at
// work/opencore-p3.img, and that path is used when the new one is absent.
func (p Paths) OpenCoreImage() string {
	cur := filepath.Join(p.Build(), "opencore.img")
	if exists(cur) {
		return cur
	}
	if legacy := filepath.Join(p.Work(), "opencore-p3.img"); exists(legacy) {
		return legacy
	}
	return cur
}

// Home is VMAVS_HOME, else ~/.local/share/vmavs.
func Home(getenv func(string) string) (string, error) {
	if h := getenv("VMAVS_HOME"); h != "" {
		return h, nil
	}
	u := getenv("HOME")
	if u == "" {
		return "", errors.New("neither VMAVS_HOME nor HOME is set")
	}
	return filepath.Join(u, ".local", "share", "vmavs"), nil
}

// LegacyHint explains, when the default home does not exist and the shell
// tree's does, how to point vmavs at it. It is "" otherwise. vmavs never
// moves anything itself.
func LegacyHint(getenv func(string) string, exists func(string) bool) string {
	if getenv("VMAVS_HOME") != "" || getenv("HOME") == "" {
		return ""
	}
	u := getenv("HOME")
	old := filepath.Join(u, ".local", "share", "mavericks-qemu-guest")
	cur := filepath.Join(u, ".local", "share", "vmavs")
	if !exists(old) || exists(cur) {
		return ""
	}
	return fmt.Sprintf("built state is in the shell tree's location, %s:\n"+
		"  while the shell tree is still in use:  export VMAVS_HOME=%s\n"+
		"  once it is retired:                    mv %s %s", old, old, old, cur)
}

// QEMU is the QEMU binary: VMAVS_QEMU, else qemu-system-x86_64.
func QEMU(getenv func(string) string) string {
	if q := getenv("VMAVS_QEMU"); q != "" {
		return q
	}
	return DefaultQEMU
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// Exists reports whether p exists. It is the default for LegacyHint.
func Exists(p string) bool { return exists(p) }
```

- [ ] **Step 4: Implement `internal/config/machine.go`**

```go
package config

import (
	"flag"
	"fmt"
	"slices"
	"strings"
)

// Machine is the guest hardware, and the forwarded SSH port. The same
// values drive install, verify, run and emit.
type Machine struct {
	Accel    string
	Type     string // QEMU machine type; ",vmport=off" is added by machine.Spec
	CPU      string
	MemoryMB int
	SMP      int
	NIC      string
	SSHPort  int
	Display  string
}

func DefaultMachine() Machine {
	return Machine{
		Accel: DefaultAccel, Type: DefaultType, CPU: DefaultCPU,
		MemoryMB: DefaultMemoryMB, SMP: DefaultSMP, NIC: DefaultNIC,
		SSHPort: DefaultSSHPort, Display: DefaultDisplay,
	}
}

// Register adds the machine flags every machine-using subcommand shares.
func (m *Machine) Register(fs *flag.FlagSet) {
	fs.StringVar(&m.Accel, "accel", m.Accel, "accelerator: kvm, hvf, nvmm or tcg")
	fs.StringVar(&m.CPU, "cpu", m.CPU, "QEMU -cpu line (docs/decisions/0009)")
	fs.IntVar(&m.MemoryMB, "memory", m.MemoryMB, "guest memory in MiB")
	fs.IntVar(&m.SMP, "smp", m.SMP, "guest CPUs")
	fs.StringVar(&m.NIC, "nic", m.NIC, "network device: "+strings.Join(NICChoices, ", "))
	fs.IntVar(&m.SSHPort, "ssh-port", m.SSHPort, "host port forwarded to the guest's port 22")
	fs.StringVar(&m.Display, "display", m.Display, "QEMU -display: none, gtk, sdl or cocoa")
}

// Override copies the fields whose flags were set on the command line.
// An image's manifest says what it was installed with; a flag given
// explicitly still wins.
func (m *Machine) Override(from Machine, set func(name string) bool) {
	if set("accel") {
		m.Accel = from.Accel
	}
	if set("cpu") {
		m.CPU = from.CPU
	}
	if set("memory") {
		m.MemoryMB = from.MemoryMB
	}
	if set("smp") {
		m.SMP = from.SMP
	}
	if set("nic") {
		m.NIC = from.NIC
	}
	if set("ssh-port") {
		m.SSHPort = from.SSHPort
	}
	if set("display") {
		m.Display = from.Display
	}
}

func (m Machine) Validate() error {
	if !slices.Contains(NICChoices, m.NIC) {
		return fmt.Errorf("no such NIC %q (choices: %s)", m.NIC, strings.Join(NICChoices, ", "))
	}
	if m.MemoryMB <= 0 || m.SMP <= 0 {
		return fmt.Errorf("memory and smp must be positive (got %d MiB, %d)", m.MemoryMB, m.SMP)
	}
	if m.SSHPort <= 0 || m.SSHPort > 65535 {
		return fmt.Errorf("no such port %d", m.SSHPort)
	}
	return nil
}
```

- [ ] **Step 5: Implement `internal/manifest/manifest.go`**

```go
// Package manifest reads what image/build-image.sh (and, from phase 5,
// vmavs image) writes beside every built image: one "key<TAB>value" per
// line, with # comments.
package manifest

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

type Manifest struct {
	Name    string
	Path    string
	ModTime time.Time
	fields  map[string]string
}

func Load(path string) (Manifest, error) {
	f, err := os.Open(path)
	if err != nil {
		return Manifest{}, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return Manifest{}, err
	}
	m := Manifest{Path: path, ModTime: st.ModTime(), fields: map[string]string{}}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "\t")
		if !ok {
			return Manifest{}, fmt.Errorf("%s: not key<TAB>value: %q", path, line)
		}
		m.fields[k] = v
	}
	if err := sc.Err(); err != nil {
		return Manifest{}, err
	}
	m.Name = m.fields["name"]
	if m.Name == "" {
		m.Name = strings.TrimSuffix(filepath.Base(path), ".manifest")
	}
	return m, nil
}

func (m Manifest) Get(key string) string { return m.fields[key] }

// Image is the qcow2 this manifest describes.
func (m Manifest) Image() string { return strings.TrimSuffix(m.Path, ".manifest") + ".qcow2" }

// Hardware is the machine the image was installed and verified on. Fields
// the manifest does not record keep their defaults, except the NIC: an
// image with no nic line predates the choice and was installed with
// usb-net.
func (m Manifest) Hardware() config.Machine {
	h := config.DefaultMachine()
	if nic, ok := m.fields["nic"]; ok {
		h.NIC = nic
	} else {
		h.NIC = config.LegacyNIC
	}
	parts := strings.Fields(m.fields["accel"])
	if len(parts) > 0 {
		h.Accel = parts[0]
		for _, kv := range parts[1:] {
			k, v, _ := strings.Cut(kv, "=")
			switch k {
			case "machine":
				h.Type = v
			case "cpu":
				h.CPU = v
			case "ram":
				if n, err := strconv.Atoi(v); err == nil {
					h.MemoryMB = n
				}
			case "smp":
				if n, err := strconv.Atoi(v); err == nil {
					h.SMP = n
				}
			}
		}
	}
	return h
}

// LegacySSH reports whether the guest runs Apple's OpenSSH 6.2: an image
// built with --no-openssh, or before the openssh line existed (3bde057).
func (m Manifest) LegacySSH() bool {
	v, ok := m.fields["openssh"]
	return !ok || v == "none"
}

// SSHKeyFingerprint is the SHA256 fingerprint of the key the image
// authorized, or "".
func (m Manifest) SSHKeyFingerprint() string {
	if f := strings.Fields(m.fields["sshkey"]); len(f) > 0 {
		return f[0]
	}
	return ""
}

// List is every manifest in dir that has its image beside it, newest
// first.
func List(dir string) ([]Manifest, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "*.manifest"))
	if err != nil {
		return nil, err
	}
	var out []Manifest
	for _, p := range paths {
		m, err := Load(p)
		if err != nil {
			return nil, err
		}
		if _, err := os.Stat(m.Image()); err == nil {
			out = append(out, m)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	return out, nil
}

// Find is the manifest for the image named name.
func Find(dir, name string) (Manifest, error) {
	all, err := List(dir)
	if err != nil {
		return Manifest{}, err
	}
	var names []string
	for _, m := range all {
		if m.Name == name {
			return m, nil
		}
		names = append(names, m.Name)
	}
	return Manifest{}, fmt.Errorf("no built image %q in %s (there: %s)", name, dir, strings.Join(names, ", "))
}
```

- [ ] **Step 6: Run the tests, vet, staticcheck; commit**

Run: `go test ./internal/config/ ./internal/manifest/ && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` → PASS, clean.

```bash
git add internal/config internal/manifest
git commit   # subject: "vmavs (Go): config and manifests -- one place for defaults and paths"
```

---

### Task 3: `proc` and `machine`: running things, and the one machine

**Files:**
- Create: `internal/proc/proc.go`, `internal/proc/proc_test.go`, `internal/machine/machine.go`, `internal/machine/machine_test.go`
- Modify: `internal/cli/cli.go` (add `Env.Runner` and `runner(e)`)

**Interfaces:**
- Consumes: `config.Machine`.
- Produces:
  - `proc.Cmd{Name string; Args []string; Dir string; Stdin io.Reader; Stdout, Stderr io.Writer}` and `(Cmd).String()`
  - `proc.Runner` interface: `Run(ctx, Cmd) error`, `LookPath(string) (string, error)`
  - `proc.Exec{GracePeriod time.Duration}`
  - `proc.ExitError{Cmd string; Code int}`
  - `proc.Fake{Calls []Cmd; Handle func(Cmd) error; Paths map[string]string}`
  - `machine.Firmware{OVMFCode, OpenCore string}`
  - `machine.Spec{QEMU string; config.Machine; OVMFCode, NVRAM, OpenCore, Disk, Installer, Monitor string}`
  - `machine.ForInstall(m, fw, nvram, disk, installer, monitor) Spec`
  - `machine.ForVerify(m, fw, nvram, disk, monitor) Spec`
  - `machine.ForRun(m, fw, nvram, overlay, monitor) Spec`
  - `(Spec).Args() []string`, `(Spec).Command() proc.Cmd`
  - `machine.NICDevice(nic string) string`
  - `cli.runner(e *Env) proc.Runner`

- [ ] **Step 1: Write the failing `proc` tests**

`internal/proc/proc_test.go`:

```go
package proc

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestExecReportsTheExitStatus(t *testing.T) {
	err := Exec{}.Run(context.Background(), Cmd{Name: "sh", Args: []string{"-c", "exit 3"}})
	var xe *ExitError
	if !errors.As(err, &xe) || xe.Code != 3 || !strings.Contains(xe.Error(), "sh -c 'exit 3'") {
		t.Fatalf("err = %v", err)
	}
}

func TestCancellingTheContextStopsTheChildPolitely(t *testing.T) {
	// SIGTERM, not SIGKILL: QEMU flushes its disks on SIGTERM.
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := Exec{GracePeriod: 2 * time.Second}.Run(ctx, Cmd{Name: "sleep", Args: []string{"30"}})
	if err == nil || time.Since(start) > 5*time.Second {
		t.Fatalf("err=%v after %v", err, time.Since(start))
	}
}

func TestFakeRecordsAndAnswers(t *testing.T) {
	f := &Fake{Paths: map[string]string{"qemu-img": "/usr/bin/qemu-img"}}
	_ = f.Run(context.Background(), Cmd{Name: "qemu-img", Args: []string{"create"}})
	if len(f.Calls) != 1 || f.Calls[0].String() != "qemu-img create" {
		t.Fatalf("calls %v", f.Calls)
	}
	if _, err := f.LookPath("packer"); !errors.Is(err, exec.ErrNotFound) {
		t.Fatalf("missing tool: err = %v", err)
	}
}

func TestCmdStringQuotesWhatNeedsQuoting(t *testing.T) {
	c := Cmd{Name: "qemu", Args: []string{"-drive", "file=/a b/c", "-m", "4096"}}
	if got := c.String(); got != "qemu -drive 'file=/a b/c' -m 4096" {
		t.Fatalf("got %q", got)
	}
}
```

Run: `go test ./internal/proc/` → FAIL.

- [ ] **Step 2: Implement `internal/proc/proc.go`**

```go
// Package proc is the one way vmavs runs another program, so that every
// command can be tested with a fake that records what would have run.
package proc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type Cmd struct {
	Name   string
	Args   []string
	Dir    string
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

// String is the command as a shell would need it typed, for logs and
// error messages.
func (c Cmd) String() string {
	parts := []string{quote(c.Name)}
	for _, a := range c.Args {
		parts = append(parts, quote(a))
	}
	return strings.Join(parts, " ")
}

func quote(s string) string {
	if s != "" && !strings.ContainsAny(s, " \t\n'\"\\$`*?[]{}()<>|&;#~") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

type Runner interface {
	Run(ctx context.Context, c Cmd) error
	LookPath(name string) (string, error)
}

// ExitError is a program that ran and failed.
type ExitError struct {
	Cmd  string
	Code int
}

func (e *ExitError) Error() string { return fmt.Sprintf("%s: exit status %d", e.Cmd, e.Code) }

// Exec runs real programs. Cancelling the context sends SIGTERM, and
// SIGKILL only if the program is still running GracePeriod later (default
// 10s): QEMU flushes its disks on SIGTERM.
type Exec struct{ GracePeriod time.Duration }

func (x Exec) Run(ctx context.Context, c Cmd) error {
	cmd := exec.CommandContext(ctx, c.Name, c.Args...)
	cmd.Dir, cmd.Stdin, cmd.Stdout, cmd.Stderr = c.Dir, c.Stdin, c.Stdout, c.Stderr
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = x.GracePeriod
	if cmd.WaitDelay == 0 {
		cmd.WaitDelay = 10 * time.Second
	}
	err := cmd.Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) && ctx.Err() == nil {
		return &ExitError{Cmd: c.String(), Code: ee.ExitCode()}
	}
	if err != nil {
		return fmt.Errorf("%s: %w", c.String(), err)
	}
	return nil
}

func (Exec) LookPath(name string) (string, error) { return exec.LookPath(name) }

// Fake records every command instead of running it. Handle, if set,
// decides each command's result; Paths answers LookPath.
type Fake struct {
	Calls  []Cmd
	Handle func(Cmd) error
	Paths  map[string]string
}

func (f *Fake) Run(_ context.Context, c Cmd) error {
	f.Calls = append(f.Calls, c)
	if f.Handle != nil {
		return f.Handle(c)
	}
	return nil
}

func (f *Fake) LookPath(name string) (string, error) {
	if p, ok := f.Paths[name]; ok {
		return p, nil
	}
	return "", fmt.Errorf("%s: %w", name, exec.ErrNotFound)
}
```

Run: `go test ./internal/proc/` → PASS.

- [ ] **Step 3: Write the failing `machine` test**

The expected argument list is `qemu_args with-media` from
`image/build-image.sh:406-452`, transcribed argument by argument. It is
the parity check against the shell reference.

`internal/machine/machine_test.go`:

```go
package machine

import (
	"slices"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
)

var fw = Firmware{OVMFCode: "/fw/OVMF_CODE.fd", OpenCore: "/oc.img"}

func TestInstallMatchesTheShellPipelineArgumentForArgument(t *testing.T) {
	s := ForInstall(config.DefaultMachine(), fw, "/w/VARS.fd", "/i/x.qcow2", "/m/installer.img", "/w/monitor.sock")
	want := []string{
		"-accel", "kvm",
		"-machine", "q35,vmport=off",
		"-cpu", "Penryn,+ssse3,+sse4.1,+sse4.2",
		"-m", "4096",
		"-smp", "2",
		"-drive", "if=pflash,format=raw,unit=0,readonly=on,file=/fw/OVMF_CODE.fd",
		"-drive", "if=pflash,format=raw,unit=1,file=/w/VARS.fd",
		"-device", "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on",
		"-device", "ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on",
		"-device", "ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1",
		"-device", "ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2",
		"-drive", "id=opencore,if=none,format=raw,snapshot=on,file=/oc.img",
		"-device", "usb-storage,bus=usb.0,drive=opencore",
		"-drive", "id=target,if=none,format=qcow2,file=/i/x.qcow2",
		"-device", "ide-hd,bus=ide.0,drive=target",
		"-netdev", "user,id=net0,hostfwd=tcp::2222-:22",
		"-device", "e1000-82545em,netdev=net0",
		"-device", "usb-kbd,bus=usb.0",
		"-device", "usb-mouse,bus=usb.0",
		"-device", "VGA,vgamem_mb=64",
		"-display", "none",
		"-monitor", "unix:/w/monitor.sock,server,nowait",
		"-drive", "id=installer,if=none,format=raw,snapshot=on,file=/m/installer.img",
		"-device", "ide-hd,bus=ide.1,drive=installer",
	}
	if got := s.Args(); !slices.Equal(got, want) {
		t.Fatalf("args differ from build-image.sh qemu_args:\n got %q\nwant %q", got, want)
	}
}

func TestRunAndVerifyHaveNoInstaller(t *testing.T) {
	for _, s := range []Spec{
		ForRun(config.DefaultMachine(), fw, "/r/VARS.fd", "/r/disk.qcow2", "/r/monitor.sock"),
		ForVerify(config.DefaultMachine(), fw, "/w/VARS.fd", "/i/x.qcow2", "/w/monitor.sock"),
	} {
		if slices.Contains(s.Args(), "ide-hd,bus=ide.1,drive=installer") {
			t.Fatalf("%v attaches installer media", s.Args())
		}
	}
}

func TestUSBNetHangsOffTheEHCIController(t *testing.T) {
	if NICDevice("usb-net") != "usb-net,bus=usb.0,netdev=net0" || NICDevice("virtio-net-pci") != "virtio-net-pci,netdev=net0" {
		t.Fatal("NIC device lines differ from build-image.sh nic_device()")
	}
}

func TestNoMonitorAndAChosenDisplay(t *testing.T) {
	m := config.DefaultMachine()
	m.Display = "gtk"
	args := ForRun(m, fw, "/r/V", "/r/d", "").Args()
	if slices.Contains(args, "-monitor") || !slices.Contains(args, "gtk") {
		t.Fatalf("%q", args)
	}
}
```

Run: `go test ./internal/machine/` → FAIL.

- [ ] **Step 4: Implement `internal/machine/machine.go`**

```go
// Package machine is the one definition of the guest's hardware. The
// install and verify stages, `vmavs run` and `vmavs emit packer` all
// derive from Spec, so they cannot drift apart. They drifted three ways
// in the shell tree: image/build-image.sh, image/compare-images.sh and
// vm/profiles/*.args.
package machine

import (
	"fmt"
	"strconv"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

type Firmware struct {
	OVMFCode string
	OpenCore string
}

type Spec struct {
	QEMU string
	config.Machine
	OVMFCode  string
	NVRAM     string // this VM's own copy of the OVMF variable store
	OpenCore  string
	Disk      string
	Installer string // attached only while installing
	Monitor   string // unix socket path, or "" for none
}

func ForInstall(m config.Machine, fw Firmware, nvram, disk, installer, monitor string) Spec {
	s := ForVerify(m, fw, nvram, disk, monitor)
	s.Installer = installer
	return s
}

// ForVerify boots the built image without its installer: an image that
// only boots with the installer beside it is not the deliverable.
func ForVerify(m config.Machine, fw Firmware, nvram, disk, monitor string) Spec {
	return Spec{
		QEMU: config.DefaultQEMU, Machine: m,
		OVMFCode: fw.OVMFCode, NVRAM: nvram, OpenCore: fw.OpenCore,
		Disk: disk, Monitor: monitor,
	}
}

// ForRun boots a throwaway overlay backed by the built image, so the image
// itself is never written.
func ForRun(m config.Machine, fw Firmware, nvram, overlay, monitor string) Spec {
	return ForVerify(m, fw, nvram, overlay, monitor)
}

// NICDevice is the -device line for a NIC. usb-net is a USB device and
// hangs off the EHCI controller; the others are PCI, and QEMU places them.
func NICDevice(nic string) string {
	if nic == "usb-net" {
		return "usb-net,bus=usb.0,netdev=net0"
	}
	return nic + ",netdev=net0"
}

// Args is the QEMU command line, in the order image/build-image.sh's
// qemu_args() produced it.
func (s Spec) Args() []string {
	display := s.Display
	if display == "" {
		display = config.DefaultDisplay
	}
	a := []string{
		"-accel", s.Accel,
		"-machine", s.Type + ",vmport=off",
		"-cpu", s.CPU,
		"-m", strconv.Itoa(s.MemoryMB),
		"-smp", strconv.Itoa(s.SMP),
		"-drive", "if=pflash,format=raw,unit=0,readonly=on,file=" + s.OVMFCode,
		"-drive", "if=pflash,format=raw,unit=1,file=" + s.NVRAM,
		"-device", "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on",
		"-device", "ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on",
		"-device", "ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1",
		"-device", "ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2",
		// snapshot=on: the guest writes to the OpenCore image, and the file
		// must not change when it does. Without it every boot rewrote the
		// bootloader image, and the manifest's opencore checksum stopped
		// meaning anything (found by image/compare-images.sh; NOTES.md).
		"-drive", "id=opencore,if=none,format=raw,snapshot=on,file=" + s.OpenCore,
		"-device", "usb-storage,bus=usb.0,drive=opencore",
		"-drive", "id=target,if=none,format=qcow2,file=" + s.Disk,
		"-device", "ide-hd,bus=ide.0,drive=target",
		"-netdev", fmt.Sprintf("user,id=net0,hostfwd=tcp::%d-:22", s.SSHPort),
		"-device", NICDevice(s.NIC),
		"-device", "usb-kbd,bus=usb.0",
		"-device", "usb-mouse,bus=usb.0",
		"-device", "VGA,vgamem_mb=64",
		"-display", display,
	}
	if s.Monitor != "" {
		a = append(a, "-monitor", "unix:"+s.Monitor+",server,nowait")
	}
	if s.Installer != "" {
		// snapshot=on for the same reason: mds writes a .Spotlight-V100
		// store onto the installer media, with a fresh UUID each time.
		a = append(a,
			"-drive", "id=installer,if=none,format=raw,snapshot=on,file="+s.Installer,
			"-device", "ide-hd,bus=ide.1,drive=installer")
	}
	return a
}

func (s Spec) Command() proc.Cmd {
	q := s.QEMU
	if q == "" {
		q = config.DefaultQEMU
	}
	return proc.Cmd{Name: q, Args: s.Args()}
}
```

- [ ] **Step 5: Give `Env` a Runner**

In `internal/cli/cli.go`, import `proc` and add this field to `Env`:

```go
	// Runner runs external commands. A nil Runner means the real one.
	Runner proc.Runner
```

and add this helper:

```go
// runner is e.Runner, or the real one.
func runner(e *Env) proc.Runner {
	if e.Runner != nil {
		return e.Runner
	}
	return proc.Exec{}
}
```

- [ ] **Step 6: Run everything; commit**

Run: `go test ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` → PASS, clean.

```bash
git add internal/proc internal/machine internal/cli/cli.go
git commit   # subject: "vmavs (Go): proc.Runner, and the one machine definition"
```

---

### Task 4: `guest`: the SSH client, and choosing the key an image authorized

**Files:**
- Create: `internal/guest/ssh.go`, `internal/guest/keys.go`, `internal/guest/guest_test.go`, `internal/guest/guesttest/server.go`
- Modify: `go.mod`, `go.sum` (`go get golang.org/x/crypto@v0.57.0 golang.org/x/term@v0.46.0`)

**Interfaces:**
- Produces:
  - `guest.Target{Addr, User string; Signer ssh.Signer; Legacy bool; Timeout time.Duration}`
  - `(Target).ClientConfig() *ssh.ClientConfig`
  - `guest.Dial(ctx, Target) (*ssh.Client, error)`
  - `guest.Exec(c *ssh.Client, command string, stdin io.Reader, stdout, stderr io.Writer) (int, error)`
  - `guest.Shell(c *ssh.Client, in *os.File, out, errOut io.Writer) (int, error)`
  - `guest.KeyCandidates(getenv func(string) string, keysDir string) []string`, a list of private-key paths
  - `guest.ChooseKey(candidates []string, fingerprint string) (path string, s ssh.Signer, err error)`
  - `guest.LoadSigner(path) (ssh.Signer, error)`
  - `guesttest.Options{AuthorizedKey ssh.PublicKey; Legacy bool}`
  - `guesttest.Start(t testing.TB, o Options) (addr string)`: exec requests reply `ran: <cmd>\n`, and exit status 3 when the command is `fail`

- [ ] **Step 1: Add dependencies and write the test server**

```bash
go get golang.org/x/crypto@v0.57.0 golang.org/x/term@v0.46.0
```

`internal/guest/guesttest/server.go`:

```go
// Package guesttest is an in-process SSH server that stands in for a
// guest in tests.
package guesttest

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"fmt"
	"net"
	"testing"

	"golang.org/x/crypto/ssh"
)

type Options struct {
	AuthorizedKey ssh.PublicKey
	// Legacy makes the server offer what Apple's OpenSSH 6.2 offers: an
	// ssh-rsa host key, diffie-hellman-group14-sha1 key exchange, and only
	// SHA-1 ("ssh-rsa") signatures from an RSA user key.
	Legacy bool
}

// Start serves until the test ends. It returns host:port.
func Start(t testing.TB, o Options) string {
	t.Helper()
	hostKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	host, err := ssh.NewSignerFromKey(hostKey)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(_ ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			if bytes.Equal(k.Marshal(), o.AuthorizedKey.Marshal()) {
				return nil, nil
			}
			return nil, errors.New("key not authorized")
		},
	}
	if o.Legacy {
		host, err = ssh.NewSignerWithAlgorithms(host.(ssh.AlgorithmSigner), []string{ssh.KeyAlgoRSA})
		if err != nil {
			t.Fatal(err)
		}
		cfg.KeyExchanges = []string{"diffie-hellman-group14-sha1"}
		cfg.PublicKeyAuthAlgorithms = []string{ssh.KeyAlgoRSA}
	}
	cfg.AddHostKey(host)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go serve(c, cfg)
		}
	}()
	return ln.Addr().String()
}

func serve(c net.Conn, cfg *ssh.ServerConfig) {
	defer c.Close()
	_, chans, reqs, err := ssh.NewServerConn(c, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			nc.Reject(ssh.UnknownChannelType, "session only")
			continue
		}
		ch, in, err := nc.Accept()
		if err != nil {
			continue
		}
		go func() {
			defer ch.Close()
			for req := range in {
				if req.Type != "exec" {
					req.Reply(false, nil)
					continue
				}
				var p struct{ Command string }
				ssh.Unmarshal(req.Payload, &p)
				req.Reply(true, nil)
				fmt.Fprintf(ch, "ran: %s\n", p.Command)
				code := uint32(0)
				if p.Command == "fail" {
					code = 3
				}
				ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{code}))
				return
			}
		}()
	}
}
```

- [ ] **Step 2: Write the failing tests**

`internal/guest/guest_test.go`:

```go
package guest

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/pem"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// writeKey writes a private key and its .pub beside it; returns the path.
func writeKey(t *testing.T, dir, name string, priv any) string {
	t.Helper()
	block, err := ssh.MarshalPrivateKey(priv, name)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	os.WriteFile(p, pem.EncodeToMemory(block), 0o600)
	s, _ := ssh.NewSignerFromKey(priv)
	os.WriteFile(p+".pub", ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	return p
}

func TestExecRunsTheCommandAndReturnsItsStatus(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	c, err := Dial(context.Background(), Target{Addr: addr, User: "mavsuser", Signer: s, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var out bytes.Buffer
	code, err := Exec(c, "sw_vers", nil, &out, &out)
	if err != nil || code != 0 || out.String() != "ran: sw_vers\n" {
		t.Fatalf("code=%d err=%v out=%q", code, err, out.String())
	}
	code, err = Exec(c, "fail", nil, &out, &out)
	if err != nil || code != 3 {
		t.Fatalf("fail: code=%d err=%v", code, err)
	}
}

func TestLegacyReachesAnOpenSSH62ShapedServerWithAnRSAKey(t *testing.T) {
	// REASONED stand-in for Apple's OpenSSH 6.2; Task 9 measures the real one.
	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	s, _ := ssh.NewSignerFromKey(rk)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey(), Legacy: true})
	c, err := Dial(context.Background(), Target{Addr: addr, User: "mavsuser", Signer: s, Legacy: true, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
}

func TestLegacyConfigOffersWhatOpenSSH62Needs(t *testing.T) {
	cfg := Target{Legacy: true, Signer: mustEd(t)}.ClientConfig()
	if !slices.Contains(cfg.HostKeyAlgorithms, "ssh-rsa") || !slices.Contains(cfg.KeyExchanges, "diffie-hellman-group14-sha1") {
		t.Fatalf("host keys %v, kex %v", cfg.HostKeyAlgorithms, cfg.KeyExchanges)
	}
	modern := Target{Signer: mustEd(t)}.ClientConfig()
	if modern.HostKeyAlgorithms != nil || modern.KeyExchanges != nil {
		t.Fatal("a modern guest gets x/crypto's defaults, untouched")
	}
}

func TestChooseKeyPicksTheOneTheImageAuthorized(t *testing.T) {
	dir := t.TempDir()
	_, a, _ := ed25519.GenerateKey(rand.Reader)
	_, b, _ := ed25519.GenerateKey(rand.Reader)
	pa := writeKey(t, dir, "id_a", a)
	pb := writeKey(t, dir, "id_b", b)
	sb, _ := ssh.NewSignerFromKey(b)
	want := ssh.FingerprintSHA256(sb.PublicKey())
	path, _, err := ChooseKey([]string{pa, pb}, want)
	if err != nil || path != pb {
		t.Fatalf("path=%q err=%v", path, err)
	}
	_, _, err = ChooseKey([]string{pa}, want)
	if err == nil || !strings.Contains(err.Error(), want) || !strings.Contains(err.Error(), "VMAVS_SSH_KEY") {
		t.Fatalf("err = %v", err)
	}
}

func TestKeyCandidatesOrder(t *testing.T) {
	home := t.TempDir()
	keys := filepath.Join(t.TempDir(), "keys")
	os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	os.MkdirAll(keys, 0o700)
	_, k, _ := ed25519.GenerateKey(rand.Reader)
	user := writeKey(t, filepath.Join(home, ".ssh"), "id_ed25519", k)
	built := writeKey(t, keys, "mqg_rsa", k)
	getenv := func(n string) string { return map[string]string{"HOME": home, "VMAVS_SSH_KEY": "/explicit"}[n] }
	got := KeyCandidates(getenv, keys)
	if !slices.Equal(got, []string{"/explicit", user, built}) {
		t.Fatalf("got %v", got)
	}
}

func mustEd(t *testing.T) ssh.Signer {
	_, k, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(k)
	return s
}
```

Run: `go test ./internal/guest/...` → FAIL.

- [ ] **Step 3: Implement `internal/guest/ssh.go`**

```go
// Package guest talks to a running guest over SSH, with Go's own client:
// no ssh binary and no known_hosts.
package guest

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/term"
)

type Target struct {
	Addr   string
	User   string
	Signer ssh.Signer
	// Legacy is a guest running Apple's OpenSSH 6.2 (manifest.LegacySSH).
	Legacy  bool
	Timeout time.Duration
}

// ClientConfig trusts any host key: every overlay has fresh host keys, so
// a pinned one would be wrong by construction. What authenticates is the
// user key the image authorized.
func (t Target) ClientConfig() *ssh.ClientConfig {
	signer := t.Signer
	cfg := &ssh.ClientConfig{
		User:            t.User,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         t.Timeout,
	}
	if t.Legacy {
		// OpenSSH 6.2 offers only ssh-rsa/ssh-dss host keys and SHA-1
		// key exchanges, and predates rsa-sha2 signatures (RFC 8332).
		// The shell equivalent is ssh_opts() in image/build-image.sh.
		sup, ins := ssh.SupportedAlgorithms(), ssh.InsecureAlgorithms()
		cfg.HostKeyAlgorithms = append(append([]string{}, sup.HostKeys...), ins.HostKeys...)
		cfg.KeyExchanges = append(append([]string{}, sup.KeyExchanges...), ins.KeyExchanges...)
		if as, ok := signer.(ssh.AlgorithmSigner); ok && signer.PublicKey().Type() == ssh.KeyAlgoRSA {
			if s, err := ssh.NewSignerWithAlgorithms(as, []string{ssh.KeyAlgoRSA}); err == nil {
				signer = s
			}
		}
	}
	cfg.Auth = []ssh.AuthMethod{ssh.PublicKeys(signer)}
	return cfg
}

func Dial(ctx context.Context, t Target) (*ssh.Client, error) {
	d := net.Dialer{Timeout: t.Timeout}
	conn, err := d.DialContext(ctx, "tcp", t.Addr)
	if err != nil {
		return nil, err
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, t.Addr, t.ClientConfig())
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("ssh %s@%s: %w", t.User, t.Addr, err)
	}
	return ssh.NewClient(c, chans, reqs), nil
}

// Exec runs one command and returns its exit status.
func Exec(c *ssh.Client, command string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	s, err := c.NewSession()
	if err != nil {
		return 0, err
	}
	defer s.Close()
	s.Stdin, s.Stdout, s.Stderr = stdin, stdout, stderr
	return status(s.Run(command))
}

// Shell is an interactive login shell on a terminal.
func Shell(c *ssh.Client, in *os.File, out, errOut io.Writer) (int, error) {
	s, err := c.NewSession()
	if err != nil {
		return 0, err
	}
	defer s.Close()
	s.Stdin, s.Stdout, s.Stderr = in, out, errOut
	fd := int(in.Fd())
	if term.IsTerminal(fd) {
		old, err := term.MakeRaw(fd)
		if err != nil {
			return 0, err
		}
		defer term.Restore(fd, old)
		w, h, err := term.GetSize(fd)
		if err != nil {
			w, h = 80, 24
		}
		termName := os.Getenv("TERM")
		if termName == "" {
			termName = "xterm"
		}
		if err := s.RequestPty(termName, h, w, ssh.TerminalModes{ssh.ECHO: 1}); err != nil {
			return 0, err
		}
	}
	if err := s.Shell(); err != nil {
		return 0, err
	}
	return status(s.Wait())
}

func status(err error) (int, error) {
	var xe *ssh.ExitError
	if errors.As(err, &xe) {
		return xe.ExitStatus(), nil
	}
	if err != nil {
		return 0, err
	}
	return 0, nil
}
```

- [ ] **Step 4: Implement `internal/guest/keys.go`**

```go
package guest

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

// KeyCandidates lists private keys in the order the shell tree searched
// for the key to authorize (lib/sshkey.sh): VMAVS_SSH_KEY, then
// ~/.ssh/id_*, then VMAVS_HOME/keys/*. Only keys with a .pub beside them
// count, except VMAVS_SSH_KEY, which is taken as given.
func KeyCandidates(getenv func(string) string, keysDir string) []string {
	var out []string
	if k := getenv("VMAVS_SSH_KEY"); k != "" {
		out = append(out, k)
	}
	for _, pattern := range []string{
		filepath.Join(getenv("HOME"), ".ssh", "id_*.pub"),
		filepath.Join(keysDir, "*.pub"),
	} {
		pubs, _ := filepath.Glob(pattern)
		for _, pub := range pubs {
			priv := strings.TrimSuffix(pub, ".pub")
			if _, err := os.Stat(priv); err == nil {
				out = append(out, priv)
			}
		}
	}
	return out
}

func LoadSigner(path string) (ssh.Signer, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s, err := ssh.ParsePrivateKey(b)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return s, nil
}

// ChooseKey is the candidate whose public key has the fingerprint the
// image's manifest recorded. With no fingerprint, it is the first
// candidate that loads.
func ChooseKey(candidates []string, fingerprint string) (string, ssh.Signer, error) {
	var tried []string
	for _, p := range candidates {
		s, err := LoadSigner(p)
		if err != nil {
			tried = append(tried, fmt.Sprintf("%s (%v)", p, err))
			continue
		}
		if fingerprint == "" || ssh.FingerprintSHA256(s.PublicKey()) == fingerprint {
			return p, s, nil
		}
		tried = append(tried, p)
	}
	return "", nil, fmt.Errorf("no private key matches %s, the key this image authorized; tried: %s. "+
		"Set VMAVS_SSH_KEY or pass --key", fingerprint, strings.Join(tried, ", "))
}
```

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/guest/... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...`
Expected: PASS, clean. If `ssh.SupportedAlgorithms`/`InsecureAlgorithms`
or `ServerConfig.PublicKeyAuthAlgorithms` do not exist in x/crypto
v0.57.0, stop and report NEEDS_CONTEXT, with the API you found instead. Do
not weaken the legacy test.

- [ ] **Step 6: Commit**

```bash
git add go.mod go.sum internal/guest
git commit   # subject: "vmavs (Go): an SSH client, and the key an image authorized"
```

---

### Task 5: `vmavs run`

**Files:**
- Create: `internal/vm/vm.go`, `internal/vm/vm_test.go`, `internal/cli/run.go`, `internal/cli/run_test.go`
- Modify: `internal/cli/cli.go` (add the `run` row to `commandTable`, and `Env.PID`: `// PID names this process's run directory. Zero means os.Getpid().` / `PID int`)

**Interfaces:**
- Consumes:
  - `config.Paths`, `config.Home`, `config.LegacyHint`, `config.QEMU`, `config.Machine` (`Register`, `Override`, `Validate`)
  - `manifest.List`, `manifest.Find`, `(Manifest).Hardware`
  - `machine.ForRun`, `machine.Firmware`
  - `proc.Runner`, `cli.runner`
- Produces:
  - `vm.Run{Dir string; Image manifest.Manifest; Spec machine.Spec}`
  - `vm.Prepare(ctx, r proc.Runner, p config.Paths, m manifest.Manifest, hw config.Machine, qemu string, pid int) (*vm.Run, error)`
  - `(*vm.Run).Boot(ctx, r, stdin io.Reader, stdout, stderr io.Writer) error`
  - `(*vm.Run).Remove() error`
  - `vm.State{Image string; Port, PID int; Dir string}`
  - `vm.Live(p config.Paths) ([]vm.State, error)`
  - `cli.chooseImage(e *Env, p config.Paths, name string) (manifest.Manifest, error)`, reused by Tasks 6 and 7
  - `cli.paths(e *Env) (config.Paths, error)`

- [ ] **Step 1: Write the failing `vm` tests**

`internal/vm/vm_test.go`:

```go
package vm

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// home builds a VMAVS_HOME the way the shell pipeline leaves it.
func home(t *testing.T) (config.Paths, manifest.Manifest) {
	t.Helper()
	p := config.Paths{Home: t.TempDir()}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), filepath.Join(p.Work(), "opencore-p3.img"),
		filepath.Join(p.Images(), "img.qcow2")} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, []byte("x"), 0o644)
	}
	os.WriteFile(filepath.Join(p.Images(), "img.manifest"), []byte("name\timg\n"), 0o644)
	m, err := manifest.Find(p.Images(), "img")
	if err != nil {
		t.Fatal(err)
	}
	return p, m
}

func TestPrepareMakesAnOverlayAndItsOwnNVRAM(t *testing.T) {
	p, m := home(t)
	f := &proc.Fake{}
	r, err := Prepare(context.Background(), f, p, m, m.Hardware(), "qemu-system-x86_64", 4242)
	if err != nil {
		t.Fatal(err)
	}
	if r.Dir != filepath.Join(p.Run(), "img-4242") {
		t.Fatalf("dir %q", r.Dir)
	}
	create := f.Calls[0].String()
	if !strings.HasPrefix(create, "qemu-img create") || !strings.Contains(create, "-b "+m.Image()) ||
		!strings.Contains(create, "-F qcow2") {
		t.Fatalf("overlay: %s", create)
	}
	if b, _ := os.ReadFile(filepath.Join(r.Dir, "OVMF_VARS.fd")); string(b) != "x" {
		t.Fatal("NVRAM not copied from the template")
	}
	args := r.Spec.Args()
	if !slices.Contains(args, "id=target,if=none,format=qcow2,file="+filepath.Join(r.Dir, "disk.qcow2")) {
		t.Fatalf("boots %q, not the overlay", args)
	}
	if !slices.Contains(args, "id=opencore,if=none,format=raw,snapshot=on,file="+filepath.Join(p.Work(), "opencore-p3.img")) {
		t.Fatal("does not use the shell tree's OpenCore image")
	}
}

func TestPrepareNamesWhatIsMissing(t *testing.T) {
	p, m := home(t)
	os.Remove(p.OVMFCode())
	_, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1)
	if err == nil || !strings.Contains(err.Error(), "OVMF_CODE.fd") {
		t.Fatalf("err = %v", err)
	}
}

func TestLiveFindsThisProcessesRunAndIgnoresDeadOnes(t *testing.T) {
	p, m := home(t)
	if _, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", os.Getpid()); err != nil {
		t.Fatal(err)
	}
	dead := filepath.Join(p.Run(), "img-999999")
	os.MkdirAll(dead, 0o755)
	os.WriteFile(filepath.Join(dead, "state"), []byte("image\timg\nport\t2222\npid\t999999\n"), 0o644)
	live, err := Live(p)
	if err != nil || len(live) != 1 || live[0].PID != os.Getpid() || live[0].Port != 2222 {
		t.Fatalf("live=%+v err=%v", live, err)
	}
}
```

Run: `go test ./internal/vm/` → FAIL.

- [ ] **Step 2: Implement `internal/vm/vm.go`**

```go
// Package vm prepares, boots and cleans up a run of a built image: a
// throwaway overlay, its own NVRAM, and a state file that `vmavs ssh`
// reads to find it.
package vm

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/machine"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

type Run struct {
	Dir   string
	Image manifest.Manifest
	Spec  machine.Spec
}

type State struct {
	Image string
	Port  int
	PID   int
	Dir   string
}

// Prepare creates run/<image>-<pid>/: a qcow2 overlay backed by the
// image, so the image is never written, and this VM's own copy of the
// NVRAM template.
func Prepare(ctx context.Context, r proc.Runner, p config.Paths, m manifest.Manifest, hw config.Machine, qemu string, pid int) (*Run, error) {
	fw := machine.Firmware{OVMFCode: p.OVMFCode(), OpenCore: p.OpenCoreImage()}
	for _, need := range []struct{ path, from string }{
		{m.Image(), "vmavs image"},
		{fw.OVMFCode, "vmavs firmware"},
		{p.OVMFVarsTemplate(), "vmavs firmware"},
		{fw.OpenCore, "vmavs firmware"},
	} {
		if _, err := os.Stat(need.path); err != nil {
			return nil, fmt.Errorf("%s is missing; it is built by `%s` "+
				"(until that is ported: ./image/build-image.sh)", need.path, need.from)
		}
	}
	dir := filepath.Join(p.Run(), fmt.Sprintf("%s-%d", m.Name, pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	overlay := filepath.Join(dir, "disk.qcow2")
	if err := r.Run(ctx, proc.Cmd{Name: "qemu-img", Args: []string{
		"create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", m.Image(), overlay,
	}}); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	nvram := filepath.Join(dir, "OVMF_VARS.fd")
	if err := copyFile(p.OVMFVarsTemplate(), nvram); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	spec := machine.ForRun(hw, fw, nvram, overlay, filepath.Join(dir, "monitor.sock"))
	spec.QEMU = qemu
	state := fmt.Sprintf("image\t%s\nport\t%d\npid\t%d\n", m.Name, hw.SSHPort, pid)
	if err := os.WriteFile(filepath.Join(dir, "state"), []byte(state), 0o644); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	return &Run{Dir: dir, Image: m, Spec: spec}, nil
}

func (r *Run) Boot(ctx context.Context, run proc.Runner, stdin io.Reader, stdout, stderr io.Writer) error {
	c := r.Spec.Command()
	c.Stdin, c.Stdout, c.Stderr = stdin, stdout, stderr
	return run.Run(ctx, c)
}

func (r *Run) Remove() error { return os.RemoveAll(r.Dir) }

// Live is every run directory whose process is still running.
func Live(p config.Paths) ([]State, error) {
	states, err := filepath.Glob(filepath.Join(p.Run(), "*", "state"))
	if err != nil {
		return nil, err
	}
	var out []State
	for _, f := range states {
		s, err := readState(f)
		if err != nil || !alive(s.PID) {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

func readState(path string) (State, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return State{}, err
	}
	s := State{Dir: filepath.Dir(path)}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, _ := strings.Cut(line, "\t")
		switch k {
		case "image":
			s.Image = v
		case "port":
			s.Port, _ = strconv.Atoi(v)
		case "pid":
			s.PID, _ = strconv.Atoi(v)
		}
	}
	if s.PID == 0 || s.Port == 0 {
		return State{}, fmt.Errorf("%s: incomplete", path)
	}
	return s, nil
}

// alive: signal 0 checks for existence. EPERM still means it exists.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}
```

Run: `go test ./internal/vm/` → PASS.

- [ ] **Step 3: Write the failing CLI test**

`internal/cli/run_test.go`:

```go
package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// shellHome is a VMAVS_HOME laid out the way the shell pipeline leaves it,
// with one legacy image (usb-net, no openssh line).
func shellHome(t *testing.T) string {
	t.Helper()
	h := t.TempDir()
	p := config.Paths{Home: h}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(),
		filepath.Join(p.Work(), "opencore-p3.img"), filepath.Join(p.Images(), "old.qcow2")} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, []byte("x"), 0o644)
	}
	os.WriteFile(filepath.Join(p.Images(), "old.manifest"),
		[]byte("name\told\naccel\tkvm machine=q35 cpu=Penryn ram=4096 smp=2 disk=60G\n"), 0o644)
	return h
}

func runVmavs(t *testing.T, f *proc.Fake, env map[string]string, args ...string) (int, string) {
	t.Helper()
	var out, errb bytes.Buffer
	e := &Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Getenv: func(k string) string { return env[k] }, Runner: f, PID: 777}
	return Run(context.Background(), args, e), errb.String()
}

func TestRunBootsTheLatestImageOnItsOwnHardwareAndCleansUp(t *testing.T) {
	h := shellHome(t)
	f := &proc.Fake{}
	code, stderr := runVmavs(t, f, map[string]string{"VMAVS_HOME": h}, "run")
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	boot := f.Calls[len(f.Calls)-1].String()
	if !strings.HasPrefix(boot, "qemu-system-x86_64 ") || !strings.Contains(boot, "usb-net,bus=usb.0,netdev=net0") {
		t.Fatalf("boot: %s", boot)
	}
	if _, err := os.Stat(filepath.Join(h, "run", "old-777")); !os.IsNotExist(err) {
		t.Fatal("run directory left behind without --keep")
	}
}

func TestRunKeepAndFlagsWin(t *testing.T) {
	h := shellHome(t)
	f := &proc.Fake{}
	code, _ := runVmavs(t, f, map[string]string{"VMAVS_HOME": h, "VMAVS_QEMU": "/opt/q"},
		"run", "--keep", "--nic", "e1000-82545em", "--memory", "8192")
	if code != 0 {
		t.Fatal(code)
	}
	boot := f.Calls[len(f.Calls)-1].String()
	if !strings.HasPrefix(boot, "/opt/q ") || !strings.Contains(boot, "e1000-82545em,netdev=net0") || !strings.Contains(boot, "-m 8192") {
		t.Fatalf("boot: %s", boot)
	}
	if _, err := os.Stat(filepath.Join(h, "run", "old-777", "OVMF_VARS.fd")); err != nil {
		t.Fatal("--keep must keep the run directory")
	}
}

func TestRunWithNoImagesGivesTheLegacyHint(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".local", "share", "mavericks-qemu-guest"), 0o755)
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"HOME": home}, "run")
	if code != 1 || !strings.Contains(stderr, "export VMAVS_HOME=") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}
```

Run: `go test ./internal/cli/` → FAIL.

- [ ] **Step 4: Implement `internal/cli/run.go`; add the table row**

```go
package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/vm"
)

const runHelp = `usage: vmavs run [--image NAME] [--keep] [machine options]

Boot a built image: the most recently built one, or --image NAME. It boots
on a throwaway overlay, so the image itself is never written, with the
hardware the image was installed on (its manifest); a machine option given
here overrides that. QEMU runs in the foreground; Ctrl-C stops it. The
overlay is deleted on exit unless --keep.

Then, from another terminal: vmavs ssh
`

func cmdRun(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("run")
	flagged := config.DefaultMachine()
	flagged.Register(fs)
	name := fs.String("image", "", "image to boot (default: the most recently built)")
	keep := fs.Bool("keep", false, "keep the run directory (overlay, NVRAM) after QEMU exits")
	if err := parse(fs, e, runHelp, args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usagef("run takes no arguments (got %q)", fs.Args())
	}
	p, err := paths(e)
	if err != nil {
		return err
	}
	m, err := chooseImage(e, p, *name)
	if err != nil {
		return err
	}
	hw := m.Hardware()
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	hw.Override(flagged, func(n string) bool { return set[n] })
	if err := hw.Validate(); err != nil {
		return usagef("%v", err)
	}
	pid := e.PID
	if pid == 0 {
		pid = os.Getpid()
	}
	r := runner(e)
	run, err := vm.Prepare(ctx, r, p, m, hw, config.QEMU(e.Getenv), pid)
	if err != nil {
		return err
	}
	if !*keep {
		defer run.Remove()
	}
	logf(e, "run", "booting %s (%s, %d MiB, %s); ssh on localhost:%d", m.Name, hw.CPU, hw.MemoryMB, hw.NIC, hw.SSHPort)
	err = run.Boot(ctx, r, e.Stdin, e.Stdout, e.Stderr)
	if ctx.Err() != nil {
		logf(e, "run", "stopped")
		return nil
	}
	return err
}

func paths(e *Env) (config.Paths, error) {
	h, err := config.Home(e.Getenv)
	return config.Paths{Home: h}, err
}

// chooseImage is the named image, or the most recently built one. With
// none, it explains where the shell tree's images are, if they exist.
func chooseImage(e *Env, p config.Paths, name string) (manifest.Manifest, error) {
	if name != "" {
		return manifest.Find(p.Images(), name)
	}
	all, err := manifest.List(p.Images())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return manifest.Manifest{}, err
	}
	if len(all) == 0 {
		msg := fmt.Sprintf("no built images in %s; build one with `vmavs image`", p.Images())
		if hint := config.LegacyHint(e.Getenv, config.Exists); hint != "" {
			msg += "\n" + hint
		}
		return manifest.Manifest{}, errors.New(msg)
	}
	return all[0], nil
}
```

Add to `commandTable()`, before `version`:
`{"run", "Boot a built image on a throwaway overlay", cmdRun},`

- [ ] **Step 5: Run everything; commit**

Run: `go test ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` → PASS, clean.

```bash
git add internal/vm internal/cli
git commit   # subject: "vmavs run: boot the image vmavs built, on its own hardware, on an overlay"
```

---

### Task 6: `vmavs ssh`

**Files:**
- Create: `internal/cli/ssh.go`, `internal/cli/ssh_test.go`
- Modify: `internal/cli/cli.go` (add the table row)

**Interfaces:**
- Consumes:
  - `vm.Live`, `chooseImage`, `manifest.Find`
  - `guest.KeyCandidates`, `guest.ChooseKey`, `guest.LoadSigner`, `guest.Dial`, `guest.Exec`, `guest.Shell`
  - `guesttest.Start`
- Produces: the `ssh` subcommand. `vmavs ssh [--image NAME] [--port N] [--user U] [--key PATH] [-- command…]`.

- [ ] **Step 1: Write the failing tests**

`internal/cli/ssh_test.go`:

```go
package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// guestHome is a VMAVS_HOME with one image whose manifest names the key in
// keys/, a live run of it (this process's pid) forwarding to a test server,
// and the server's port.
func guestHome(t *testing.T) (home string) {
	t.Helper()
	home = t.TempDir()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "build")
	os.MkdirAll(filepath.Join(home, "keys"), 0o700)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519"), pem.EncodeToMemory(block), 0o600)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519.pub"), ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	os.MkdirAll(filepath.Join(home, "images"), 0o755)
	os.WriteFile(filepath.Join(home, "images", "img.qcow2"), nil, 0o644)
	os.WriteFile(filepath.Join(home, "images", "img.manifest"), []byte(fmt.Sprintf(
		"name\timg\nopenssh\t10.5p1-mavericks.2\nsshkey\t%s build\n", ssh.FingerprintSHA256(s.PublicKey()))), 0o644)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	port := addr[strings.LastIndex(addr, ":")+1:]
	dir := filepath.Join(home, "run", fmt.Sprintf("img-%d", os.Getpid()))
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "state"), []byte(fmt.Sprintf("image\timg\nport\t%s\npid\t%d\n", port, os.Getpid())), 0o644)
	return home
}

func sshVmavs(t *testing.T, home string, args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	e := &Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Getenv: func(k string) string { return map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}[k] }}
	code := Run(context.Background(), append([]string{"ssh"}, args...), e)
	return code, out.String(), errb.String()
}

func TestSSHFindsTheRunningGuestAndItsKey(t *testing.T) {
	home := guestHome(t)
	code, out, errs := sshVmavs(t, home, "--", "sw_vers", "-productVersion")
	if code != 0 || out != "ran: sw_vers -productVersion\n" {
		t.Fatalf("code=%d out=%q err=%q", code, out, errs)
	}
}

func TestSSHPassesTheRemoteExitStatusThrough(t *testing.T) {
	home := guestHome(t)
	if code, _, _ := sshVmavs(t, home, "--", "fail"); code != 3 {
		t.Fatalf("code=%d, want the remote status 3", code)
	}
}

func TestSSHWithNoRunningGuestSaysHowToStartOne(t *testing.T) {
	home := t.TempDir()
	code, _, errs := sshVmavs(t, home, "--", "true")
	if code != 1 || !strings.Contains(errs, "vmavs run") {
		t.Fatalf("code=%d err=%q", code, errs)
	}
}
```

Run: `go test ./internal/cli/ -run SSH` → FAIL.

- [ ] **Step 2: Implement `internal/cli/ssh.go`; add the table row**

```go
package cli

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/guest"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/vm"
)

const sshHelp = `usage: vmavs ssh [--image NAME] [--port N] [--user U] [--key PATH] [-- command...]

Open a shell in the running guest, or run one command there and exit with
its status. The guest is the one "vmavs run" started (--image picks one if
several are running); the key is the one that image authorized, found by
the fingerprint in its manifest. Host keys are not checked: every run's
overlay has fresh ones.
`

func cmdSSH(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("ssh")
	name := fs.String("image", "", "which running image (when more than one is)")
	port := fs.Int("port", 0, "host port forwarded to the guest's 22 (default: the running guest's)")
	user := fs.String("user", config.DefaultSSHUser, "guest account")
	keyPath := fs.String("key", "", "private key (default: the one the image authorized)")
	if err := parse(fs, e, sshHelp, args); err != nil {
		return err
	}
	p, err := paths(e)
	if err != nil {
		return err
	}
	m, livePort, err := sshTarget(e, p, *name, *port)
	if err != nil {
		return err
	}
	if *port == 0 {
		*port = livePort
	}
	var signer ssh.Signer
	if *keyPath != "" {
		signer, err = guest.LoadSigner(*keyPath)
	} else {
		_, signer, err = guest.ChooseKey(guest.KeyCandidates(e.Getenv, p.Keys()), m.SSHKeyFingerprint())
	}
	if err != nil {
		return err
	}
	t := guest.Target{Addr: net.JoinHostPort("127.0.0.1", strconv.Itoa(*port)), User: *user,
		Signer: signer, Legacy: m.LegacySSH(), Timeout: 10 * time.Second}
	c, err := guest.Dial(ctx, t)
	if err != nil {
		return err
	}
	defer c.Close()
	var code int
	if fs.NArg() > 0 {
		code, err = guest.Exec(c, strings.Join(fs.Args(), " "), e.Stdin, e.Stdout, e.Stderr)
	} else {
		in, ok := e.Stdin.(*os.File)
		if !ok {
			return errors.New("an interactive shell needs a terminal; pass a command after --")
		}
		code, err = guest.Shell(c, in, e.Stdout, e.Stderr)
	}
	if err != nil {
		return err
	}
	if code != 0 {
		return &ExitError{Code: code}
	}
	return nil
}

// sshTarget is the image to talk to and the port its run forwards. With
// --port and no running guest, the image is --image or the latest built.
func sshTarget(e *Env, p config.Paths, name string, port int) (manifest.Manifest, int, error) {
	live, err := vm.Live(p)
	if err != nil {
		return manifest.Manifest{}, 0, err
	}
	var match []vm.State
	for _, s := range live {
		if name == "" || s.Image == name {
			match = append(match, s)
		}
	}
	switch {
	case len(match) == 1:
		m, err := manifest.Find(p.Images(), match[0].Image)
		return m, match[0].Port, err
	case len(match) > 1:
		var names []string
		for _, s := range match {
			names = append(names, fmt.Sprintf("%s (port %d)", s.Image, s.Port))
		}
		return manifest.Manifest{}, 0, usagef("several guests are running: %s; pick one with --image", strings.Join(names, ", "))
	case port != 0:
		m, err := chooseImage(e, p, name)
		return m, port, err
	default:
		return manifest.Manifest{}, 0, errors.New("no guest is running; start one with `vmavs run`, or pass --port")
	}
}
```

Add to `commandTable()`, after `run`:
`{"ssh", "Open a shell in the running guest", cmdSSH},`

- [ ] **Step 3: Run everything; commit**

Run: `go test ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` → PASS, clean.

```bash
git add internal/cli
git commit   # subject: "vmavs ssh: find the running guest and the key its image authorized"
```

---

### Task 7: `vmavs emit packer`, and CI validation of it

**Files:**
- Create: `internal/emit/packer.go`, `internal/emit/hcl.go`, `internal/emit/packer_test.go`, `internal/emit/testdata/packer.pkr.hcl` (golden, generated with `-update`), `internal/cli/emit.go`, `internal/cli/emit_test.go`
- Modify: `go.mod`/`go.sum` (`go get github.com/hashicorp/hcl/v2@v2.25.0 github.com/zclconf/go-cty@v1.19.0`), `internal/cli/cli.go` (the table row), `.github/workflows/ci.yml` (`packer-validate`)

**Interfaces:**
- Consumes: `config.Machine`, `config.DefaultDiskGB`, `config.DefaultSSHUser`, `config.DefaultSMBIOS`, `machine.ForInstall`, `proc.Runner`, `cli.runner`, `chooseImage`.
- Produces:
  - `emit.Packer(hw config.Machine, diskGB int) ([]byte, error)`
  - `emit.Variables []emit.Variable`, where `emit.Variable{Name, Description string}`
  - the `emit` subcommand: `vmavs emit packer [--image NAME] [--out FILE] [--check] [machine options]`

**What the template is.** `machine.ForInstall` renders the hardware. Paths
become variable references:

| Path | Becomes |
|---|---|
| OVMF code | `${var.ovmf_code}` |
| NVRAM | `${var.ovmf_vars}` |
| OpenCore | `${var.opencore_media}` |
| installer | `${var.media}` |
| target | `output-mavericks/mavericks.qcow2` (Packer's `output_directory`/`vm_name` convention) |

Packer's own fields take:
- `accelerator`, `machine_type` (with `,vmport=off`), `cpu_model`,
  `memory`, `cpus`;
- `disk_size` (`"<GB*1024>M"`), `format = "qcow2"`, `disk_image = false`;
- `iso_url = var.media`, `iso_checksum = "none"`;
- `output_directory`, `vm_name`;
- `headless = true`, `boot_wait = "0s"`, `communicator = "ssh"`;
- `ssh_username`, `ssh_private_key_file = var.ssh_key`,
  `ssh_timeout = "60m"`;
- `host_port_min`/`host_port_max` = the SSH port.

Every other argument pair goes into `qemuargs`, in `Spec.Args()` order,
leaving out the ones those fields replace:
`-accel -machine -cpu -m -smp -display -monitor`. `required_plugins`
declares qemu and vagrant. `build` has `sources = ["source.qemu.mavericks"]`
and `post-processor "vagrant" { output = "mavericks-{{.Provider}}.box" }`.

- [ ] **Step 1: Write the failing tests**

`internal/emit/packer_test.go`:

```go
package emit

import (
	"flag"
	"os"
	"strings"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"

	"github.com/Mavergreen/vm-guest/internal/config"
)

var update = flag.Bool("update", false, "rewrite testdata/packer.pkr.hcl")

func template(t *testing.T) string {
	t.Helper()
	b, err := Packer(config.DefaultMachine(), config.DefaultDiskGB)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestTheTemplateIsValidHCL(t *testing.T) {
	src := template(t)
	f, diags := hclsyntax.ParseConfig([]byte(src), "packer.pkr.hcl", hcl.InitialPos)
	if diags.HasErrors() {
		t.Fatalf("%v\n%s", diags, src)
	}
	body := f.Body.(*hclsyntax.Body)
	kinds := map[string]int{}
	for _, b := range body.Blocks {
		kinds[b.Type]++
	}
	if kinds["packer"] != 1 || kinds["variable"] != len(Variables) || kinds["source"] != 1 || kinds["build"] != 1 {
		t.Fatalf("blocks %v", kinds)
	}
}

func TestTheTemplateMatchesTheGoldenFile(t *testing.T) {
	src := template(t)
	if *update {
		os.WriteFile("testdata/packer.pkr.hcl", []byte(src), 0o644)
	}
	want, _ := os.ReadFile("testdata/packer.pkr.hcl")
	if src != string(want) {
		t.Fatalf("differs from testdata/packer.pkr.hcl; run go test ./internal/emit -update and review the diff")
	}
}

func TestWhatPackerValidateTaughtUs(t *testing.T) {
	src := template(t)
	for _, want := range []string{
		`"github.com/hashicorp/vagrant"`, `"github.com/hashicorp/qemu"`,
		`host_port_min`, `machine_type`, `"q35,vmport=off"`,
		`${var.ovmf_code}`, `${var.opencore_media}`, `${var.media}`, `output-mavericks/mavericks.qcow2`,
		`post-processor "vagrant"`, `mavericks-{{.Provider}}.box`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("template lacks %s", want)
		}
	}
	for _, bad := range []string{"ssh_host_port_min", "boot_command =", "vagrantcloud"} {
		if strings.Contains(src, bad) {
			t.Errorf("template contains %s", bad)
		}
	}
}

func TestTheTemplateCarriesNoAppleBytes(t *testing.T) {
	src := template(t)
	for _, bad := range []string{"osk=", "isa-applesmc", "InstallESD", "BaseSystem"} {
		if strings.Contains(src, bad) {
			t.Errorf("template contains %s", bad)
		}
	}
}

func TestTheHeaderSaysWhatValidationProves(t *testing.T) {
	src := template(t)
	if !strings.Contains(src, "packer validate") || !strings.Contains(strings.ToLower(src), "no packer build has ever run") {
		t.Fatal("header must say it validates and has never been built")
	}
}

func TestQuotedTemplateEscapesLiteralText(t *testing.T) {
	got := string(templateTokens(`a "b" ${var.x} $${lit}`).Bytes())
	if got != `"a \"b\" ${var.x} $$${lit}"` {
		t.Fatalf("got %s", got)
	}
}
```

`internal/cli/emit_test.go`:

```go
package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

func TestEmitWritesTheTemplate(t *testing.T) {
	out := filepath.Join(t.TempDir(), "m.pkr.hcl")
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": t.TempDir()}, "emit", "packer", "--out", out)
	b, _ := os.ReadFile(out)
	if code != 0 || !strings.Contains(string(b), `source "qemu" "mavericks"`) {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func TestEmitCheckWithoutPackerFailsSayingSo(t *testing.T) {
	out := filepath.Join(t.TempDir(), "m.pkr.hcl")
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": t.TempDir()}, "emit", "packer", "--out", out, "--check")
	if code != 1 || !strings.Contains(stderr, "packer is not installed") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func TestEmitCheckGivesEveryVariableAValueAndARealKey(t *testing.T) {
	out := filepath.Join(t.TempDir(), "m.pkr.hcl")
	var keySeen bool
	f := &proc.Fake{Paths: map[string]string{"packer": "/usr/bin/packer"}, Handle: func(c proc.Cmd) error {
		for _, a := range c.Args {
			if k, ok := strings.CutPrefix(a, "ssh_key="); ok {
				b, err := os.ReadFile(k)
				keySeen = err == nil && strings.Contains(string(b), "OPENSSH PRIVATE KEY")
			}
		}
		return nil
	}}
	code, stderr := runVmavs(t, f, map[string]string{"VMAVS_HOME": t.TempDir()}, "emit", "packer", "--out", out, "--check")
	if code != 0 || !keySeen {
		t.Fatalf("code=%d keySeen=%v stderr=%s", code, keySeen, stderr)
	}
	call := f.Calls[0].String()
	for _, v := range []string{"media=", "ovmf_code=", "ovmf_vars=", "opencore_media=", "ssh_key="} {
		if !strings.Contains(call, "-var "+v) {
			t.Errorf("no -var %s in %s", v, call)
		}
	}
	for _, a := range f.Calls[0].Args {
		if k, ok := strings.CutPrefix(a, "ssh_key="); ok {
			if _, err := os.Stat(k); !errors.Is(err, os.ErrNotExist) {
				t.Error("the placeholder key outlived --check")
			}
		}
	}
}

func TestEmitRefusesAnotherTarget(t *testing.T) {
	code, stderr := runVmavs(t, &proc.Fake{}, nil, "emit", "libvirt")
	if code != 2 || !strings.Contains(stderr, "packer") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}
```

Run: `go get github.com/hashicorp/hcl/v2@v2.25.0 github.com/zclconf/go-cty@v1.19.0 && go test ./internal/emit/ ./internal/cli/` → FAIL.

- [ ] **Step 2: Implement `internal/emit/hcl.go`**

```go
package emit

import (
	"strings"

	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/hashicorp/hcl/v2/hclwrite"
)

// templateTokens is a quoted HCL string in which ${var.NAME} stays an
// interpolation and everything else is literal text, escaped. hclwrite's
// own TokensForValue escapes every ${, which is right for literal text
// and wrong for the variable references a template needs.
func templateTokens(s string) hclwrite.Tokens {
	toks := hclwrite.Tokens{{Type: hclsyntax.TokenOQuote, Bytes: []byte(`"`)}}
	for s != "" {
		i := strings.Index(s, "${var.")
		if i < 0 {
			toks = append(toks, literal(s))
			break
		}
		if i > 0 {
			toks = append(toks, literal(s[:i]))
		}
		end := strings.Index(s[i:], "}")
		name := s[i+len("${var.") : i+end]
		toks = append(toks,
			&hclwrite.Token{Type: hclsyntax.TokenTemplateInterp, Bytes: []byte("${")},
			&hclwrite.Token{Type: hclsyntax.TokenIdent, Bytes: []byte("var")},
			&hclwrite.Token{Type: hclsyntax.TokenDot, Bytes: []byte(".")},
			&hclwrite.Token{Type: hclsyntax.TokenIdent, Bytes: []byte(name)},
			&hclwrite.Token{Type: hclsyntax.TokenTemplateSeqEnd, Bytes: []byte("}")},
		)
		s = s[i+end+1:]
	}
	return append(toks, &hclwrite.Token{Type: hclsyntax.TokenCQuote, Bytes: []byte(`"`)})
}

func literal(s string) *hclwrite.Token {
	esc := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "${", "$${", "%{", "%%{").Replace(s)
	return &hclwrite.Token{Type: hclsyntax.TokenQuotedLit, Bytes: []byte(esc)}
}

// pairsTokens is `[\n ["-flag", "value"],\n ... ]`, one pair per line.
func pairsTokens(pairs [][2]string) hclwrite.Tokens {
	toks := hclwrite.Tokens{
		{Type: hclsyntax.TokenOBrack, Bytes: []byte("[")},
		{Type: hclsyntax.TokenNewline, Bytes: []byte("\n")},
	}
	for _, p := range pairs {
		toks = append(toks, &hclwrite.Token{Type: hclsyntax.TokenOBrack, Bytes: []byte("[")})
		toks = append(toks, templateTokens(p[0])...)
		toks = append(toks, &hclwrite.Token{Type: hclsyntax.TokenComma, Bytes: []byte(",")})
		toks = append(toks, templateTokens(p[1])...)
		toks = append(toks,
			&hclwrite.Token{Type: hclsyntax.TokenCBrack, Bytes: []byte("]")},
			&hclwrite.Token{Type: hclsyntax.TokenComma, Bytes: []byte(",")},
			&hclwrite.Token{Type: hclsyntax.TokenNewline, Bytes: []byte("\n")})
	}
	return append(toks, &hclwrite.Token{Type: hclsyntax.TokenCBrack, Bytes: []byte("]")})
}
```

- [ ] **Step 3: Implement `internal/emit/packer.go`**

```go
// Package emit writes artifacts for other tools. Today: one Packer
// template, for the machine machine.ForInstall describes.
package emit

import (
	"fmt"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclwrite"
	"github.com/zclconf/go-cty/cty"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/machine"
)

type Variable struct{ Name, Description string }

// Variables are the user's own local paths. The template names them; it
// never carries what they hold.
var Variables = []Variable{
	{"media", "Installer media image from `vmavs media`"},
	{"ovmf_code", "OVMF_CODE.fd from `vmavs firmware`"},
	{"ovmf_vars", "This VM's own copy of OVMF_VARS.fd"},
	{"opencore_media", "OpenCore boot image from `vmavs firmware`"},
	{"ssh_key", "Private key whose public half the image's first-boot payload authorized"},
}

const header = `# Generated by vmavs emit packer. Do not edit; re-emit.
#
# WHAT IS AND IS NOT VERIFIED. The field names, nesting and types are
# MEASURED: packer validate (Packer 1.16.1, qemu plugin 1.1.6, vagrant
# plugin 1.1.7) accepts this template, and this project's CI re-validates
# it on every push. The values are the machine vmavs installs and boots.
# No Packer build has ever run from it, so whether the drive mapping and
# the SSH forward work in a real build is REASONED.
#
# NO APPLE BYTES. This template names local paths you produced; it
# contains none of Apple's software, and must never be changed so that it
# does. A box built from it contains Apple's operating system and can never
# be shared, so there is deliberately no Vagrant Cloud upload here.
#
# NO boot_command. Apple's own installer reads rc.cdrom.local,
# minstallconfig.xml and OSInstall.collection off the media, so the install
# runs unattended with nobody typing at a console.
#
# DRIVES ARE IN qemuargs. Supplying any -drive in qemuargs replaces all of
# Packer's default drives (packer-plugin-qemu; REASONED from its source),
# and OpenCore does not see a CD-ROM installer (MEASURED in P4), so the
# installer and target are attached here as the install stage attaches them.

`

// firstClass are the QEMU flags Packer's own fields replace.
var firstClass = map[string]bool{
	"-accel": true, "-machine": true, "-cpu": true, "-m": true, "-smp": true,
	"-display": true, "-monitor": true,
}

func Packer(hw config.Machine, diskGB int) ([]byte, error) {
	if err := hw.Validate(); err != nil {
		return nil, err
	}
	spec := machine.ForInstall(hw,
		machine.Firmware{OVMFCode: "${var.ovmf_code}", OpenCore: "${var.opencore_media}"},
		"${var.ovmf_vars}", "output-mavericks/mavericks.qcow2", "${var.media}", "")
	args := spec.Args()
	var pairs [][2]string
	for i := 0; i+1 < len(args); i += 2 {
		if !firstClass[args[i]] {
			pairs = append(pairs, [2]string{args[i], args[i+1]})
		}
	}

	f := hclwrite.NewEmptyFile()
	root := f.Body()
	plugins := root.AppendNewBlock("packer", nil).Body().AppendNewBlock("required_plugins", nil).Body()
	for _, p := range []string{"qemu", "vagrant"} {
		plugins.SetAttributeValue(p, cty.ObjectVal(map[string]cty.Value{
			"source":  cty.StringVal("github.com/hashicorp/" + p),
			"version": cty.StringVal("~> 1"),
		}))
	}
	for _, v := range Variables {
		root.AppendNewline()
		b := root.AppendNewBlock("variable", []string{v.Name}).Body()
		b.SetAttributeTraversal("type", hcl.Traversal{hcl.TraverseRoot{Name: "string"}})
		b.SetAttributeValue("description", cty.StringVal(v.Description))
	}
	root.AppendNewline()
	src := root.AppendNewBlock("source", []string{"qemu", "mavericks"}).Body()
	ref := func(name string) hcl.Traversal {
		return hcl.Traversal{hcl.TraverseRoot{Name: "var"}, hcl.TraverseAttr{Name: name}}
	}
	src.SetAttributeTraversal("iso_url", ref("media"))
	src.SetAttributeValue("iso_checksum", cty.StringVal("none"))
	src.SetAttributeValue("disk_image", cty.False)
	src.SetAttributeValue("disk_size", cty.StringVal(fmt.Sprintf("%dM", diskGB*1024)))
	src.SetAttributeValue("format", cty.StringVal("qcow2"))
	src.SetAttributeValue("output_directory", cty.StringVal("output-mavericks"))
	src.SetAttributeValue("vm_name", cty.StringVal("mavericks.qcow2"))
	src.SetAttributeValue("accelerator", cty.StringVal(hw.Accel))
	src.SetAttributeValue("machine_type", cty.StringVal(hw.Type+",vmport=off"))
	src.SetAttributeValue("cpu_model", cty.StringVal(hw.CPU))
	src.SetAttributeValue("memory", cty.NumberIntVal(int64(hw.MemoryMB)))
	src.SetAttributeValue("cpus", cty.NumberIntVal(int64(hw.SMP)))
	src.SetAttributeValue("headless", cty.True)
	src.SetAttributeValue("boot_wait", cty.StringVal("0s"))
	src.SetAttributeValue("communicator", cty.StringVal("ssh"))
	src.SetAttributeValue("ssh_username", cty.StringVal(config.DefaultSSHUser))
	src.SetAttributeTraversal("ssh_private_key_file", ref("ssh_key"))
	src.SetAttributeValue("ssh_timeout", cty.StringVal("60m"))
	src.SetAttributeValue("host_port_min", cty.NumberIntVal(int64(hw.SSHPort)))
	src.SetAttributeValue("host_port_max", cty.NumberIntVal(int64(hw.SSHPort)))
	src.SetAttributeRaw("qemuargs", pairsTokens(pairs))
	root.AppendNewline()
	build := root.AppendNewBlock("build", nil).Body()
	build.SetAttributeValue("sources", cty.ListVal([]cty.Value{cty.StringVal("source.qemu.mavericks")}))
	build.AppendNewBlock("post-processor", []string{"vagrant"}).Body().
		SetAttributeValue("output", cty.StringVal("mavericks-{{.Provider}}.box"))

	return append([]byte(header), hclwrite.Format(f.Bytes())...), nil
}
```

Run: `go test ./internal/emit/ -update && go test ./internal/emit/`. Read
`internal/emit/testdata/packer.pkr.hcl` in full before committing it: it
is the product, and the golden file only freezes what you approved.

- [ ] **Step 4: Implement `internal/cli/emit.go`; add the table row**

```go
package cli

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/emit"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

const emitHelp = `usage: vmavs emit packer [--out FILE] [--check] [machine options]

Write a Packer template (HCL2) that installs the same machine vmavs
installs and boots, for QEMU, with a local-only Vagrant box as its output.
It names local paths as variables and contains no Apple software.

--check runs packer validate on the result, with placeholder variables and
a throwaway key. It needs packer on PATH and the template's plugins
installed first (packer init FILE), which downloads them; vmavs will not.
`

func cmdEmit(ctx context.Context, e *Env, args []string) error {
	if len(args) == 0 || (args[0] != "packer" && args[0] != "-h" && args[0] != "--help") {
		return usagef("usage: vmavs emit packer [options] (the only target today is packer)")
	}
	if args[0] == "packer" {
		args = args[1:]
	}
	fs := newFlags("emit")
	hw := config.DefaultMachine()
	hw.Register(fs)
	out := fs.String("out", "", "write the template here (default: stdout)")
	check := fs.Bool("check", false, "run packer validate on --out afterwards")
	if err := parse(fs, e, emitHelp, args); err != nil {
		return err
	}
	if *check && *out == "" {
		return usagef("--check needs --out: there is nothing to validate on stdout")
	}
	src, err := emit.Packer(hw, config.DefaultDiskGB)
	if err != nil {
		return usagef("%v", err)
	}
	if *out == "" {
		_, err = e.Stdout.Write(src)
		return err
	}
	if err := os.WriteFile(*out, src, 0o644); err != nil {
		return err
	}
	logf(e, "emit", "wrote %s", *out)
	if !*check {
		return nil
	}
	return packerValidate(ctx, e, runner(e), *out)
}

// packerValidate gives every variable a placeholder and ssh_key a real,
// throwaway key: validate refuses unset variables, and the qemu plugin
// parses ssh_private_key_file (MEASURED, Packer 1.16.1).
func packerValidate(ctx context.Context, e *Env, r proc.Runner, file string) error {
	packer, err := r.LookPath("packer")
	if err != nil {
		return errors.New("packer is not installed or not on PATH; CI validates every push (.github/workflows/ci.yml)")
	}
	dir, err := os.MkdirTemp("", "vmavs-emit-check-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	block, err := ssh.MarshalPrivateKey(priv, "vmavs emit packer --check placeholder")
	if err != nil {
		return err
	}
	key := filepath.Join(dir, "key")
	if err := os.WriteFile(key, pem.EncodeToMemory(block), 0o600); err != nil {
		return err
	}
	args := []string{"validate"}
	for _, v := range emit.Variables {
		val := "/nonexistent/vmavs-check-placeholder/" + v.Name
		if v.Name == "ssh_key" {
			val = key
		}
		args = append(args, "-var", v.Name+"="+val)
	}
	args = append(args, file)
	if err := r.Run(ctx, proc.Cmd{Name: packer, Args: args, Stdout: e.Stderr, Stderr: e.Stderr}); err != nil {
		return fmt.Errorf("%w; if it names a missing plugin, run `packer init %s` first", err, file)
	}
	logf(e, "emit", "packer validate: OK (placeholder variables: the template parses; no build has run)")
	return nil
}
```

Add to `commandTable()`, after `ssh`:
`{"emit", "Write a Packer template for this machine", cmdEmit},`

`TestEverySubcommandTakesHelp` runs `vmavs emit --help`. `cmdEmit` passes
`--help` through to `parse`, which prints `usage: vmavs emit …`.

- [ ] **Step 5: Validate against the real Packer, when one is available**

If the scratch Packer from 2026-09-24 is present, run this (otherwise
skip it; CI does it):

```bash
SP=/tmp/claude-1000/-home-schmonz-Documents-trees-mavergreen-vm-guest/62efee50-ef94-4607-99e0-b11c1c28b9ad/scratchpad
[ -x "$SP/pk/packer" ] && {
  export PATH=$SP/pk:$PATH PACKER_PLUGIN_PATH=$SP/plugins PACKER_CONFIG_DIR=$SP/pkcfg CHECKPOINT_DISABLE=1
  go build -o out/vmavs ./cmd/vmavs
  ./out/vmavs emit packer --out /tmp/vmavs-go.pkr.hcl
  packer init /tmp/vmavs-go.pkr.hcl
  ./out/vmavs emit packer --out /tmp/vmavs-go.pkr.hcl --check
}
```

Expected: `The configuration is valid.`, and only the `iso_checksum none`
warning. Anything else is a real defect: fix `emit`, not the check.

- [ ] **Step 6: Switch CI's `packer-validate` job to the Go emitter**

In `.github/workflows/ci.yml`:
- Add `actions/setup-go@v7.0.0` with `go-version-file: go.mod` before
  `setup-packer`.
- Replace the "Every profile's Packer template validates" step with:

```yaml
      # The Go vmavs emits one template: the machine it installs and boots
      # (internal/machine). The shell emitter's per-profile templates retire
      # with the shell tree in phase 6; until then, tests/emit.bats covers
      # them.
      - name: vmavs emit packer validates
        run: |
          set -eu
          go build -o out/vmavs ./cmd/vmavs
          out="$RUNNER_TEMP/mavericks.pkr.hcl"
          ./out/vmavs emit packer --out "$out"
          packer init "$out"
          ./out/vmavs emit packer --out "$out" --check
```

Keep the job's header comment accurate, and validate the YAML.

- [ ] **Step 7: Run everything; commit**

Run: `go test ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...` → PASS, clean.

```bash
git add go.mod go.sum internal/emit internal/cli .github/workflows/ci.yml
git commit   # subject: "vmavs emit packer: hclwrite, from the one machine, validated in CI"
```

---

### Task 8: `vmavs doctor`

**Files:**
- Create: `internal/doctor/doctor.go`, `internal/doctor/doctor_test.go`, `internal/cli/doctor.go`
- Modify: `internal/cli/cli.go` (add the table row, first in the table)

**Interfaces:**
- Consumes: `config.Paths`, `config.QEMU`, `config.LegacyHint`, `manifest.List`, `proc.Runner.LookPath`.
- Produces:
  - `doctor.Host{GOOS string; ReadFile func(string) ([]byte, error); Exists, Writable func(string) bool; LookPath func(string) (string, error)}`
  - `doctor.Row{Status, Check, Detail string}`
  - `doctor.HostRows(h Host) []Row`
  - `doctor.Readiness{Subcommand string; Missing []string}` with `Ready() bool`
  - `doctor.Subcommands(h Host, p config.Paths, qemu string) []Readiness`
  - `doctor.Verdict(host []Row, subs []Readiness) (ok bool, line string)`

**The rules**, carried over from `lib/preconditions.sh` (host rows) and
`bin/preconditions.sh` (the verdict), narrowed to what Go `vmavs` does in
Phase 1:
- **CPU vendor:** GenuineIntel → PASS. AuthenticAMD → FAIL, "a known-harder
  case for macOS guests". Anything else → FAIL.
- **Virtualization:** a `vmx` flag → PASS, else FAIL.
- **`/dev/kvm`:** writable → PASS; present but not writable → FAIL, asking
  whether the user is in group `kvm`; absent → FAIL.
- **`kvm.ignore_msrs`:** `Y` → PASS, else WARN.
- **On a non-Linux host:** one row, `UNKNOWN accelerator`, "never probed on
  <GOOS> by this project -- see docs/test-hosts.md", and no Linux probing.
- **Subcommands:**
  - `run` needs QEMU (`VMAVS_QEMU` or `qemu-system-x86_64`), `qemu-img`,
    a built image, `OVMF_CODE.fd`, `OVMF_VARS.fd` and the OpenCore image;
  - `ssh` and `emit` need nothing external;
  - `emit --check` needs `packer`, reported as a note, not a blocker.
- **The legacy-home hint** is printed as a note when it applies.
- **Verdict:** GO when no host row FAILs and `run` is ready. It prints
  `ready: … ; blocked: <sub> (missing: …)`. Exit 1 on NO-GO.

- [ ] **Step 1: Write the failing tests**

`internal/doctor/doctor_test.go`:

```go
package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
)

func linux(cpuinfo, msrs string, kvmWritable bool, tools ...string) Host {
	have := map[string]bool{}
	for _, t := range tools {
		have[t] = true
	}
	return Host{
		GOOS: "linux",
		ReadFile: func(p string) ([]byte, error) {
			switch p {
			case "/proc/cpuinfo":
				return []byte(cpuinfo), nil
			case "/sys/module/kvm/parameters/ignore_msrs":
				return []byte(msrs + "\n"), nil
			}
			return nil, os.ErrNotExist
		},
		Exists:   func(p string) bool { return p == "/dev/kvm" },
		Writable: func(p string) bool { return p == "/dev/kvm" && kvmWritable },
		LookPath: func(n string) (string, error) {
			if have[n] {
				return "/usr/bin/" + n, nil
			}
			return "", errors.New("not found")
		},
	}
}

const intel = "vendor_id\t: GenuineIntel\nflags\t\t: fpu vmx sse4_2\n"

func row(rows []Row, check string) Row {
	for _, r := range rows {
		if r.Check == check {
			return r
		}
	}
	return Row{}
}

func TestAGoodIntelHost(t *testing.T) {
	rows := HostRows(linux(intel, "Y", true))
	for _, c := range []string{"cpu-vendor", "vmx", "kvm-device", "ignore-msrs"} {
		if row(rows, c).Status != "PASS" {
			t.Errorf("%s: %+v", c, row(rows, c))
		}
	}
}

func TestAMDAndNoVMXAndNoKVMFail(t *testing.T) {
	rows := HostRows(linux("vendor_id\t: AuthenticAMD\nflags\t\t: fpu svm\n", "N", false))
	if row(rows, "cpu-vendor").Status != "FAIL" || row(rows, "vmx").Status != "FAIL" ||
		row(rows, "kvm-device").Status != "FAIL" || row(rows, "ignore-msrs").Status != "WARN" {
		t.Fatalf("%+v", rows)
	}
}

func TestANonLinuxHostIsNeverProbed(t *testing.T) {
	h := linux(intel, "Y", true)
	h.GOOS = "darwin"
	h.ReadFile = func(string) ([]byte, error) { t.Fatal("probed a Linux path on darwin"); return nil, nil }
	rows := HostRows(h)
	if len(rows) != 1 || rows[0].Status != "UNKNOWN" || !strings.Contains(rows[0].Detail, "never probed on darwin") {
		t.Fatalf("%+v", rows)
	}
}

func TestRunNeedsAnImageFirmwareAndQEMU(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	subs := Subcommands(linux(intel, "Y", true, "qemu-system-x86_64"), p, "qemu-system-x86_64")
	var run Readiness
	for _, s := range subs {
		if s.Subcommand == "run" {
			run = s
		}
	}
	missing := strings.Join(run.Missing, " ")
	for _, want := range []string{"qemu-img", "a built image", "OVMF_CODE.fd", "OVMF_VARS.fd", "opencore"} {
		if !strings.Contains(missing, want) {
			t.Errorf("run's missing list %q lacks %s", missing, want)
		}
	}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), filepath.Join(p.Work(), "opencore-p3.img"),
		filepath.Join(p.Images(), "i.qcow2"), filepath.Join(p.Images(), "i.manifest")} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, []byte("name\ti\n"), 0o644)
	}
	subs = Subcommands(linux(intel, "Y", true, "qemu-system-x86_64", "qemu-img"), p, "qemu-system-x86_64")
	ok, line := Verdict(HostRows(linux(intel, "Y", true)), subs)
	if !ok || !strings.Contains(line, "ready: run") {
		t.Fatalf("ok=%v %s", ok, line)
	}
}

func TestVerdictIsNoGoOnAHostFailure(t *testing.T) {
	ok, line := Verdict([]Row{{"FAIL", "kvm-device", "x"}}, []Readiness{{Subcommand: "run"}})
	if ok || !strings.HasPrefix(line, "NO-GO") {
		t.Fatalf("ok=%v %s", ok, line)
	}
}
```

Run: `go test ./internal/doctor/` → FAIL.

- [ ] **Step 2: Implement `internal/doctor/doctor.go`**

```go
// Package doctor judges whether this host can do what vmavs does. The
// rules are the shell tree's (lib/preconditions.sh), narrowed to the
// subcommands the Go vmavs has.
package doctor

import (
	"fmt"
	"os"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/manifest"
)

// Host is everything doctor reads from the machine, so that tests can
// describe a machine instead of depending on the one they run on.
type Host struct {
	GOOS     string
	ReadFile func(string) ([]byte, error)
	Exists   func(string) bool
	Writable func(string) bool
	LookPath func(string) (string, error)
}

type Row struct{ Status, Check, Detail string }

type Readiness struct {
	Subcommand string
	Missing    []string
	Notes      []string
}

func (r Readiness) Ready() bool { return len(r.Missing) == 0 }

func HostRows(h Host) []Row {
	if h.GOOS != "linux" {
		return []Row{{"UNKNOWN", "accelerator",
			fmt.Sprintf("never probed on %s by this project -- see docs/test-hosts.md", h.GOOS)}}
	}
	var rows []Row
	info, _ := h.ReadFile("/proc/cpuinfo")
	vendor, flags := cpuinfo(string(info))
	switch vendor {
	case "GenuineIntel":
		rows = append(rows, Row{"PASS", "cpu-vendor", "Intel: the documented KVM path"})
	case "AuthenticAMD":
		rows = append(rows, Row{"FAIL", "cpu-vendor", "AMD is a known-harder case for macOS guests; stop and ask"})
	default:
		rows = append(rows, Row{"FAIL", "cpu-vendor", "unrecognised CPU vendor: " + vendor})
	}
	if strings.Contains(" "+flags+" ", " vmx ") {
		rows = append(rows, Row{"PASS", "vmx", "VT-x present"})
	} else {
		rows = append(rows, Row{"FAIL", "vmx", "no VT-x; KVM acceleration unavailable"})
	}
	switch {
	case h.Writable("/dev/kvm"):
		rows = append(rows, Row{"PASS", "kvm-device", "/dev/kvm is writable by this user"})
	case h.Exists("/dev/kvm"):
		rows = append(rows, Row{"FAIL", "kvm-device", "/dev/kvm exists but is not writable; is this user in group kvm?"})
	default:
		rows = append(rows, Row{"FAIL", "kvm-device", "/dev/kvm does not exist"})
	}
	msrs, err := h.ReadFile("/sys/module/kvm/parameters/ignore_msrs")
	if v := strings.TrimSpace(string(msrs)); err == nil && v == "Y" {
		rows = append(rows, Row{"PASS", "ignore-msrs", "kvm.ignore_msrs is enabled"})
	} else {
		rows = append(rows, Row{"WARN", "ignore-msrs", fmt.Sprintf("kvm.ignore_msrs is %q; prior art requires it. "+
			"Needs root: echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs", v)})
	}
	return rows
}

func cpuinfo(s string) (vendor, flags string) {
	for _, line := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "vendor_id":
			if vendor == "" {
				vendor = strings.TrimSpace(v)
			}
		case "flags":
			if flags == "" {
				flags = strings.TrimSpace(v)
			}
		}
	}
	return vendor, flags
}

func Subcommands(h Host, p config.Paths, qemu string) []Readiness {
	run := Readiness{Subcommand: "run"}
	for _, t := range []string{qemu, "qemu-img"} {
		if _, err := h.LookPath(t); err != nil {
			run.Missing = append(run.Missing, t)
		}
	}
	if ms, _ := manifest.List(p.Images()); len(ms) == 0 {
		run.Missing = append(run.Missing, "a built image (vmavs image)")
	}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), p.OpenCoreImage()} {
		if _, err := os.Stat(f); err != nil {
			run.Missing = append(run.Missing, f)
		}
	}
	emit := Readiness{Subcommand: "emit"}
	if _, err := h.LookPath("packer"); err != nil {
		emit.Notes = append(emit.Notes, "--check needs packer on PATH")
	}
	return []Readiness{run, {Subcommand: "ssh"}, emit}
}

func Verdict(host []Row, subs []Readiness) (bool, string) {
	var ready, blocked []string
	runReady := false
	for _, s := range subs {
		if s.Ready() {
			ready = append(ready, s.Subcommand)
			runReady = runReady || s.Subcommand == "run"
		} else {
			blocked = append(blocked, fmt.Sprintf("%s (missing: %s)", s.Subcommand, strings.Join(s.Missing, ", ")))
		}
	}
	hostOK := true
	for _, r := range host {
		hostOK = hostOK && r.Status != "FAIL"
	}
	ok := hostOK && runReady
	word := "GO"
	if !ok {
		word = "NO-GO"
	}
	line := fmt.Sprintf("%s -- ready: %s", word, strings.Join(ready, " "))
	if len(blocked) > 0 {
		line += "; blocked: " + strings.Join(blocked, "; ")
	}
	return ok, line
}
```

- [ ] **Step 3: Implement `internal/cli/doctor.go`; add the table row (first)**

```go
package cli

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"syscall"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/doctor"
)

const doctorHelp = `usage: vmavs doctor

What this host can do, subcommand by subcommand, and why. Exits 0 when
"vmavs run" can boot a built image here, and 1 otherwise.
`

func cmdDoctor(_ context.Context, e *Env, args []string) error {
	fs := newFlags("doctor")
	if err := parse(fs, e, doctorHelp, args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usagef("doctor takes no arguments")
	}
	p, err := paths(e)
	if err != nil {
		return err
	}
	r := runner(e)
	h := doctor.Host{
		GOOS:     runtime.GOOS,
		ReadFile: os.ReadFile,
		Exists:   config.Exists,
		Writable: func(path string) bool { return syscall.Access(path, 2) == nil }, // 2 is W_OK
		LookPath: r.LookPath,
	}
	rows := doctor.HostRows(h)
	fmt.Fprintf(e.Stdout, "%-8s  %-12s  %s\n", "STATUS", "CHECK", "DETAIL")
	for _, row := range rows {
		fmt.Fprintf(e.Stdout, "%-8s  %-12s  %s\n", row.Status, row.Check, row.Detail)
	}
	subs := doctor.Subcommands(h, p, config.QEMU(e.Getenv))
	fmt.Fprintf(e.Stdout, "\n%-8s  %-12s  %s\n", "STATUS", "SUBCOMMAND", "DETAIL")
	for _, s := range subs {
		status, detail := "READY", "-"
		if !s.Ready() {
			status, detail = "BLOCKED", fmt.Sprintf("missing: %v", s.Missing)
		}
		fmt.Fprintf(e.Stdout, "%-8s  %-12s  %s\n", status, s.Subcommand, detail)
		for _, n := range s.Notes {
			fmt.Fprintf(e.Stdout, "%-8s  %-12s  %s\n", "", "", "note: "+n)
		}
	}
	if hint := config.LegacyHint(e.Getenv, config.Exists); hint != "" {
		fmt.Fprintf(e.Stdout, "\nnote: %s\n", hint)
	}
	ok, line := doctor.Verdict(rows, subs)
	logf(e, "doctor", "%s", line)
	if !ok {
		return &ExitError{Code: 1}
	}
	return nil
}

```

Add to `commandTable()` as the first row:
`{"doctor", "What this host can do, subcommand by subcommand", cmdDoctor},`

- [ ] **Step 4: Run everything; try it on this host; commit**

```bash
go test ./... && go vet ./... && go run honnef.co/go/tools/cmd/staticcheck@2026.2.1 ./...
go build -o out/vmavs ./cmd/vmavs
./out/vmavs doctor; echo "exit $?"
VMAVS_HOME=$HOME/.local/share/mavericks-qemu-guest ./out/vmavs doctor; echo "exit $?"
```

Expected on this host:
- the first run shows the legacy-home note, NO-GO, exit 1 (no images in
  `~/.local/share/vmavs`);
- the second shows `run` READY and GO, if this host's rows pass.

Paste both outputs into the task report.

```bash
git add internal/doctor internal/cli
git commit   # subject: "vmavs doctor: the host, the run subcommand, and a verdict that follows them"
```

---

### Task 9: Measure it, and say so

**Files:**
- Modify: `NOTES.md` (append only), `README.md` (a new section), `docs/superpowers/specs/2026-09-17-mavericks-guest-design.md` (the P8 row, only if the measurement succeeds)

This task boots real VMs on this host. Run only the commands below. Stop
every VM you start before finishing, and leave no `run/` directory
behind.

- [ ] **Step 1: Build, and boot the current shell-built image**

```bash
go build -o out/vmavs ./cmd/vmavs
export VMAVS_HOME=$HOME/.local/share/mavericks-qemu-guest
./out/vmavs run --image mavericks-20260922 > /tmp/vmavs-run.log 2>&1 &
RUN=$!
for i in $(seq 1 60); do ./out/vmavs ssh -- sw_vers -productVersion 2>/dev/null && break; sleep 10; done
./out/vmavs ssh -- sw_vers
./out/vmavs ssh -- uname -a
kill -TERM $RUN; wait $RUN; echo "run exit $?"
ls "$VMAVS_HOME/run" 2>/dev/null
```

Expected:
- `sw_vers` reports `10.9.5`, within about 10 minutes;
- `run` exits 0 after SIGTERM;
- `run/` is empty or absent.

- [ ] **Step 2: The legacy path: an image with Apple's OpenSSH 6.2**

Repeat Step 1 with `--image mavericks-a`. Its manifest has no `openssh`
line and no `nic` line, so `run` boots it with `usb-net`, and `ssh` uses
the legacy algorithms. Record the result whichever way it goes. If it
fails, that is a finding. Record the exact error; do not paper over it.

- [ ] **Step 3: The interactive shell (manual)**

Run `./out/vmavs run --image mavericks-20260922 &` and wait. Then run
`./out/vmavs ssh` in a real terminal, run `sw_vers; exit`, and stop the
VM. If no terminal is available to the executor, write "not measured: no
TTY" in NOTES.md. Do not claim it.

- [ ] **Step 4: Append the NOTES.md entry**

Append a dated entry in NOTES.md's existing format and voice:
`## 2026-09-24 — P8 — the Go vmavs boots a built image and answers SSH`.
It contains:
- the commands, and the exact output of `sw_vers`;
- how long `run` took to reach SSH;
- the legacy result;
- whether the interactive shell was measured.

Label each claim MEASURED. Name what was not measured.

- [ ] **Step 5: README and spec**

- **README.md.** Add a section **"The Go vmavs (in progress)"** after the
  quickstart:
  - how to build it (`go build -o out/vmavs ./cmd/vmavs`);
  - that `run`, `ssh`, `emit packer`, `doctor` and `version` exist;
  - `VMAVS_HOME=~/.local/share/mavericks-qemu-guest` to boot images the
    shell pipeline built;
  - that the rest is still `bin/vmavs` until phase 6 of the spec, which it
    links.

  Keep the existing README tests green (`bats tests/release.bats`).
- **The spec's P8 row.** Only if Step 1 succeeded, change "exit not met"
  to say the exit is met by the Go `vmavs run` + `vmavs ssh`, MEASURED on
  2026-09-24 against a shell-built image, and name the NOTES.md entry.
  Otherwise leave it and say why in the report.

- [ ] **Step 6: Run everything; commit**

```bash
go test ./... && ./bin/run-tests.sh >/tmp/suite.log 2>&1; echo "shell suite exit $?"
git add NOTES.md README.md docs/superpowers/specs/2026-09-17-mavericks-guest-design.md
git commit   # subject: "NOTES: the Go vmavs boots a built image and answers SSH"
```

---

## Self-review

**Spec coverage (Phase 1 row of spec §9):**

| Spec requirement | Covered by |
|---|---|
| skeleton | Task 1 |
| `cli`, `config` | Tasks 1–2 |
| `run` (as `proc`) | Task 3 |
| `machine` (§4) | Task 3 |
| `vmavs run` (§5) | Task 5 |
| `vmavs ssh` (§5, legacy algorithms) | Tasks 4 and 6 |
| `emit packer` (§4, hclwrite) | Task 7 |
| `doctor` | Task 8 |
| `version` | Task 1 |
| the `go` CI job (§8) | Task 1 |
| `packer-validate` switch (§8) | Task 7 |
| shell-built images booting in phases 1–5 (§5) | `OpenCoreImage` fallback in Task 2, used in Task 5 |
| the legacy-home message (§5) | Task 2, surfaced in Tasks 5 and 8 |
| MEASURED discipline (§10, for what phase 1 can measure) | Task 9 |

The package names and dependencies that differ from spec §3 are amended in
Task 1, Step 9.

**Out of phase:** `fetch`, `firmware`, `media`, `install`, `image`,
`assets/` and locks. These are phases 2–5; no task here touches them.

**Types.**
- `config.Machine` fields are used consistently in `machine.Spec` (by
  embedding), `manifest.Hardware`, `cli/run.go` and `emit.Packer`.
- `proc.Runner` has two methods everywhere.
- `vm.State` fields match what `cli/ssh.go` reads.
- `emit.Variables` names match the `-var` names in `packerValidate` and
  the test.
