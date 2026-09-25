package lock

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func pidIn(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "pid"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// deadPID is the pid of a process that has exited and been reaped: the
// shell's bats test does the same with `sleep 0 &; wait`.
func deadPID(t *testing.T) int {
	t.Helper()
	c := exec.Command("true")
	if err := c.Start(); err != nil {
		t.Skipf("cannot start true: %v", err)
	}
	pid := c.Process.Pid
	_ = c.Wait()
	return pid
}

func TestAcquireCreatesTheLockAndReleaseRemovesIt(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "out.img.lock")
	l, err := Acquire(dir, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if l.TookOver != 0 {
		t.Errorf("TookOver = %d on a free lock", l.TookOver)
	}
	if got := pidIn(t, dir); got != strconv.Itoa(os.Getpid())+"\n" {
		t.Fatalf("pid file %q", got)
	}
	if err := l.Release(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("lock still there after Release: %v", err)
	}
}

// Two builders over one image file corrupt it, and each verifies its own
// page cache and sees nothing wrong (media/build-installer-img.sh).
func TestASecondBuilderIsRefused(t *testing.T) {
	sleeper := exec.Command("sleep", "30")
	if err := sleeper.Start(); err != nil {
		t.Skipf("cannot start sleep: %v", err)
	}
	defer func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() }()
	holder := sleeper.Process.Pid

	dir := filepath.Join(t.TempDir(), "out.img.lock")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(holder)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := Acquire(dir, os.Getpid())
	if err == nil {
		t.Fatalf("acquired a live holder's lock: %+v", l)
	}
	for _, want := range []string{"pid " + strconv.Itoa(holder), "is already building", dir} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not say %q", err, want)
		}
	}
	// And it must not have touched the holder's lock on its way out.
	if got := pidIn(t, dir); got != strconv.Itoa(holder)+"\n" {
		t.Fatalf("holder's pid file rewritten: %q", got)
	}
}

func TestAStaleLockIsTakenOver(t *testing.T) {
	dead := deadPID(t)
	dir := filepath.Join(t.TempDir(), "out.img.lock")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(dead)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := Acquire(dir, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()
	if l.TookOver != dead {
		t.Errorf("TookOver = %d, want %d", l.TookOver, dead)
	}
	if got := pidIn(t, dir); got != strconv.Itoa(os.Getpid())+"\n" {
		t.Fatalf("pid file %q after takeover", got)
	}
}

// A lock directory with no pid in it is stale too: the shell's
// ${holder:-unknown} case, a builder killed between its mkdir and its
// printf.
func TestALockWithNoPidIsTakenOver(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "out.img.lock")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	l, err := Acquire(dir, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()
	if l.TookOver != -1 {
		t.Errorf("TookOver = %d, want -1 (unknown holder)", l.TookOver)
	}
	if got := pidIn(t, dir); got != strconv.Itoa(os.Getpid())+"\n" {
		t.Fatalf("pid file %q after takeover", got)
	}
}

// A lock taken over by a later builder -- this one was judged stale, or
// someone removed it by hand -- is that builder's now, not ours to remove.
func TestReleaseOnlyRemovesItsOwnLock(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "out.img.lock")
	l, err := Acquire(dir, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	other := os.Getpid() + 1
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(other)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	err = l.Release()
	if err == nil || !strings.Contains(err.Error(), "no longer") {
		t.Fatalf("Release of someone else's lock: err = %v", err)
	}
	if got := pidIn(t, dir); got != strconv.Itoa(other)+"\n" {
		t.Fatalf("the later taker's lock was disturbed: %q", got)
	}
}
