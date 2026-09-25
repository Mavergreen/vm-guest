// Package machine is the one definition of the guest's hardware. The
// install and verify stages, `vmavs run` and `vmavs emit packer` all
// derive from Spec, so they cannot drift apart. They drifted three ways
// in the shell tree: image/build-image.sh, image/compare-images.sh and
// vm/profiles/*.args.
package machine

import (
	"fmt"
	"strconv"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

type Firmware struct {
	OVMFCode string
	OpenCore string
}

type Spec struct {
	QEMU string
	config.Machine
	OVMFCode  string
	NVRAM     string // this VM's own copy of the OVMF variable store
	OpenCore  string
	Disk      string
	Installer string // attached only while installing
	Monitor   string // unix socket path, or "" for none
}

func ForInstall(m config.Machine, fw Firmware, nvram, disk, installer, monitor string) Spec {
	s := ForVerify(m, fw, nvram, disk, monitor)
	s.Installer = installer
	return s
}

// ForVerify boots the built image without its installer: an image that
// only boots with the installer beside it is not the deliverable.
func ForVerify(m config.Machine, fw Firmware, nvram, disk, monitor string) Spec {
	return Spec{
		QEMU: config.DefaultQEMU, Machine: m,
		OVMFCode: fw.OVMFCode, NVRAM: nvram, OpenCore: fw.OpenCore,
		Disk: disk, Monitor: monitor,
	}
}

// ForRun boots a throwaway overlay backed by the built image, so the image
// itself is never written.
func ForRun(m config.Machine, fw Firmware, nvram, overlay, monitor string) Spec {
	return ForVerify(m, fw, nvram, overlay, monitor)
}

// NICDevice is the -device line for a NIC. usb-net is a USB device and
// hangs off the EHCI controller; the others are PCI, and QEMU places them.
func NICDevice(nic string) string {
	if nic == "usb-net" {
		return "usb-net,bus=usb.0,netdev=net0"
	}
	return nic + ",netdev=net0"
}

// Args is the QEMU command line, in the order image/build-image.sh's
// qemu_args() produced it.
func (s Spec) Args() []string {
	display := s.Display
	if display == "" {
		display = config.DefaultDisplay
	}
	a := []string{
		"-accel", s.Accel,
		"-machine", s.Type + ",vmport=off",
		"-cpu", s.CPU,
		"-m", strconv.Itoa(s.MemoryMB),
		"-smp", strconv.Itoa(s.SMP),
		"-drive", "if=pflash,format=raw,unit=0,readonly=on,file=" + s.OVMFCode,
		"-drive", "if=pflash,format=raw,unit=1,file=" + s.NVRAM,
		"-device", "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on",
		"-device", "ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on",
		"-device", "ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1",
		"-device", "ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2",
		// snapshot=on: the guest writes to the OpenCore image, and the file
		// must not change when it does. Without it every boot rewrote the
		// bootloader image, and the manifest's opencore checksum stopped
		// meaning anything (found by image/compare-images.sh; NOTES.md).
		"-drive", "id=opencore,if=none,format=raw,snapshot=on,file=" + s.OpenCore,
		"-device", "usb-storage,bus=usb.0,drive=opencore",
		"-drive", "id=target,if=none,format=qcow2,file=" + s.Disk,
		"-device", "ide-hd,bus=ide.0,drive=target",
		"-netdev", fmt.Sprintf("user,id=net0,hostfwd=tcp::%d-:22", s.SSHPort),
		"-device", NICDevice(s.NIC),
		"-device", "usb-kbd,bus=usb.0",
		"-device", "usb-mouse,bus=usb.0",
		"-device", "VGA,vgamem_mb=64",
		"-display", display,
	}
	if s.Monitor != "" {
		a = append(a, "-monitor", "unix:"+s.Monitor+",server,nowait")
	}
	if s.Installer != "" {
		// snapshot=on for the same reason: mds writes a .Spotlight-V100
		// store onto the installer media, with a fresh UUID each time.
		a = append(a,
			"-drive", "id=installer,if=none,format=raw,snapshot=on,file="+s.Installer,
			"-device", "ide-hd,bus=ide.1,drive=installer")
	}
	return a
}

func (s Spec) Command() proc.Cmd {
	q := s.QEMU
	if q == "" {
		q = config.DefaultQEMU
	}
	return proc.Cmd{Name: q, Args: s.Args()}
}
