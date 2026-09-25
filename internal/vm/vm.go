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

type Run struct {
	Dir   string
	Image manifest.Manifest
	Spec  machine.Spec
}

type State struct {
	Image string
	Port  int
	PID   int
	Dir   string
}

// Prepare creates run/<image>-<pid>/: a qcow2 overlay backed by the
// image, so the image is never written, and this VM's own copy of the
// NVRAM template.
func Prepare(ctx context.Context, r proc.Runner, p config.Paths, m manifest.Manifest, hw config.Machine, qemu string, pid int) (*Run, error) {
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
	dir := filepath.Join(p.Run(), fmt.Sprintf("%s-%d", m.Name, pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
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
	spec := machine.ForRun(hw, fw, nvram, overlay, filepath.Join(dir, "monitor.sock"))
	spec.QEMU = qemu
	state := fmt.Sprintf("image\t%s\nport\t%d\npid\t%d\n", m.Name, hw.SSHPort, pid)
	if err := os.WriteFile(filepath.Join(dir, "state"), []byte(state), 0o644); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	return &Run{Dir: dir, Image: m, Spec: spec}, nil
}

func (r *Run) Boot(ctx context.Context, run proc.Runner, stdin io.Reader, stdout, stderr io.Writer) error {
	c := r.Spec.Command()
	c.Stdin, c.Stdout, c.Stderr = stdin, stdout, stderr
	return run.Run(ctx, c)
}

func (r *Run) Remove() error { return os.RemoveAll(r.Dir) }

// Live is every run directory whose process is still running.
func Live(p config.Paths) ([]State, error) {
	states, err := filepath.Glob(filepath.Join(p.Run(), "*", "state"))
	if err != nil {
		return nil, err
	}
	var out []State
	for _, f := range states {
		s, err := readState(f)
		if err != nil || !alive(s.PID) {
			continue
		}
		out = append(out, s)
	}
	return out, nil
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
		}
	}
	if s.PID == 0 || s.Port == 0 {
		return State{}, fmt.Errorf("%s: incomplete", path)
	}
	return s, nil
}

// alive: signal 0 checks for existence. EPERM still means it exists.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}
