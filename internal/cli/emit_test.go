package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

func TestEmitWritesTheTemplate(t *testing.T) {
	out := filepath.Join(t.TempDir(), "m.pkr.hcl")
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": t.TempDir()}, "emit", "packer", "--out", out)
	b, _ := os.ReadFile(out)
	if code != 0 || !strings.Contains(string(b), `source "qemu" "mavericks"`) {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func TestEmitCheckWithoutPackerFailsSayingSo(t *testing.T) {
	out := filepath.Join(t.TempDir(), "m.pkr.hcl")
	code, stderr := runVmavs(t, &proc.Fake{}, map[string]string{"VMAVS_HOME": t.TempDir()}, "emit", "packer", "--out", out, "--check")
	if code != 1 || !strings.Contains(stderr, "packer is not installed") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}

func TestEmitCheckGivesEveryVariableAValueAndARealKey(t *testing.T) {
	out := filepath.Join(t.TempDir(), "m.pkr.hcl")
	var keySeen bool
	f := &proc.Fake{Paths: map[string]string{"packer": "/usr/bin/packer"}, Handle: func(c proc.Cmd) error {
		for _, a := range c.Args {
			if k, ok := strings.CutPrefix(a, "ssh_key="); ok {
				b, err := os.ReadFile(k)
				keySeen = err == nil && strings.Contains(string(b), "OPENSSH PRIVATE KEY")
			}
		}
		return nil
	}}
	code, stderr := runVmavs(t, f, map[string]string{"VMAVS_HOME": t.TempDir()}, "emit", "packer", "--out", out, "--check")
	if code != 0 || !keySeen {
		t.Fatalf("code=%d keySeen=%v stderr=%s", code, keySeen, stderr)
	}
	call := f.Calls[0].String()
	for _, v := range []string{"media=", "ovmf_code=", "ovmf_vars=", "opencore_media=", "ssh_key="} {
		if !strings.Contains(call, "-var "+v) {
			t.Errorf("no -var %s in %s", v, call)
		}
	}
	for _, a := range f.Calls[0].Args {
		if k, ok := strings.CutPrefix(a, "ssh_key="); ok {
			if _, err := os.Stat(k); !errors.Is(err, os.ErrNotExist) {
				t.Error("the placeholder key outlived --check")
			}
		}
	}
}

func TestEmitRefusesAnotherTarget(t *testing.T) {
	code, stderr := runVmavs(t, &proc.Fake{}, nil, "emit", "libvirt")
	if code != 2 || !strings.Contains(stderr, "packer") {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
}
