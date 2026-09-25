package cli

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// shortTempDir is t.TempDir(), but without the test's own name -- often
// long, in this codebase's descriptive test-naming style -- baked into
// the path: a run's monitor socket lives under VMAVS_HOME, and a unix
// socket path has a short, OS-imposed length limit (vm.maxUnixSocketPath).
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "vmavs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// shellHome is a VMAVS_HOME laid out the way the shell pipeline leaves it,
// with one legacy image (usb-net, no openssh line).
func shellHome(t *testing.T) string {
	t.Helper()
	h := shortTempDir(t)
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

// runDirs is whatever is directly under home/run/. A run's directory is
// now named <image>-<random> (vm.Prepare, os.MkdirTemp), not <image>-<pid>,
// so tests that used to check for a specific name instead check how many
// are left, and (when there should be exactly one) look inside it.
func runDirs(t *testing.T, home string) []os.DirEntry {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(home, "run"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return entries
}

// blockingRunner delegates qemu-img (the overlay create step, in
// Prepare) to the Fake it wraps, but the boot command itself (Boot)
// blocks until ctx is cancelled: a stand-in for a long-running QEMU that
// Ctrl-C (or SIGTERM/SIGHUP; cmd/vmavs/main.go) stops.
type blockingRunner struct{ create *proc.Fake }

func (b blockingRunner) Run(ctx context.Context, c proc.Cmd) error {
	if c.Name == "qemu-img" {
		return b.create.Run(ctx, c)
	}
	<-ctx.Done()
	return ctx.Err()
}

func (b blockingRunner) LookPath(name string) (string, error) { return b.create.LookPath(name) }

// freePort is a TCP port free on 127.0.0.1 right now. cmdRun's own
// portFree check means every test that gets as far as vm.Prepare binds a
// real port; the default (2222) is not guaranteed free on the host
// running these tests -- including, per fix round 2, a real machine
// during the phase 9 measurement, where something else may already be
// listening on it.
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func TestRunBootsTheLatestImageOnItsOwnHardwareAndCleansUp(t *testing.T) {
	h := shellHome(t)
	f := &proc.Fake{}
	code, stderr := runVmavs(t, f, map[string]string{"VMAVS_HOME": h}, "run", "--ssh-port", strconv.Itoa(freePort(t)))
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	boot := f.Calls[len(f.Calls)-1].String()
	if !strings.HasPrefix(boot, "qemu-system-x86_64 ") || !strings.Contains(boot, "usb-net,bus=usb.0,netdev=net0") {
		t.Fatalf("boot: %s", boot)
	}
	if dirs := runDirs(t, h); len(dirs) != 0 {
		t.Fatalf("run directory left behind without --keep: %v", dirs)
	}
}

func TestRunKeepAndFlagsWin(t *testing.T) {
	h := shellHome(t)
	f := &proc.Fake{}
	code, _ := runVmavs(t, f, map[string]string{"VMAVS_HOME": h, "VMAVS_QEMU": "/opt/q"},
		"run", "--keep", "--nic", "e1000-82545em", "--memory", "8192", "--ssh-port", strconv.Itoa(freePort(t)))
	if code != 0 {
		t.Fatal(code)
	}
	boot := f.Calls[len(f.Calls)-1].String()
	if !strings.HasPrefix(boot, "/opt/q ") || !strings.Contains(boot, "e1000-82545em,netdev=net0") || !strings.Contains(boot, "-m 8192") {
		t.Fatalf("boot: %s", boot)
	}
	dirs := runDirs(t, h)
	if len(dirs) != 1 {
		t.Fatalf("--keep must keep exactly one run directory, got %v", dirs)
	}
	if _, err := os.Stat(filepath.Join(h, "run", dirs[0].Name(), "OVMF_VARS.fd")); err != nil {
		t.Fatal("--keep must keep the run directory's contents")
	}
}

func TestRunWithNoImagesGivesTheLegacyHint(t *testing.T) {
	home := shortTempDir(t)
	os.MkdirAll(filepath.Join(home, ".local", "share", "mavericks-qemu-guest"), 0o755)
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"HOME": home}, "run")
	if code != 1 || !strings.Contains(stderr, "export VMAVS_HOME=") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

// TestRunWithNoImagesNamesACommandThatExists: out/vmavs has no `image`
// subcommand yet, so pointing at `vmavs image` sends a user to one that
// fails.
func TestRunWithNoImagesNamesACommandThatExists(t *testing.T) {
	home := shortTempDir(t)
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": home}, "run")
	if code != 1 || !strings.Contains(stderr, "bin/vmavs image (until it is ported)") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func TestRunStopsCleanlyWhenCtxIsCancelled(t *testing.T) {
	h := shellHome(t)
	br := blockingRunner{create: &proc.Fake{}}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	var out, errb bytes.Buffer
	e := &Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Getenv: func(k string) string { return map[string]string{"VMAVS_HOME": h}[k] }, Runner: br, PID: 777}
	code := Run(ctx, []string{"run", "--ssh-port", strconv.Itoa(freePort(t))}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if !strings.Contains(errb.String(), "stopped") {
		t.Fatalf("stderr=%s, want it to log \"stopped\"", errb.String())
	}
	if dirs := runDirs(t, h); len(dirs) != 0 {
		t.Fatalf("run directory left behind after Ctrl-C: %v", dirs)
	}
}

func TestRunRemovesTheDirEvenWhenBootFails(t *testing.T) {
	h := shellHome(t)
	f := &proc.Fake{Handle: func(c proc.Cmd) error {
		if c.Name == "qemu-img" {
			return nil
		}
		return errors.New("boom")
	}}
	code, stderr := runVmavs(t, f, map[string]string{"VMAVS_HOME": h}, "run", "--ssh-port", strconv.Itoa(freePort(t)))
	if code != 1 || !strings.Contains(stderr, "boom") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	if dirs := runDirs(t, h); len(dirs) != 0 {
		t.Fatalf("run directory left behind after a boot failure: %v", dirs)
	}
}

func TestRunRefusesAnInUseSSHPort(t *testing.T) {
	h := shellHome(t)
	ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(config.DefaultSSHPort))
	if err != nil {
		t.Skipf("port %d unavailable in this environment: %v", config.DefaultSSHPort, err)
	}
	defer ln.Close()
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": h}, "run")
	if code != 1 || !strings.Contains(stderr, "in use") || !strings.Contains(stderr, "--ssh-port") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func TestRunReapsStaleRunDirectoriesFirst(t *testing.T) {
	h := shellHome(t)
	p := config.Paths{Home: h}
	stale := filepath.Join(p.Run(), "old-stale")
	os.MkdirAll(stale, 0o755)
	os.WriteFile(filepath.Join(stale, "state"), []byte("image\told\nport\t2222\npid\t1\nkeep\tfalse\n"), 0o644)
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": h}, "run", "--ssh-port", strconv.Itoa(freePort(t)))
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stderr, "removed stale run directory") || !strings.Contains(stderr, "old-stale") {
		t.Fatalf("stderr=%s, want it to log the removed stale run directory", stderr)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale run directory not reaped")
	}
}
