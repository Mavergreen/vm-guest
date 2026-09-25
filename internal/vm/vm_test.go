package vm

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

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
	r, err := Prepare(context.Background(), f, p, m, m.Hardware(), "qemu-system-x86_64", 4242, false)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Remove()
	if filepath.Dir(r.Dir) != p.Run() || !strings.HasPrefix(filepath.Base(r.Dir), "img-") {
		t.Fatalf("dir %q", r.Dir)
	}
	create := f.Calls[0].String()
	if !strings.HasPrefix(create, "qemu-img create") || !strings.Contains(create, "-b "+m.Image()) ||
		!strings.Contains(create, "-F qcow2") || !filepath.IsAbs(m.Image()) {
		t.Fatalf("overlay: %s (backing path must be absolute: a relative one, baked into the "+
			"overlay, breaks as soon as the working directory changes)", create)
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
	_, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1, false)
	if err == nil || !strings.Contains(err.Error(), "OVMF_CODE.fd") {
		t.Fatalf("err = %v", err)
	}
}

func TestPrepareGivesEachRunItsOwnDirectory(t *testing.T) {
	p, m := home(t)
	r1, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1, false)
	if err != nil {
		t.Fatal(err)
	}
	defer r1.Remove()
	r2, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1, false)
	if err != nil {
		t.Fatal(err)
	}
	defer r2.Remove()
	if r1.Dir == r2.Dir {
		t.Fatalf("two runs of the same image and pid got the same directory %q "+
			"(a recycled pid used to clobber a --keep run)", r1.Dir)
	}
}

func TestPrepareRejectsATooLongMonitorPath(t *testing.T) {
	base := t.TempDir()
	p := config.Paths{Home: filepath.Join(base, strings.Repeat("x", maxUnixSocketPath))}
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
	_, err = Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1, false)
	if err == nil || !strings.Contains(err.Error(), "monitor socket path") || !strings.Contains(err.Error(), "VMAVS_HOME") {
		t.Fatalf("err = %v", err)
	}
}

func TestPrepareWritesImagePortAndKeepToState(t *testing.T) {
	p, m := home(t)
	r, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 4242, true)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Remove()
	b, err := os.ReadFile(filepath.Join(r.Dir, "state"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if !strings.Contains(s, "image\timg\n") || !strings.Contains(s, "port\t2222\n") ||
		!strings.Contains(s, "pid\t4242\n") || !strings.Contains(s, "keep\ttrue\n") {
		t.Fatalf("state = %q", s)
	}
}

func TestLiveSeesAHeldRunAndNotOneWhoseLockWasReleased(t *testing.T) {
	p, m := home(t)
	r, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 4242, false)
	if err != nil {
		t.Fatal(err)
	}
	live, err := Live(p)
	if err != nil || len(live) != 1 || live[0].Dir != r.Dir || live[0].Image != "img" || live[0].Port != 2222 {
		t.Fatalf("live=%+v err=%v", live, err)
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	live, err = Live(p)
	if err != nil || len(live) != 0 {
		t.Fatalf("after Close, live=%+v err=%v", live, err)
	}
}

func TestReapRemovesDeadNonKeepRunsAndKeepsTheRest(t *testing.T) {
	p, m := home(t)

	live, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 1, false)
	if err != nil {
		t.Fatal(err)
	}
	defer live.Remove()

	deadKeep, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 2, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := deadKeep.Close(); err != nil {
		t.Fatal(err)
	}

	deadGone, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 3, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := deadGone.Close(); err != nil {
		t.Fatal(err)
	}

	half := filepath.Join(p.Run(), "img-half")
	os.MkdirAll(half, 0o755)
	old := time.Now().Add(-2 * reapStaleAge)
	os.Chtimes(half, old, old)

	removed, err := Reap(p)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(removed, deadGone.Dir) || !slices.Contains(removed, half) {
		t.Fatalf("removed=%v, want %q and %q in it", removed, deadGone.Dir, half)
	}
	if slices.Contains(removed, live.Dir) {
		t.Fatalf("removed a live run: %v", removed)
	}
	if slices.Contains(removed, deadKeep.Dir) {
		t.Fatalf("removed a dead --keep run: %v", removed)
	}
	if _, err := os.Stat(deadKeep.Dir); err != nil {
		t.Fatal("a dead --keep run's directory must survive Reap")
	}
	if _, err := os.Stat(live.Dir); err != nil {
		t.Fatal("a live run's directory must survive Reap")
	}
}
