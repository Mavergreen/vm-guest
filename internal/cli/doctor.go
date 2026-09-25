package cli

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strings"
	"syscall"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/doctor"
	"github.com/Mavergreen/vm-guest/internal/firmware"
)

const doctorHelp = `usage: vmavs doctor

What this host can do, subcommand by subcommand, and why. Exits 0 when
"vmavs run" can boot a built image here, and 1 otherwise.
`

func cmdDoctor(ctx context.Context, e *Env, args []string) error {
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
	gccBin := e.Getenv("GCC_BIN")
	gcc := gccBin + "gcc"
	h := doctor.Host{
		GOOS:     runtime.GOOS,
		ReadFile: os.ReadFile,
		Exists:   config.Exists,
		Writable: func(path string) bool { return syscall.Access(path, 2) == nil }, // 2 is W_OK
		LookPath: r.LookPath,
		GCCBin:   gccBin,
		// With no gcc on PATH the probe answers true and checks nothing:
		// the missing compiler is already its own row, and "cannot tell"
		// is not "missing". firmware.HeaderCompiles is the same probe
		// firmware's own build runs before unpacking anything.
		Header: func(name string) bool {
			if _, err := r.LookPath(gcc); err != nil {
				return true
			}
			return firmware.HeaderCompiles(ctx, r, gcc, nil, name)
		},
	}
	if e.Host != nil {
		h = *e.Host
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
			status, detail = "BLOCKED", "missing: "+strings.Join(s.Missing, ", ")
		}
		fmt.Fprintf(e.Stdout, "%-8s  %-12s  %s\n", status, s.Subcommand, detail)
		for _, n := range s.Notes {
			fmt.Fprintf(e.Stdout, "%-8s  %-12s  %s\n", "", "", "note: "+n)
		}
	}
	if hint := legacyHint(e); hint != "" {
		fmt.Fprintf(e.Stdout, "\nnote: %s\n", hint)
	}
	ok, line := doctor.Verdict(rows, subs)
	logf(e, "doctor", "%s", line)
	if !ok {
		return &ExitError{Code: 1}
	}
	return nil
}
