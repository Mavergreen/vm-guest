// Package config holds every default vmavs has, and the layout of
// VMAVS_HOME. No other package decides a default or builds a path under
// VMAVS_HOME itself.
package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
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

// Home is VMAVS_HOME, else ~/.local/share/vmavs.
func Home(getenv func(string) string) (string, error) {
	if h := getenv("VMAVS_HOME"); h != "" {
		return h, nil
	}
	u := getenv("HOME")
	if u == "" {
		return "", errors.New("neither VMAVS_HOME nor HOME is set")
	}
	return filepath.Join(u, ".local", "share", "vmavs"), nil
}

// LegacyHint explains, when the default home does not exist and the shell
// tree's does, how to point vmavs at it. It is "" otherwise. vmavs never
// moves anything itself.
func LegacyHint(getenv func(string) string, exists func(string) bool) string {
	if getenv("VMAVS_HOME") != "" || getenv("HOME") == "" {
		return ""
	}
	u := getenv("HOME")
	old := filepath.Join(u, ".local", "share", "mavericks-qemu-guest")
	cur := filepath.Join(u, ".local", "share", "vmavs")
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
