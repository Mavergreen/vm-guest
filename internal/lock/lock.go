// Package lock is a build lock that works everywhere vmavs does: a
// directory, created atomically by mkdir, holding the holder's pid. It is
// not flock(2): the lock must be visible to the shell tree's builders
// too, which use exactly this shape (media/build-installer-img.sh), and a
// directory is what OS X's shell tools can take as well. A lock whose
// holder is no longer running is stale, and is taken over rather than
// left to block every later build (spec §5, "Locks").
package lock

import (
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
func Acquire(dir string, pid int) (*Lock, error) {
	l := &Lock{Dir: dir, PID: pid}
	if err := os.Mkdir(dir, 0o755); err != nil {
		if !errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
		}
		holder := readPID(dir)
		if holder > 0 && alive(holder) {
			return nil, fmt.Errorf("pid %d is already building here (lock %s): two builders sharing one image file corrupt it, and each verifies its own page cache and sees nothing wrong -- wait for it, or stop it and remove %s", holder, dir, dir)
		}
		l.TookOver = holder
		if holder == 0 {
			l.TookOver = -1
		}
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("cannot remove the stale lock %s: %w", dir, err)
		}
		if err := os.Mkdir(dir, 0o755); err != nil {
			return nil, fmt.Errorf("cannot create the lock %s: %w", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		_ = os.RemoveAll(dir)
		return nil, fmt.Errorf("cannot write the lock's pid: %w", err)
	}
	return l, nil
}

// Release removes the lock, but only while it is still this holder's: a
// later builder that took it over owns it now.
func (l *Lock) Release() error {
	if got := readPID(l.Dir); got != l.PID {
		return fmt.Errorf("the lock %s is no longer this process's: it names pid %d, not %d; leaving it", l.Dir, got, l.PID)
	}
	return os.RemoveAll(l.Dir)
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
