// Package cli is vmavs's command line: the subcommand table, flag
// parsing, help, logging and exit codes. It owns argv and the command
// table, and reads the environment for the packages it calls, which take
// plain values. cli is the only package that knows about flags or argv:
// config owns the defaults a machine-using subcommand's flags start from
// (registerMachine binds them to a FlagSet cli hands it).
package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"slices"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/doctor"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/pins"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// Env is everything a subcommand may touch outside its arguments, so that
// tests can run the whole CLI in-process.
type Env struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
	Getenv func(string) string
	// Environ is the environment children inherit (the firmware builds
	// add to it). nil means os.Environ.
	Environ func() []string
	// Runner runs external commands. A nil Runner means the real one.
	Runner proc.Runner
	// PID is the pid run records in a run's state file, for a person
	// reading it. Nothing decides anything by it: a run directory is
	// named by os.MkdirTemp, and liveness is the state file's lock. Zero
	// means os.Getpid().
	PID int
	// Host is what cmdDoctor probes for host facts. nil means the real
	// host (runtime.GOOS, os.ReadFile, syscall.Access, ...); a test gives
	// it a fake doctor.Host so it can describe a machine instead of
	// depending on the one the test runs on.
	Host *doctor.Host

	// HTTP is what cmdFetch downloads with. nil means http.DefaultClient
	// (in this package's tests, a client that refuses non-loopback hosts).
	HTTP *http.Client
	// Endpoints is where cmdFetch reaches osrecovery and the OpenSSH
	// releases. nil means the real ones (fetch.DefaultRecovery,
	// fetch.DefaultOpenSSHReleases); a test points both at httptest servers.
	Endpoints *Endpoints
	// Registry is the source registry cmdFetch verifies downloads
	// against. nil means the one embedded in this binary (pins.Embedded).
	Registry *pins.Registry
}

type command struct {
	name    string
	summary string
	run     func(ctx context.Context, e *Env, args []string) error
}

// commandTable is every subcommand, in the order help lists them.
func commandTable() []command {
	return []command{
		{"doctor", "What this host can do, subcommand by subcommand", cmdDoctor},
		{"fetch", "Fetch and verify the pinned inputs (Apple's installer, updates, OpenSSH)", cmdFetch},
		{"firmware", "Build OpenCore, OVMF and the OpenCore EFI image from pinned source", cmdFirmware},
		{"run", "Boot a built image on a throwaway overlay", cmdRun},
		{"ssh", "Open a shell in the running guest", cmdSSH},
		{"emit", "Write a Packer template for this machine", cmdEmit},
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

// defaultHTTP is what an Env without HTTP downloads with. Only this
// package's tests change it: to a client that refuses every host but
// loopback, so no test can reach the internet.
var defaultHTTP = http.DefaultClient

// httpClient is e.HTTP, or defaultHTTP.
func httpClient(e *Env) *http.Client {
	if e.HTTP != nil {
		return e.HTTP
	}
	return defaultHTTP
}

// runner is e.Runner, or the real one.
func runner(e *Env) proc.Runner {
	if e.Runner != nil {
		return e.Runner
	}
	return proc.Exec{}
}

// environ is e.Environ(), or os.Environ(): what the firmware builds hand
// their external tools as the whole environment (proc.Cmd.Env).
func environ(e *Env) []string {
	if e.Environ != nil {
		return e.Environ()
	}
	return os.Environ()
}

// parseInterleaved lets targets and flags appear in either order (a
// command's usage puts a target first: "vmavs fetch updates --updates
// none", or "vmavs firmware efi --smbios MacPro5,1"), which
// flag.FlagSet.Parse does not support on its own -- it stops permanently
// at the first non-flag argument. Instead this parses repeatedly: fs.Parse
// consumes a run of flags (deciding for itself, the standard way, which
// take a value -- including "--updates X", "--updates=X" and "-updates
// X"), then the first remaining argument is taken as one target and
// parsing resumes on the rest. Every flag's variable ends up set exactly
// as a single fs.Parse(args) would have set it, since flag.FlagSet
// accumulates across repeated Parse calls on the same FlagSet.
//
// "--" ends flag parsing for good: fs.Parse consumes it and stops, and
// every argument after it is a plain target, never looked at as a flag
// again even if it starts with "-" (so `-- esd --probe` names an unknown
// target, "--probe"). fs.Parse stopped at a "--" when that is the last
// argument it consumed. The one look-alike is "--" given as a flag's
// value ("--updates --"), and --updates refuses that value anyway.
func parseInterleaved(fs *flag.FlagSet, e *Env, help string, args []string) ([]string, error) {
	var targets []string
	remaining := args
	for {
		if err := parse(fs, e, help, remaining); err != nil {
			return nil, err
		}
		consumed := len(remaining) - fs.NArg()
		if consumed > 0 && remaining[consumed-1] == "--" {
			return append(targets, fs.Args()...), nil
		}
		if fs.NArg() == 0 {
			return targets, nil
		}
		targets = append(targets, fs.Arg(0))
		remaining = fs.Args()[1:]
	}
}

// orderedTargets validates args against order and returns the requested
// targets, deduplicated, in order's own order regardless of the order
// they were named in: every one of order when args is empty (spec §2:
// "all of" them), an error otherwise naming cmd and every choice.
//
// A repeated target ("esd esd") is not an error: naming the same target
// twice is redundant, not contradictory, and each target already runs at
// most once regardless of how many times it appears.
func orderedTargets(cmd string, args, order []string) ([]string, error) {
	if len(args) == 0 {
		return order, nil
	}
	want := map[string]bool{}
	for _, a := range args {
		if !slices.Contains(order, a) {
			return nil, usagef("unknown %s target %q: choose from %s", cmd, a, strings.Join(order, ", "))
		}
		want[a] = true
	}
	var out []string
	for _, t := range order {
		if want[t] {
			out = append(out, t)
		}
	}
	return out, nil
}

// logf writes one "vmavs <cmd>: ..." line to stderr.
func logf(e *Env, cmd, format string, a ...any) {
	fmt.Fprintf(e.Stderr, "vmavs %s: %s\n", cmd, fmt.Sprintf(format, a...))
}

// legacyHint is config.LegacyHint on the real filesystem: "" unless the
// shell tree's home holds the only built images.
func legacyHint(e *Env) string {
	return config.LegacyHint(e.Getenv, manifest.Any, config.Exists)
}

// fetchLegacyHint is legacyHint as fetch gives it: the export advice
// only, never the mv. A fetch that stores anything creates the default
// home, and once that exists moving the old home over it is stale advice
// (it may hold hard links into the old home) -- so fetch asks as if it
// already did.
func fetchLegacyHint(e *Env) string {
	return config.LegacyHint(e.Getenv, manifest.Any, func(string) bool { return true })
}
