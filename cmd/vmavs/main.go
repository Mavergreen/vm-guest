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
	// Ctrl-C, a terminated terminal (SIGHUP) or a plain kill (SIGTERM)
	// all cancel the context: a VM stops, a run directory is cleaned up,
	// and vmavs exits, instead of vmavs dying first (or its terminal
	// disappearing under it) and leaking both. There is no separate
	// reaper process; a run that is not cleaned up this way (a crash, a
	// SIGKILL) is swept up by the next `vmavs run` or `vmavs ssh`
	// (vm.Reap), unless it was started with --keep.
	//
	// SIGHUP is only watched if it isn't already being ignored (as under
	// `nohup`): signal.Notify would otherwise re-enable a signal the
	// parent deliberately ignored. That is all this buys. It does NOT make
	// `nohup vmavs run &` survive its terminal closing: QEMU installs its
	// own SIGHUP handler, so the hangup still stops the VM (and vmavs,
	// with it, exits). Only a run started in its own session (setsid) is
	// out of the hangup's reach. REASONED from QEMU's os-posix.c, whose
	// os_setup_signal_handling catches SIGHUP as it does SIGINT and
	// SIGTERM; not measured here.
	sigs := []os.Signal{os.Interrupt, syscall.SIGTERM}
	if !signal.Ignored(syscall.SIGHUP) {
		sigs = append(sigs, syscall.SIGHUP)
	}
	ctx, stop := signal.NotifyContext(context.Background(), sigs...)
	// Only the first signal is caught: once it has cancelled ctx, stop
	// hands every signal back to its default action, so a second Ctrl-C
	// kills a vmavs that is stuck somewhere a context cannot reach (a
	// read that never returns, say). A run killed this way before it
	// cleaned up is swept up like any other, as above.
	context.AfterFunc(ctx, stop)
	code := cli.Run(ctx, os.Args[1:], &cli.Env{
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Getenv: os.Getenv,
	})
	stop()
	os.Exit(code)
}
