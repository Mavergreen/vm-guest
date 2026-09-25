// Package config holds every default vmavs has, and the layout of
// VMAVS_HOME: where each directory under it is. No other package decides
// a default or places a directory there. What goes inside a directory is
// its owner's business: vm names the files inside a run directory it made
// (state, disk.qcow2, OVMF_VARS.fd, monitor.sock), and manifest and guest
// look inside the images/ and keys/ directories config names.
package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Machine defaults, MEASURED: each is the value image/build-image.sh used
// for the installs recorded in NOTES.md.
const (
	DefaultAccel = "kvm"
	DefaultType  = "q35"
	// DefaultCPU is the only -cpu line with completed installs behind it
	// (docs/decisions/0009).
	DefaultCPU = "Penryn,+ssse3,+sse4.1,+sse4.2"
	// DefaultSMBIOS is baked into OpenCore's config.plist, not passed to
	// QEMU (docs/decisions/0010).
	DefaultSMBIOS   = "iMac14,2"
	DefaultMemoryMB = 4096
	DefaultSMP      = 2
	DefaultDiskGB   = 60
	DefaultNIC      = "e1000-82545em"
	// LegacyNIC is what every image built before commit a9f8c61
	// (2026-09-21) was installed with. Their manifests have no nic line.
	LegacyNIC      = "usb-net"
	DefaultSSHPort = 2222
	DefaultSSHUser = "mavsuser"
	DefaultQEMU    = "qemu-system-x86_64"
	DefaultDisplay = "none"
)

// NICChoices are the network devices a guest has been installed with
// (docs/open-questions.md Q2).
var NICChoices = []string{"usb-net", "e1000-82545em", "virtio-net-pci"}

// Which post-10.9.5 updates an image carries (docs/decisions/0011): a
// build-time choice whose default is a decision.
var UpdateChoices = []string{"none", "security", "all"}

const DefaultUpdates = "security"

// Paths is the layout of VMAVS_HOME (spec §5).
type Paths struct{ Home string }

func (p Paths) Images() string           { return filepath.Join(p.Home, "images") }
func (p Paths) Build() string            { return filepath.Join(p.Home, "build") }
func (p Paths) Firmware() string         { return filepath.Join(p.Build(), "firmware") }
func (p Paths) OVMFCode() string         { return filepath.Join(p.Firmware(), "OVMF_CODE.fd") }
func (p Paths) OVMFVarsTemplate() string { return filepath.Join(p.Firmware(), "OVMF_VARS.fd") }
func (p Paths) Work() string             { return filepath.Join(p.Home, "work") }
func (p Paths) Run() string              { return filepath.Join(p.Home, "run") }
func (p Paths) Keys() string             { return filepath.Join(p.Home, "keys") }
func (p Paths) Cache() string            { return filepath.Join(p.Home, "cache") }

// CacheFile is where a downloaded input with this checksum and filename
// lives: content-addressed, so a changed pin is a different file and a
// cached file can always be re-verified against its own directory name.
func (p Paths) CacheFile(sha256, filename string) string {
	return filepath.Join(p.Cache(), sha256, filename)
}

// OpenCoreImage is build/opencore.img. Until the shell tree is retired
// (spec §5, phase 6), an image it built keeps OpenCore at
// work/opencore-p3.img, and that path is used when the new one is absent.
func (p Paths) OpenCoreImage() string {
	cur := filepath.Join(p.Build(), "opencore.img")
	if exists(cur) {
		return cur
	}
	if legacy := filepath.Join(p.Work(), "opencore-p3.img"); exists(legacy) {
		return legacy
	}
	return cur
}

// Home is VMAVS_HOME, made absolute (a qcow2 overlay's backing file is a
// path baked into the overlay, and a relative one would break as soon as
// the working directory changed), else ~/.local/share/vmavs. The root
// directory is refused: vmavs creates, and reaps, directories under it.
func Home(getenv func(string) string) (string, error) {
	if h := getenv("VMAVS_HOME"); h != "" {
		if strings.HasPrefix(h, "~") {
			return "", fmt.Errorf("VMAVS_HOME=%s: a leading ~ is not expanded here; use $HOME instead", h)
		}
		abs, err := filepath.Abs(h)
		if err != nil {
			return "", fmt.Errorf("VMAVS_HOME=%s: %w", h, err)
		}
		if abs == string(filepath.Separator) {
			// run/ would be the system's /run, which vmavs reaps.
			return "", fmt.Errorf("VMAVS_HOME=%s is the root directory; give vmavs a directory of its own", h)
		}
		return abs, nil
	}
	u := getenv("HOME")
	if u == "" {
		return "", errors.New("neither VMAVS_HOME nor HOME is set")
	}
	return filepath.Join(u, ".local", "share", "vmavs"), nil
}

// LegacyHome is the shell tree's state directory, whose downloads vmavs
// fetch adopts (verified) instead of downloading again. "" without HOME.
func LegacyHome(getenv func(string) string) string {
	if h := getenv("HOME"); h != "" {
		return filepath.Join(h, ".local", "share", "mavericks-qemu-guest")
	}
	return ""
}

// LegacyHint explains, when the default home does not exist and the shell
// tree's does, how to point vmavs at it. It is "" otherwise. vmavs never
// moves anything itself.
func LegacyHint(getenv func(string) string, exists func(string) bool) string {
	if getenv("VMAVS_HOME") != "" || getenv("HOME") == "" {
		return ""
	}
	old := LegacyHome(getenv)
	cur := filepath.Join(getenv("HOME"), ".local", "share", "vmavs")
	if !exists(old) || exists(cur) {
		return ""
	}
	return fmt.Sprintf("built state is in the shell tree's location, %s:\n"+
		"  while the shell tree is still in use:  export VMAVS_HOME=%s\n"+
		"  once it is retired:                    mv %s %s", old, old, old, cur)
}

// QEMU is the QEMU binary: VMAVS_QEMU, else qemu-system-x86_64.
func QEMU(getenv func(string) string) string {
	if q := getenv("VMAVS_QEMU"); q != "" {
		return q
	}
	return DefaultQEMU
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// Exists reports whether p exists. It is the default for LegacyHint.
func Exists(p string) bool { return exists(p) }
