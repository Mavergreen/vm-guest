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
