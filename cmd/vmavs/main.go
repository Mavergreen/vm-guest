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
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	code := cli.Run(ctx, os.Args[1:], &cli.Env{
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Getenv: os.Getenv,
	})
	stop()
	os.Exit(code)
}
