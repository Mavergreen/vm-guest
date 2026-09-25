package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/firmware"
)

func linux(cpuinfo, msrs string, kvmWritable bool, tools ...string) Host {
	have := map[string]bool{}
	for _, t := range tools {
		have[t] = true
	}
	return Host{
		GOOS: "linux",
		ReadFile: func(p string) ([]byte, error) {
			switch p {
			case "/proc/cpuinfo":
				return []byte(cpuinfo), nil
			case "/sys/module/kvm/parameters/ignore_msrs":
				return []byte(msrs + "\n"), nil
			}
			return nil, os.ErrNotExist
		},
		// /dev/kvm is described; anything else (the files a test lays
		// out under its own temporary VMAVS_HOME) is looked up for real.
		Exists:   func(p string) bool { return p == "/dev/kvm" || config.Exists(p) },
		Writable: func(p string) bool { return p == "/dev/kvm" && kvmWritable },
		LookPath: func(n string) (string, error) {
			if have[n] {
				return "/usr/bin/" + n, nil
			}
			return "", errors.New("not found")
		},
	}
}

const intel = "vendor_id\t: GenuineIntel\nflags\t\t: fpu vmx sse4_2\n"

func row(rows []Row, check string) Row {
	for _, r := range rows {
		if r.Check == check {
			return r
		}
	}
	return Row{}
}

func TestAGoodIntelHost(t *testing.T) {
	rows := HostRows(linux(intel, "Y", true))
	for _, c := range []string{"cpu-vendor", "vmx", "kvm-device", "ignore-msrs"} {
		if row(rows, c).Status != "PASS" {
			t.Errorf("%s: %+v", c, row(rows, c))
		}
	}
}

func TestAMDAndNoVMXAndNoKVMFail(t *testing.T) {
	rows := HostRows(linux("vendor_id\t: AuthenticAMD\nflags\t\t: fpu svm\n", "N", false))
	if row(rows, "cpu-vendor").Status != "FAIL" || row(rows, "vmx").Status != "FAIL" ||
		row(rows, "kvm-device").Status != "FAIL" || row(rows, "ignore-msrs").Status != "WARN" {
		t.Fatalf("%+v", rows)
	}
}

func TestANonLinuxHostIsNeverProbed(t *testing.T) {
	h := linux(intel, "Y", true)
	h.GOOS = "darwin"
	h.ReadFile = func(string) ([]byte, error) { t.Fatal("probed a Linux path on darwin"); return nil, nil }
	rows := HostRows(h)
	if len(rows) != 1 || rows[0].Status != "UNKNOWN" || !strings.Contains(rows[0].Detail, "never probed on darwin") {
		t.Fatalf("%+v", rows)
	}
}

func TestRunNeedsAnImageFirmwareAndQEMU(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	subs := Subcommands(linux(intel, "Y", true, "qemu-system-x86_64"), p, "qemu-system-x86_64")
	var run Readiness
	for _, s := range subs {
		if s.Subcommand == "run" {
			run = s
		}
	}
	missing := strings.Join(run.Missing, " ")
	for _, want := range []string{"qemu-img", "a built image -- bin/vmavs image (until it is ported)", "OVMF_CODE.fd", "OVMF_VARS.fd", "opencore"} {
		if !strings.Contains(missing, want) {
			t.Errorf("run's missing list %q lacks %s", missing, want)
		}
	}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), filepath.Join(p.Work(), "opencore-p3.img"),
		filepath.Join(p.Images(), "i.qcow2"), filepath.Join(p.Images(), "i.manifest")} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, []byte("name\ti\n"), 0o644)
	}
	subs = Subcommands(linux(intel, "Y", true, "qemu-system-x86_64", "qemu-img"), p, "qemu-system-x86_64")
	ok, line := Verdict(HostRows(linux(intel, "Y", true)), subs)
	if !ok || !strings.Contains(line, "ready: fetch run") {
		t.Fatalf("ok=%v %s", ok, line)
	}
}

// TestRunReadinessAsksTheHostWhetherFirmwareExists: Subcommands judges
// the firmware files through Host.Exists, like every other host fact, so
// a test (or another host description) is believed rather than bypassed
// with a direct os.Stat.
func TestRunReadinessAsksTheHostWhetherFirmwareExists(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	os.MkdirAll(p.Images(), 0o755)
	os.WriteFile(filepath.Join(p.Images(), "i.qcow2"), nil, 0o644)
	os.WriteFile(filepath.Join(p.Images(), "i.manifest"), []byte("name\ti\n"), 0o644)
	h := linux(intel, "Y", true, "qemu-system-x86_64", "qemu-img")
	firmware := map[string]bool{p.OVMFCode(): true, p.OVMFVarsTemplate(): true, p.OpenCoreImage(): true}
	h.Exists = func(path string) bool { return path == "/dev/kvm" || firmware[path] }
	for _, s := range Subcommands(h, p, "qemu-system-x86_64") {
		if s.Subcommand == "run" && !s.Ready() {
			t.Fatalf("run missing %v, though Host.Exists says the firmware is there", s.Missing)
		}
	}
}

// TestFetchIsAlwaysReady: the Go binary does its own downloads and
// verification, so fetch needs no external tool -- unlike run, ssh or
// emit, it is READY even on a bare host with nothing built yet.
func TestFetchIsAlwaysReady(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	subs := Subcommands(linux("vendor_id\t: AuthenticAMD\nflags\t\t: fpu svm\n", "N", false), p, "qemu-system-x86_64")
	var fetch Readiness
	for _, s := range subs {
		if s.Subcommand == "fetch" {
			fetch = s
		}
	}
	if !fetch.Ready() {
		t.Fatalf("fetch missing %v, want it always READY", fetch.Missing)
	}
	if len(fetch.Notes) == 0 || !strings.Contains(fetch.Notes[0], "network") {
		t.Fatalf("fetch.Notes = %v, want a note about the network", fetch.Notes)
	}
}

func TestVerdictIsNoGoOnAHostFailure(t *testing.T) {
	ok, line := Verdict([]Row{{"FAIL", "kvm-device", "x"}}, []Readiness{{Subcommand: "run"}})
	if ok || !strings.HasPrefix(line, "NO-GO") {
		t.Fatalf("ok=%v %s", ok, line)
	}
}

// firmwareRow is the "firmware" Readiness among subs.
func firmwareRow(subs []Readiness) Readiness {
	for _, s := range subs {
		if s.Subcommand == "firmware" {
			return s
		}
	}
	return Readiness{}
}

func TestDoctorFirmwareRow(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	h := linux(intel, "Y", true, firmware.Tools("gcc")...)
	h.Header = func(string) bool { return true }
	fw := firmwareRow(Subcommands(h, p, "qemu-system-x86_64"))
	if !fw.Ready() {
		t.Fatalf("firmware row missing %v, want READY with every tool present and Header true", fw.Missing)
	}

	tools := firmware.Tools("gcc")
	var have []string
	for _, tl := range tools {
		if tl != "nasm" && tl != "zip" {
			have = append(have, tl)
		}
	}
	h = linux(intel, "Y", true, have...)
	h.Header = func(string) bool { return false }
	fw = firmwareRow(Subcommands(h, p, "qemu-system-x86_64"))
	want := "nasm, zip, uuid/uuid.h (a C header: the uuid development package)"
	if got := strings.Join(fw.Missing, ", "); got != want {
		t.Fatalf("firmware.Missing = %q, want %q", got, want)
	}
}

func TestDoctorFirmwareHonoursGCCBin(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	h := linux(intel, "Y", true, "bash", "make", "x86_64-elf-gcc", "git", "python3", "nasm", "iasl", "zip")
	h.GCCBin = "x86_64-elf-"
	h.Header = func(string) bool { return true }
	fw := firmwareRow(Subcommands(h, p, "qemu-system-x86_64"))
	if !fw.Ready() {
		t.Fatalf("firmware row missing %v, want READY: GCCBin should make it look up x86_64-elf-gcc, not gcc", fw.Missing)
	}
}

// TestRunNamesTheFirmwareCommandThatBuildsWhatItIsMissing: run's missing
// OVMF files point at "vmavs firmware ovmf" and its missing OpenCore
// image points at "vmavs firmware efi" -- each path first, so the
// existing substring checks on the bare path still hold.
func TestRunNamesTheFirmwareCommandThatBuildsWhatItIsMissing(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	subs := Subcommands(linux(intel, "Y", true, "qemu-system-x86_64", "qemu-img"), p, "qemu-system-x86_64")
	var run Readiness
	for _, s := range subs {
		if s.Subcommand == "run" {
			run = s
		}
	}
	missing := strings.Join(run.Missing, "; ")
	for _, want := range []string{
		p.OVMFCode() + " -- vmavs firmware ovmf",
		p.OVMFVarsTemplate() + " -- vmavs firmware ovmf",
		p.OpenCoreImage() + " -- vmavs firmware efi",
	} {
		if !strings.Contains(missing, want) {
			t.Errorf("run's missing list %q lacks %q", missing, want)
		}
	}
}

// TestDoctorOrderIsFetchFirmwareRunSSHEmit: the printed order, and the
// order GO/NO-GO's "ready:" list draws from.
func TestDoctorOrderIsFetchFirmwareRunSSHEmit(t *testing.T) {
	p := config.Paths{Home: t.TempDir()}
	subs := Subcommands(linux(intel, "Y", true), p, "qemu-system-x86_64")
	var got []string
	for _, s := range subs {
		got = append(got, s.Subcommand)
	}
	want := []string{"fetch", "firmware", "run", "ssh", "emit"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("Subcommands order = %v, want %v", got, want)
	}
}
