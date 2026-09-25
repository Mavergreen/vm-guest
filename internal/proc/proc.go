// Package proc is the one way vmavs runs another program, so that every
// command can be tested with a fake that records what would have run.
package proc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
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
	// ExtraFiles are inherited by the child starting at fd 3, the way
	// os/exec.Cmd.ExtraFiles works. vm.Run.Boot uses this to hand QEMU
	// the run's own locked state file: an inherited fd keeps the flock
	// held for as long as QEMU runs, even if vmavs itself is killed
	// before it can release it deliberately.
	ExtraFiles []*os.File
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
	cmd.ExtraFiles = c.ExtraFiles
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
