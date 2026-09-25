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
	// exclusive flock (LOCK_EX) that Live and Reap test for. A pid is not
	// enough (they can be recycled, and a signal-0 check against one has
	// no way to tell "no such process" apart from "a different process now
	// has it"); a flock is released the moment the last descriptor for
	// its open file description closes -- this process's, and QEMU's once
	// Boot has handed it over -- however that happens.
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
	// The state file comes first, before any slow step (qemu-img, the
	// NVRAM copy): created, locked, then written, so that a run directory
	// vmavs made has a locked state file from birth and Reap never has to
	// guess about one without it. Create-then-lock leaves no window in
	// which the file exists but is unlockable; O_EXCL also makes
	// MkdirTemp's uniqueness redundant insurance -- two Prepares can never
	// share a state file. The lock is a blocking LOCK_EX: nothing but a
	// momentary probe (Live or Reap in a concurrent vmavs, which takes the
	// lock and releases it at once) can hold a brand new file's lock, and
	// a non-blocking one would fail this run for losing that race.
	statePath := filepath.Join(dir, "state")
	sf, err := os.OpenFile(statePath, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o644)
	if err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	fail := func(err error) (*Run, error) {
		sf.Close()
		os.RemoveAll(dir)
		return nil, err
	}
	if err := syscall.Flock(int(sf.Fd()), syscall.LOCK_EX); err != nil {
		return fail(fmt.Errorf("%s: locking the state file: %w", statePath, err))
	}
	state := fmt.Sprintf("image\t%s\nport\t%d\npid\t%d\nkeep\t%t\n", m.Name, hw.SSHPort, pid, keep)
	if _, err := sf.WriteString(state); err != nil {
		return fail(err)
	}
	monitor := filepath.Join(dir, "monitor.sock")
	if len(monitor) >= maxUnixSocketPath {
		return fail(fmt.Errorf("monitor socket path %s is %d bytes, too long for a unix socket "+
			"(limit %d); use a shorter VMAVS_HOME", monitor, len(monitor), maxUnixSocketPath))
	}
	overlay := filepath.Join(dir, "disk.qcow2")
	if err := r.Run(ctx, proc.Cmd{Name: "qemu-img", Args: []string{
		"create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", m.Image(), overlay,
	}}); err != nil {
		return fail(err)
	}
	nvram := filepath.Join(dir, "OVMF_VARS.fd")
	if err := copyFile(p.OVMFVarsTemplate(), nvram); err != nil {
		return fail(err)
	}
	spec := machine.ForRun(hw, fw, nvram, overlay, monitor)
	spec.QEMU = qemu
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

// Close closes this process's copy of the state file without deleting
// anything. It does not LOCK_UN: a flock belongs to the open file
// description, which QEMU shares once Boot has handed it over, so an
// explicit unlock here would release QEMU's lock too if Close ever ran
// while QEMU was still up. Closing only drops this process's reference;
// the lock goes once the last one (QEMU's, if it was booted) is gone, and
// Reap, in some later process, then sees the run as dead.
func (r *Run) Close() error {
	if r.state == nil {
		return nil
	}
	err := r.state.Close()
	r.state = nil
	return err
}

// Remove closes the state file and deletes the run directory.
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

// Reap deletes every dead run directory that is not meant to be kept. It
// deletes only what it can prove is a dead vmavs run: a directory whose
// state file it could lock (no process holds it: dead), could parse, and
// that says keep=false. Anything else under run/ is left alone -- a
// directory with no state file (vmavs never made it: Prepare writes the
// state before anything else, see there), one whose state file does not
// parse, and one whose lock it could not even probe (an error there says
// nothing about whether the run is alive). The cost is that a Prepare
// that dies between MkdirTemp and creating the state file leaves an empty
// directory behind for good; that is the price of never guessing. The
// lock is checked before the content is read, so a run mid-Prepare is
// never judged by a half-written state. It returns the directories it
// removed.
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
		if held, err := locked(statePath); err != nil || held {
			continue
		}
		s, err := readState(statePath)
		if err != nil || s.Keep {
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
