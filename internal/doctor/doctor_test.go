package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
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
		Exists:   func(p string) bool { return p == "/dev/kvm" },
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
	if !ok || !strings.Contains(line, "ready: run") {
		t.Fatalf("ok=%v %s", ok, line)
	}
}

func TestVerdictIsNoGoOnAHostFailure(t *testing.T) {
	ok, line := Verdict([]Row{{"FAIL", "kvm-device", "x"}}, []Readiness{{Subcommand: "run"}})
	if ok || !strings.HasPrefix(line, "NO-GO") {
		t.Fatalf("ok=%v %s", ok, line)
	}
}
