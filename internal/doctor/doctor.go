// Package doctor judges whether this host can do what vmavs does. The
// rules are the shell tree's (lib/preconditions.sh), narrowed to the
// subcommands the Go vmavs has.
package doctor

import (
	"fmt"
	"os"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/manifest"
)

// Host is everything doctor reads from the machine, so that tests can
// describe a machine instead of depending on the one they run on.
type Host struct {
	GOOS     string
	ReadFile func(string) ([]byte, error)
	Exists   func(string) bool
	Writable func(string) bool
	LookPath func(string) (string, error)
}

type Row struct{ Status, Check, Detail string }

type Readiness struct {
	Subcommand string
	Missing    []string
	Notes      []string
}

func (r Readiness) Ready() bool { return len(r.Missing) == 0 }

func HostRows(h Host) []Row {
	if h.GOOS != "linux" {
		return []Row{{"UNKNOWN", "accelerator",
			fmt.Sprintf("never probed on %s by this project -- see docs/test-hosts.md", h.GOOS)}}
	}
	var rows []Row
	info, _ := h.ReadFile("/proc/cpuinfo")
	vendor, flags := cpuinfo(string(info))
	switch vendor {
	case "GenuineIntel":
		rows = append(rows, Row{"PASS", "cpu-vendor", "Intel: the documented KVM path"})
	case "AuthenticAMD":
		rows = append(rows, Row{"FAIL", "cpu-vendor", "AMD is a known-harder case for macOS guests; stop and ask"})
	default:
		rows = append(rows, Row{"FAIL", "cpu-vendor", "unrecognised CPU vendor: " + vendor})
	}
	if strings.Contains(" "+flags+" ", " vmx ") {
		rows = append(rows, Row{"PASS", "vmx", "VT-x present"})
	} else {
		rows = append(rows, Row{"FAIL", "vmx", "no VT-x; KVM acceleration unavailable"})
	}
	switch {
	case h.Writable("/dev/kvm"):
		rows = append(rows, Row{"PASS", "kvm-device", "/dev/kvm is writable by this user"})
	case h.Exists("/dev/kvm"):
		rows = append(rows, Row{"FAIL", "kvm-device", "/dev/kvm exists but is not writable; is this user in group kvm?"})
	default:
		rows = append(rows, Row{"FAIL", "kvm-device", "/dev/kvm does not exist"})
	}
	msrs, err := h.ReadFile("/sys/module/kvm/parameters/ignore_msrs")
	if v := strings.TrimSpace(string(msrs)); err == nil && v == "Y" {
		rows = append(rows, Row{"PASS", "ignore-msrs", "kvm.ignore_msrs is enabled"})
	} else {
		rows = append(rows, Row{"WARN", "ignore-msrs", fmt.Sprintf("kvm.ignore_msrs is %q; prior art requires it. "+
			"Needs root: echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs", v)})
	}
	return rows
}

func cpuinfo(s string) (vendor, flags string) {
	for _, line := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "vendor_id":
			if vendor == "" {
				vendor = strings.TrimSpace(v)
			}
		case "flags":
			if flags == "" {
				flags = strings.TrimSpace(v)
			}
		}
	}
	return vendor, flags
}

func Subcommands(h Host, p config.Paths, qemu string) []Readiness {
	run := Readiness{Subcommand: "run"}
	for _, t := range []string{qemu, "qemu-img"} {
		if _, err := h.LookPath(t); err != nil {
			run.Missing = append(run.Missing, t)
		}
	}
	if ms, _ := manifest.List(p.Images()); len(ms) == 0 {
		run.Missing = append(run.Missing, "a built image (vmavs image)")
	}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), p.OpenCoreImage()} {
		if _, err := os.Stat(f); err != nil {
			run.Missing = append(run.Missing, f)
		}
	}
	emit := Readiness{Subcommand: "emit"}
	if _, err := h.LookPath("packer"); err != nil {
		emit.Notes = append(emit.Notes, "--check needs packer on PATH")
	}
	return []Readiness{run, {Subcommand: "ssh"}, emit}
}

func Verdict(host []Row, subs []Readiness) (bool, string) {
	var ready, blocked []string
	runReady := false
	for _, s := range subs {
		if s.Ready() {
			ready = append(ready, s.Subcommand)
			runReady = runReady || s.Subcommand == "run"
		} else {
			blocked = append(blocked, fmt.Sprintf("%s (missing: %s)", s.Subcommand, strings.Join(s.Missing, ", ")))
		}
	}
	hostOK := true
	for _, r := range host {
		hostOK = hostOK && r.Status != "FAIL"
	}
	ok := hostOK && runReady
	word := "GO"
	if !ok {
		word = "NO-GO"
	}
	line := fmt.Sprintf("%s -- ready: %s", word, strings.Join(ready, " "))
	if len(blocked) > 0 {
		line += "; blocked: " + strings.Join(blocked, "; ")
	}
	return ok, line
}
