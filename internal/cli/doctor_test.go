package cli

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/doctor"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

const goodCPUInfo = "vendor_id\t: GenuineIntel\nflags\t\t: fpu vmx sse4_2\n"

// fakeHost is a doctor.Host describing a machine, not the one running
// this test.
func fakeHost(cpuinfo, msrs string, kvmWritable bool, tools ...string) doctor.Host {
	have := map[string]bool{}
	for _, t := range tools {
		have[t] = true
	}
	return doctor.Host{
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

func runDoctor(t *testing.T, host doctor.Host, env map[string]string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	e := &Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Getenv: func(k string) string { return env[k] }, Runner: &proc.Fake{}, Host: &host, PID: 777}
	code := Run(context.Background(), []string{"doctor"}, e)
	return code, out.String(), errb.String()
}

func TestDoctorPrintsTablesAndTheVerdictAndExitsNonZeroOnNOGO(t *testing.T) {
	home := t.TempDir()
	host := fakeHost(goodCPUInfo, "Y", true, "qemu-system-x86_64", "qemu-img")
	code, stdout, stderr := runDoctor(t, host, map[string]string{"VMAVS_HOME": home})
	if code != 1 {
		t.Fatalf("code=%d stdout=%s stderr=%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "STATUS") || !strings.Contains(stdout, "cpu-vendor") || !strings.Contains(stdout, "SUBCOMMAND") {
		t.Fatalf("stdout=%s", stdout)
	}
	if !strings.Contains(stderr, "vmavs doctor: NO-GO") {
		t.Fatalf("stderr=%s, want the verdict on stderr", stderr)
	}
	if strings.Contains(stderr, "error:") {
		t.Fatalf("a NO-GO verdict is not an error to explain: stderr=%s", stderr)
	}
}

// TestDoctorListsWhatIsMissingCommaJoined: the table says what is missing
// the way the verdict does, not as a Go slice ("[a b c]"), whose items
// run together when one has a space in it.
func TestDoctorListsWhatIsMissingCommaJoined(t *testing.T) {
	home := t.TempDir()
	host := fakeHost(goodCPUInfo, "Y", true)
	_, stdout, _ := runDoctor(t, host, map[string]string{"VMAVS_HOME": home})
	if !strings.Contains(stdout, "missing: qemu-system-x86_64, qemu-img, a built image") || strings.Contains(stdout, "missing: [") {
		t.Fatalf("stdout=%s", stdout)
	}
}

func TestDoctorExitsZeroOnGO(t *testing.T) {
	home := t.TempDir()
	p := config.Paths{Home: home}
	for _, f := range []string{p.OVMFCode(), p.OVMFVarsTemplate(), filepath.Join(p.Work(), "opencore-p3.img"),
		filepath.Join(p.Images(), "i.qcow2"), filepath.Join(p.Images(), "i.manifest")} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, []byte("name\ti\n"), 0o644)
	}
	host := fakeHost(goodCPUInfo, "Y", true, "qemu-system-x86_64", "qemu-img")
	code, _, stderr := runDoctor(t, host, map[string]string{"VMAVS_HOME": home})
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stderr, "vmavs doctor: GO") {
		t.Fatalf("stderr=%s", stderr)
	}
}

func TestDoctorShowsTheLegacyHomeHintWhenItApplies(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".local", "share", "mavericks-qemu-guest"), 0o755)
	host := fakeHost(goodCPUInfo, "Y", true)
	code, stdout, _ := runDoctor(t, host, map[string]string{"HOME": home})
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(stdout, "export VMAVS_HOME=") {
		t.Fatalf("stdout=%s, want the legacy-home hint", stdout)
	}
}
