package vm

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
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

	removed, err := Reap(p)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(removed, deadGone.Dir) {
		t.Fatalf("removed=%v, want %q in it", removed, deadGone.Dir)
	}
	if _, err := os.Stat(deadGone.Dir); !os.IsNotExist(err) {
		t.Fatal("a dead non-keep run's directory must be gone after Reap")
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

// TestReapDoesNotRemoveALockedButEmptyStateFile guards the window Prepare
// now closes by locking before writing: a state file that exists but has
// not been written to yet is still a live run (locked), not an abandoned
// one, and Reap must not delete it out from under the Prepare that is
// still running.
func TestReapDoesNotRemoveALockedButEmptyStateFile(t *testing.T) {
	p, _ := home(t)
	if err := os.MkdirAll(p.Run(), 0o755); err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp(p.Run(), "img-")
	if err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(dir, "state")
	sf, err := os.OpenFile(statePath, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer sf.Close()
	if err := syscall.Flock(int(sf.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}

	removed, err := Reap(p)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(removed, dir) {
		t.Fatalf("removed a locked-but-empty (mid-Prepare) run: %v", removed)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("a locked-but-empty run directory must survive Reap")
	}
}

// TestBootHandsQEMUTheLockedStateFile guards against a SIGKILLed vmavs
// releasing the lock while QEMU keeps running: Boot must pass the state
// file through as an inherited fd, so QEMU's own copy of the open file
// description keeps the flock held even once vmavs's is gone.
func TestBootHandsQEMUTheLockedStateFile(t *testing.T) {
	p, m := home(t)
	r, err := Prepare(context.Background(), &proc.Fake{}, p, m, m.Hardware(), "q", 4242, false)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Remove()
	f := &proc.Fake{}
	if err := r.Boot(context.Background(), f, nil, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	if len(f.Calls) != 1 || len(f.Calls[0].ExtraFiles) != 1 {
		t.Fatalf("calls=%+v, want the state file passed through ExtraFiles", f.Calls)
	}
}

// oldDir makes dir under run/, with a file inside and an mtime well in
// the past: the shape the old Reap mistook for an abandoned run.
func oldDir(t *testing.T, p config.Paths, name string, files map[string]string) string {
	t.Helper()
	dir := filepath.Join(p.Run(), name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for f, content := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-24 * time.Hour)
	os.Chtimes(dir, old, old)
	return dir
}

// TestReapLeavesDirectoriesItCannotProveAreDeadVmavsRuns guards against
// Reap deleting something vmavs never created (with VMAVS_HOME=/, run/ is
// /run): only a directory whose state file Reap could lock, parse, and
// read keep=false from is a dead vmavs run.
func TestReapLeavesDirectoriesItCannotProveAreDeadVmavsRuns(t *testing.T) {
	p, _ := home(t)
	foreign := oldDir(t, p, "someone-elses", map[string]string{"precious": "data"})
	garbage := oldDir(t, p, "img-garbage", map[string]string{"state": "not a vmavs state file\n"})

	removed, err := Reap(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{foreign, garbage} {
		if slices.Contains(removed, dir) {
			t.Fatalf("removed %s: %v", dir, removed)
		}
		if _, err := os.Stat(dir); err != nil {
			t.Fatalf("%s must survive Reap: %v", dir, err)
		}
	}
	if _, err := os.Stat(filepath.Join(foreign, "precious")); err != nil {
		t.Fatal("a directory vmavs did not create must keep its contents")
	}
}

// TestReapLeavesARunWhoseLockCannotBeProbed guards against a failed lock
// probe being read as "dead": a parseable keep=false state file that Reap
// cannot open to probe (here, read-only to this user) may belong to a
// live run, so it survives.
func TestReapLeavesARunWhoseLockCannotBeProbed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens a read-only file for writing anyway")
	}
	p, _ := home(t)
	dir := oldDir(t, p, "img-unprobeable", map[string]string{"state": "image\timg\nport\t2222\npid\t1\nkeep\tfalse\n"})
	if err := os.Chmod(filepath.Join(dir, "state"), 0o444); err != nil {
		t.Fatal(err)
	}
	if _, err := locked(filepath.Join(dir, "state")); err == nil {
		t.Fatal("test setup: the lock probe was meant to fail")
	}
	removed, err := Reap(p)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(removed, dir) {
		t.Fatalf("removed a run whose lock probe failed: %v", removed)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("a run whose lock probe failed must survive Reap")
	}
}

// TestPrepareLocksTheStateFileBeforeAnythingElse: every run directory
// vmavs creates has a locked, parseable state file from before its first
// slow step (qemu-img), so Reap never needs to guess about one that lacks
// it.
func TestPrepareLocksTheStateFileBeforeAnythingElse(t *testing.T) {
	p, m := home(t)
	checked := false
	f := &proc.Fake{Handle: func(c proc.Cmd) error {
		if c.Name != "qemu-img" {
			return nil
		}
		dirs, _ := filepath.Glob(filepath.Join(p.Run(), "img-*", "state"))
		if len(dirs) != 1 {
			t.Errorf("state files during qemu-img: %v, want exactly one", dirs)
			return nil
		}
		if held, err := locked(dirs[0]); err != nil || !held {
			t.Errorf("state not locked during qemu-img: held=%v err=%v", held, err)
		}
		if _, err := readState(dirs[0]); err != nil {
			t.Errorf("state not written before qemu-img: %v", err)
		}
		checked = true
		return nil
	}}
	r, err := Prepare(context.Background(), f, p, m, m.Hardware(), "q", 1, false)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Remove()
	if !checked {
		t.Fatal("qemu-img never ran")
	}
}
