package machine

import (
	"slices"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
)

var fw = Firmware{OVMFCode: "/fw/OVMF_CODE.fd", OpenCore: "/oc.img"}

func TestInstallMatchesTheShellPipelineArgumentForArgument(t *testing.T) {
	s := ForInstall(config.DefaultMachine(), fw, "/w/VARS.fd", "/i/x.qcow2", "/m/installer.img", "/w/monitor.sock")
	want := []string{
		"-accel", "kvm",
		"-machine", "q35,vmport=off",
		"-cpu", "Penryn,+ssse3,+sse4.1,+sse4.2",
		"-m", "4096",
		"-smp", "2",
		"-drive", "if=pflash,format=raw,unit=0,readonly=on,file=/fw/OVMF_CODE.fd",
		"-drive", "if=pflash,format=raw,unit=1,file=/w/VARS.fd",
		"-device", "ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on",
		"-device", "ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on",
		"-device", "ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1",
		"-device", "ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2",
		"-drive", "id=opencore,if=none,format=raw,snapshot=on,file=/oc.img",
		"-device", "usb-storage,bus=usb.0,drive=opencore",
		"-drive", "id=target,if=none,format=qcow2,file=/i/x.qcow2",
		"-device", "ide-hd,bus=ide.0,drive=target",
		// Deliberately deviates from build-image.sh's qemu_args()
		// ("hostfwd=tcp::2222-:22"): binding 127.0.0.1 keeps the guest's
		// sshd, Apple's OpenSSH 6.2, off the network; vmavs ssh only
		// ever dials 127.0.0.1 itself (fix round 1, controller ruling 6).
		"-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
		"-device", "e1000-82545em,netdev=net0",
		"-device", "usb-kbd,bus=usb.0",
		"-device", "usb-mouse,bus=usb.0",
		"-device", "VGA,vgamem_mb=64",
		"-display", "none",
		"-monitor", "unix:/w/monitor.sock,server,nowait",
		"-drive", "id=installer,if=none,format=raw,snapshot=on,file=/m/installer.img",
		"-device", "ide-hd,bus=ide.1,drive=installer",
	}
	if got := s.Args(); !slices.Equal(got, want) {
		t.Fatalf("args differ from build-image.sh qemu_args:\n got %q\nwant %q", got, want)
	}
}

func TestRunAndVerifyHaveNoInstaller(t *testing.T) {
	for _, s := range []Spec{
		ForRun(config.DefaultMachine(), fw, "/r/VARS.fd", "/r/disk.qcow2", "/r/monitor.sock"),
		ForVerify(config.DefaultMachine(), fw, "/w/VARS.fd", "/i/x.qcow2", "/w/monitor.sock"),
	} {
		if slices.Contains(s.Args(), "ide-hd,bus=ide.1,drive=installer") {
			t.Fatalf("%v attaches installer media", s.Args())
		}
	}
}

func TestUSBNetHangsOffTheEHCIController(t *testing.T) {
	if NICDevice("usb-net") != "usb-net,bus=usb.0,netdev=net0" || NICDevice("virtio-net-pci") != "virtio-net-pci,netdev=net0" {
		t.Fatal("NIC device lines differ from build-image.sh nic_device()")
	}
}

func TestNoMonitorAndAChosenDisplay(t *testing.T) {
	m := config.DefaultMachine()
	m.Display = "gtk"
	args := ForRun(m, fw, "/r/V", "/r/d", "").Args()
	if slices.Contains(args, "-monitor") || !slices.Contains(args, "gtk") {
		t.Fatalf("%q", args)
	}
}
