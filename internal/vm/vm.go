// Package vm prepares, boots and cleans up a run of a built image: a
// throwaway overlay, its own NVRAM, and a state file that `vmavs ssh`
// reads to find it.
package vm

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/machine"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// maxUnixSocketPath is the shortest sun_path limit among the platforms
// vmavs targets (108 bytes on Linux, 104 on macOS and the BSDs); a
// monitor socket at or past it fails to bind only once QEMU tries it, so
// Prepare rejects it up front with a clear reason.
const maxUnixSocketPath = 104

type Run struct {
	Dir   string
	Image manifest.Manifest
	Spec  machine.Spec

	// state is open for as long as this run is alive: it holds an
	// exclusive, non-blocking flock (LOCK_EX|LOCK_NB) that Live and Reap
	// test for. A pid is not enough (they can be recycled, and a signal-0
	// check against one has no way to tell "no such process" apart from
	// "a different process now has it"); a lock held by an open file
	// descriptor is released the moment this process's copy of it closes,
	// however that happens.
	state *os.File
}

type State struct {
	Image string
	Port  int
	PID   int
	Dir   string
	// Keep is whether this run's directory should survive its process
	// exiting (vmavs run --keep). Reap only removes a dead run whose
	// state says Keep is false.
	Keep bool
}

// Prepare creates a run directory under run/, named <image>-<random>: a
// qcow2 overlay backed by the image, so the image is never written, and
// this VM's own copy of the NVRAM template. keep is recorded in the state
// file for Reap to read later, once this process is gone.
func Prepare(ctx context.Context, r proc.Runner, p config.Paths, m manifest.Manifest, hw config.Machine, qemu string, pid int, keep bool) (*Run, error) {
	fw := machine.Firmware{OVMFCode: p.OVMFCode(), OpenCore: p.OpenCoreImage()}
	for _, need := range []struct{ path, from string }{
		{m.Image(), "vmavs image"},
		{fw.OVMFCode, "vmavs firmware"},
		{p.OVMFVarsTemplate(), "vmavs firmware"},
		{fw.OpenCore, "vmavs firmware"},
	} {
		if _, err := os.Stat(need.path); err != nil {
			return nil, fmt.Errorf("%s is missing; it is built by `%s` "+
				"(until that is ported: ./image/build-image.sh)", need.path, need.from)
		}
	}
	if err := os.MkdirAll(p.Run(), 0o755); err != nil {
		return nil, err
	}
	// MkdirTemp, not a fixed <image>-<pid> name: a recycled pid would
	// otherwise reuse (and, worse, silently truncate the overlay and
	// NVRAM of) another run's directory.
	dir, err := os.MkdirTemp(p.Run(), m.Name+"-")
	if err != nil {
		return nil, err
	}
	monitor := filepath.Join(dir, "monitor.sock")
	if len(monitor) >= maxUnixSocketPath {
		os.RemoveAll(dir)
		return nil, fmt.Errorf("monitor socket path %s is %d bytes, too long for a unix socket "+
			"(limit %d); use a shorter VMAVS_HOME", monitor, len(monitor), maxUnixSocketPath)
	}
	overlay := filepath.Join(dir, "disk.qcow2")
	if err := r.Run(ctx, proc.Cmd{Name: "qemu-img", Args: []string{
		"create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", m.Image(), overlay,
	}}); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	nvram := filepath.Join(dir, "OVMF_VARS.fd")
	if err := copyFile(p.OVMFVarsTemplate(), nvram); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	spec := machine.ForRun(hw, fw, nvram, overlay, monitor)
	spec.QEMU = qemu
	// Create, lock, then write: a state file that exists but is not yet
	// lockable (this window used to exist between WriteFile and Flock)
	// would let a concurrent Reap or Live either delete a brand new run
	// or misjudge it. O_EXCL also makes MkdirTemp's uniqueness redundant
	// insurance -- two Prepares can never share a state file.
	statePath := filepath.Join(dir, "state")
	sf, err := os.OpenFile(statePath, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o644)
	if err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	if err := syscall.Flock(int(sf.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		sf.Close()
		os.RemoveAll(dir)
		return nil, fmt.Errorf("%s: locking the state file: %w", statePath, err)
	}
	state := fmt.Sprintf("image\t%s\nport\t%d\npid\t%d\nkeep\t%t\n", m.Name, hw.SSHPort, pid, keep)
	if _, err := sf.WriteString(state); err != nil {
		sf.Close()
		os.RemoveAll(dir)
		return nil, err
	}
	return &Run{Dir: dir, Image: m, Spec: spec, state: sf}, nil
}

// Boot hands QEMU the run's own locked state file as an inherited fd (fd
// 3 onward, os/exec's ExtraFiles convention): the flock is then held by
// QEMU's copy of the open file description too, so it survives vmavs
// being killed outright (a SIGKILL it cannot catch to release the lock
// itself) for as long as QEMU keeps running.
func (r *Run) Boot(ctx context.Context, run proc.Runner, stdin io.Reader, stdout, stderr io.Writer) error {
	c := r.Spec.Command()
	c.Stdin, c.Stdout, c.Stderr = stdin, stdout, stderr
	if r.state != nil {
		c.ExtraFiles = []*os.File{r.state}
	}
	return run.Run(ctx, c)
}

// Close releases this run's lock on its state file without deleting
// anything; Reap, in some later process, then sees it as dead.
func (r *Run) Close() error {
	if r.state == nil {
		return nil
	}
	syscall.Flock(int(r.state.Fd()), syscall.LOCK_UN)
	err := r.state.Close()
	r.state = nil
	return err
}

// Remove releases the lock and deletes the run directory.
func (r *Run) Remove() error {
	r.Close()
	return os.RemoveAll(r.Dir)
}

// Live is every run directory whose state file's lock is still held: a
// process (not necessarily this one) is still using it. The lock is
// checked before the content is read: Prepare takes the lock before
// writing the state (see the comment there), so a state file that exists
// but cannot yet be parsed, in the narrow window before that write lands,
// is still a live run -- just not one Live can describe yet.
func Live(p config.Paths) ([]State, error) {
	states, err := filepath.Glob(filepath.Join(p.Run(), "*", "state"))
	if err != nil {
		return nil, err
	}
	var out []State
	for _, f := range states {
		held, err := locked(f)
		if err != nil || !held {
			continue
		}
		s, err := readState(f)
		if err != nil {
			continue
		}
		out = append(out, s)
	}
	return out, nil
}

// reapStaleAge is how long a run directory with no state file yet (one
// that crashed between MkdirTemp and the state write, or is still being
// created) is left alone before Reap treats it as abandoned.
const reapStaleAge = time.Minute

// Reap deletes every dead run directory that is not meant to be kept:
// its state says keep=false, or it has no state file yet (or one that
// cannot be parsed) and is older than reapStaleAge. The lock is always
// checked first, before anything about the state file's content is
// judged: Prepare takes the lock before writing the state (see the
// comment there), so a directory whose state file exists but is still
// empty is exactly as live as one whose state is fully written -- Reap
// must not delete a run out from under a Prepare that has not finished
// yet. It returns the directories it removed.
func Reap(p config.Paths) ([]string, error) {
	entries, err := os.ReadDir(p.Run())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var removed []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(p.Run(), entry.Name())
		statePath := filepath.Join(dir, "state")
		if held, err := locked(statePath); err == nil && held {
			continue
		}
		s, err := readState(statePath)
		if err != nil {
			info, statErr := os.Stat(dir)
			if statErr == nil && time.Since(info.ModTime()) > reapStaleAge {
				if err := os.RemoveAll(dir); err == nil {
					removed = append(removed, dir)
				}
			}
			continue
		}
		if s.Keep {
			continue
		}
		if err := os.RemoveAll(dir); err == nil {
			removed = append(removed, dir)
		}
	}
	return removed, nil
}

// locked reports whether path's exclusive lock is currently held by
// another open file descriptor -- a live run. A lockable file is dead;
// locked releases the lock it just took before returning.
func locked(path string) (bool, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return false, err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return true, nil
		}
		return false, err
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return false, nil
}

func readState(path string) (State, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return State{}, err
	}
	s := State{Dir: filepath.Dir(path)}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, _ := strings.Cut(line, "\t")
		switch k {
		case "image":
			s.Image = v
		case "port":
			s.Port, _ = strconv.Atoi(v)
		case "pid":
			s.PID, _ = strconv.Atoi(v)
		case "keep":
			s.Keep = v == "true"
		}
	}
	if s.Image == "" || s.Port == 0 {
		return State{}, fmt.Errorf("%s: incomplete", path)
	}
	return s, nil
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}
