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
