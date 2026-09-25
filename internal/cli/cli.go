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

	"github.com/Mavergreen/vm-guest/internal/doctor"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// Env is everything a subcommand may touch outside its arguments, so that
// tests can run the whole CLI in-process.
type Env struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
	Getenv func(string) string
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

// runner is e.Runner, or the real one.
func runner(e *Env) proc.Runner {
	if e.Runner != nil {
		return e.Runner
	}
	return proc.Exec{}
}

// logf writes one "vmavs <cmd>: ..." line to stderr.
func logf(e *Env, cmd, format string, a ...any) {
	fmt.Fprintf(e.Stderr, "vmavs %s: %s\n", cmd, fmt.Sprintf(format, a...))
}
