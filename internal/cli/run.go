package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"

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
	// flagged is the defaults with only the given flags changed, so this
	// checks exactly what was typed: a flag mistake is a usage error
	// whatever VMAVS_HOME holds, reported before anything looks there.
	if err := flagged.Validate(); err != nil {
		return usagef("%v", err)
	}
	p, err := paths(e)
	if err != nil {
		return err
	}
	reap(e, "run", p)
	m, err := chooseImage(e, p, *name)
	if err != nil {
		return err
	}
	hw := m.Hardware()
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	hw.Override(flagged, func(n string) bool { return set[n] })
	if err := hw.Validate(); err != nil {
		return fmt.Errorf("image %s: %w", m.Name, err)
	}
	if err := portFree(hw.SSHPort); err != nil {
		return err
	}
	pid := e.PID
	if pid == 0 {
		pid = os.Getpid()
	}
	r := runner(e)
	run, err := vm.Prepare(ctx, r, p, m, hw, config.QEMU(e.Getenv), pid, *keep)
	if err != nil {
		return err
	}
	if !*keep {
		defer func() {
			if err := run.Remove(); err != nil {
				logf(e, "run", "cleanup: %v", err)
			}
		}()
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

// reap removes stale run directories before doing anything else with
// run/, and logs each one it removed. It is best-effort: a failure here
// (an unreadable run/, say) does not stop the subcommand.
func reap(e *Env, cmd string, p config.Paths) {
	removed, err := vm.Reap(p)
	if err != nil {
		return
	}
	for _, dir := range removed {
		logf(e, cmd, "removed stale run directory %s", dir)
	}
}

// portFree reports an error naming port if something is already
// listening on it: two runs racing for the same forwarded port otherwise
// fail with whatever confusing thing QEMU's hostfwd does instead.
func portFree(port int) error {
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return fmt.Errorf("port %d is in use (another vmavs run?); pick another with --ssh-port", port)
	}
	return ln.Close()
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
		msg := fmt.Sprintf("no built images in %s; build one with bin/vmavs image (until it is ported)", p.Images())
		if hint := config.LegacyHint(e.Getenv, config.Exists); hint != "" {
			msg += "\n" + hint
		}
		return manifest.Manifest{}, errors.New(msg)
	}
	return all[0], nil
}
