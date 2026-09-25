package vm

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// home builds a VMAVS_HOME the way the shell pipeline leaves it.
func home(t *testing.T) (config.Paths, manifest.Manifest) {
	t.Helper()
	p := config.Paths{Home: t.TempDir()}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), filepath.Join(p.Work(), "opencore-p3.img"),
		filepath.Join(p.Images(), "img.qcow2")} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, []byte("x"), 0o644)
	}
	os.WriteFile(filepath.Join(p.Images(), "img.manifest"), []byte("name\timg\n"), 0o644)
	m, err := manifest.Find(p.Images(), "img")
	if err != nil {
		t.Fatal(err)
	}
	return p, m
}

func TestPrepareMakesAnOverlayAndItsOwnNVRAM(t *testing.T) {
	p, m := home(t)
	f := &proc.Fake{}
	r, err := Prepare(context.Background(), f, p, m, m.Hardware(), "qemu-system-x86_64", 4242)
	if err != nil {
		t.Fatal(err)
	}
	if r.Dir != filepath.Join(p.Run(), "img-4242") {
		t.Fatalf("dir %q", r.Dir)
	}
	create := f.Calls[0].String()
	if !strings.HasPrefix(create, "qemu-img create") || !strings.Contains(create, "-b "+m.Image()) ||
		!strings.Contains(create, "-F qcow2") {
		t.Fatalf("overlay: %s", create)
	}
	if b, _ := os.ReadFile(filepath.Join(r.Dir, "OVMF_VARS.fd")); string(b) != "x" {
		t.Fatal("NVRAM not copied from the template")
	}
	args := r.Spec.Args()
	if !slices.Contains(args, "id=target,if=none,format=qcow2,file="+filepath.Join(r.Dir, "disk.qcow2")) {
		t.Fatalf("boots %q, not the overlay", args)
	}
	if !slices.Contains(args, "id=opencore,if=none,format=raw,snapshot=on,file="+filepath.Join(p.Work(), "opencore-p3.img")) {
		t.Fatal("does not use the shell tree's OpenCore image")
	}
}

func TestPrepareNamesWhatIsMissing(t *testing.T) {
	p, m := home(t)
	os.Remove(p.OVMFCode())
	_, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1)
	if err == nil || !strings.Contains(err.Error(), "OVMF_CODE.fd") {
		t.Fatalf("err = %v", err)
	}
}

func TestLiveFindsThisProcessesRunAndIgnoresDeadOnes(t *testing.T) {
	p, m := home(t)
	if _, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", os.Getpid()); err != nil {
		t.Fatal(err)
	}
	dead := filepath.Join(p.Run(), "img-999999")
	os.MkdirAll(dead, 0o755)
	os.WriteFile(filepath.Join(dead, "state"), []byte("image\timg\nport\t2222\npid\t999999\n"), 0o644)
	live, err := Live(p)
	if err != nil || len(live) != 1 || live[0].PID != os.Getpid() || live[0].Port != 2222 {
		t.Fatalf("live=%+v err=%v", live, err)
	}
}
