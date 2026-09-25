// Package lock is a build lock that works everywhere vmavs does: a
// directory, created atomically by mkdir, holding the holder's pid. It is
// not flock(2): the lock must be visible to the shell tree's builders
// too, which use exactly this shape (media/build-installer-img.sh), and a
// directory is what OS X's shell tools can take as well. A lock whose
// holder is no longer running is stale, and is taken over rather than
// left to block every later build (spec §5, "Locks").
package lock

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// A Lock is held until Release.
type Lock struct {
	Dir string
	PID int
	// TookOver is the stale holder's pid when Acquire took the lock over,
	// -1 when the stale lock named no pid, and 0 when the lock was free.
	TookOver int
}

// Acquire takes the lock at dir for pid. A lock held by a live process is
// refused, and left exactly as it was.
//
// The lock is never visible without its pid. It is assembled as a
// temporary directory beside dir, pid and all, and renamed onto dir,
// which is atomic: a mkdir-then-write lock is briefly an empty directory,
// which a second builder would judge stale and take over. A stale lock
// is renamed aside to a unique name first, which only one taker can do,
// and removed from there.
//
// That rename is by path, and cannot be made conditional on what is at
// the path: a taker that judged the old lock stale can, a moment later,
// move aside the fresh lock another taker has just put there, and both
// then hold it. So vmavs's own builders also take a flock on the parent
// directory for the few system calls acquisition lasts (serialize). That
// is not the lock -- the shell's builders never see it, and it leaves no
// file behind -- only what makes judging and taking over one step.
func Acquire(dir string, pid int) (*Lock, error) {
	parent, base := filepath.Dir(dir), filepath.Base(dir)
	tmp, err := os.MkdirTemp(parent, "."+base+".tmp-*")
	if err != nil {
		return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
	}
	held := false
	defer func() {
		if !held {
			_ = os.RemoveAll(tmp)
		}
	}()
	if err := os.Chmod(tmp, 0o755); err != nil {
		return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		return nil, fmt.Errorf("cannot write the lock's pid: %w", err)
	}
	l := &Lock{Dir: dir, PID: pid}
	defer serialize(parent)()
	for attempt := 0; attempt < 100; attempt++ {
		if _, err := os.Lstat(dir); errors.Is(err, fs.ErrNotExist) {
			// Rename replaces an empty directory, so dir is checked
			// first: an empty lock is a stale one, and is reported.
			if err := os.Rename(tmp, dir); err == nil {
				held = true
				return l, nil
			} else if !exists(err) {
				return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
			}
			continue // another builder got there first: look again
		} else if err != nil {
			return nil, fmt.Errorf("cannot read the lock %s: %w", dir, err)
		}
		holder := readPID(dir)
		if holder > 0 && alive(holder) {
			return nil, fmt.Errorf("pid %d is already building here (lock %s): two builders sharing one image file corrupt it, and each verifies its own page cache and sees nothing wrong -- wait for it, or stop it and remove %s", holder, dir, dir)
		}
		aside := dir + ".stale-" + randomSuffix()
		if err := os.Rename(dir, aside); err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				continue // another taker moved it first
			}
			return nil, fmt.Errorf("cannot remove the stale lock %s: %w", dir, err)
		}
		l.TookOver = holder
		if holder == 0 {
			l.TookOver = -1
		}
		if err := os.RemoveAll(aside); err != nil {
			return nil, fmt.Errorf("cannot remove the stale lock %s (moved to %s): %w", dir, aside, err)
		}
	}
	return nil, fmt.Errorf("cannot take the lock %s: it kept changing under this builder", dir)
}

// serialize holds an exclusive flock on dir until the returned function
// is called. Where the filesystem refuses flock on a directory (some
// network filesystems do), it holds nothing, and acquisition keeps the
// rename-only protocol, which is still never seen without its pid.
func serialize(dir string) func() {
	f, err := os.Open(dir)
	if err != nil {
		return func() {}
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		f.Close()
		return func() {}
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}
}

// exists is whether a rename failed because its target is already there:
// EEXIST or ENOTEMPTY, which systems use interchangeably for a directory.
func exists(err error) bool {
	return errors.Is(err, fs.ErrExist) || errors.Is(err, syscall.ENOTEMPTY)
}

func randomSuffix() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Release removes the lock, but only while it is still this holder's: a
// later builder that took it over owns it now. The lock is renamed aside
// before it is removed, so that no other builder ever sees it half gone.
func (l *Lock) Release() error {
	if _, err := os.Lstat(l.Dir); errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("the lock %s is gone: something removed it while pid %d held it", l.Dir, l.PID)
	}
	if got := readPID(l.Dir); got != l.PID {
		return fmt.Errorf("the lock %s is no longer this process's: it names pid %d, not %d; leaving it", l.Dir, got, l.PID)
	}
	aside := l.Dir + ".released-" + randomSuffix()
	if err := os.Rename(l.Dir, aside); err != nil {
		return fmt.Errorf("cannot release the lock %s: %w", l.Dir, err)
	}
	return os.RemoveAll(aside)
}

// readPID is the pid the lock names, or 0 when it names none. A pid below
// 1 counts as none: kill(0) and kill(-n) address process groups, and
// would find "a live holder" in any lock whose file said so.
func readPID(dir string) int {
	b, err := os.ReadFile(filepath.Join(dir, "pid"))
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || n < 1 {
		return 0
	}
	return n
}

// alive is kill(pid, 0): EPERM means it exists and is someone else's.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
