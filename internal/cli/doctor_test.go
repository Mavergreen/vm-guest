package cli

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/doctor"
	"github.com/Mavergreen/vm-guest/internal/firmware"
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

// TestDoctorRealHostWiresGCCBinAndTheHeaderProbe: with no Host override
// (so cmdDoctor builds the real doctor.Host itself), GCC_BIN reaches
// Host.GCCBin, and Host.Header calls firmware.HeaderCompiles through the
// Runner with the GCC_BIN-prefixed compiler name -- the fake only knows
// "x86_64-elf-gcc", so this also proves GCCBin is not silently dropped.
func TestDoctorRealHostWiresGCCBinAndTheHeaderProbe(t *testing.T) {
	compiles := true
	fake := &proc.Fake{Paths: map[string]string{"x86_64-elf-gcc": "/usr/bin/x86_64-elf-gcc"}, Handle: func(c proc.Cmd) error {
		if c.Name != "x86_64-elf-gcc" || len(c.Args) != 4 || c.Args[0] != "-fsyntax-only" {
			return nil
		}
		if compiles {
			return nil
		}
		return &proc.ExitError{Cmd: c.String(), Code: 1}
	}}
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "GCC_BIN": "x86_64-elf-"}
	e := &Env{Stdin: strings.NewReader(""), Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{},
		Getenv: func(k string) string { return env[k] }, Runner: fake, PID: 777}

	compiles = false
	var out bytes.Buffer
	e.Stdout = &out
	Run(context.Background(), []string{"doctor"}, e)
	if !strings.Contains(out.String(), "uuid/uuid.h ("+firmware.HeaderPackage("uuid/uuid.h")+")") {
		t.Fatalf("stdout lacks the missing header -- Host.Header should have called x86_64-elf-gcc, which refuses it:\n%s", out.String())
	}

	compiles = true
	out.Reset()
	Run(context.Background(), []string{"doctor"}, e)
	if strings.Contains(out.String(), "uuid/uuid.h (") {
		t.Fatalf("stdout still lists the header as missing though the fake x86_64-elf-gcc now accepts it:\n%s", out.String())
	}
}

// TestDoctorSubcommandOrderIsFetchFirmwareRunSSHEmit: the SUBCOMMAND
// table lists firmware right after fetch, before run.
func TestDoctorSubcommandOrderIsFetchFirmwareRunSSHEmit(t *testing.T) {
	home := t.TempDir()
	host := fakeHost(goodCPUInfo, "Y", true, "qemu-system-x86_64", "qemu-img")
	_, stdout, _ := runDoctor(t, host, map[string]string{"VMAVS_HOME": home})
	var order []string
	for _, line := range strings.Split(stdout, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		switch fields[1] {
		case "fetch", "firmware", "run", "ssh", "emit":
			order = append(order, fields[1])
		}
	}
	want := []string{"fetch", "firmware", "run", "ssh", "emit"}
	if !slices.Equal(order, want) {
		t.Fatalf("subcommand order = %v, want %v", order, want)
	}
}

func TestDoctorShowsTheLegacyHomeHintWhenItApplies(t *testing.T) {
	home := t.TempDir()
	legacyImages(t, home)
	host := fakeHost(goodCPUInfo, "Y", true)
	code, stdout, _ := runDoctor(t, host, map[string]string{"HOME": home})
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(stdout, "export VMAVS_HOME=") {
		t.Fatalf("stdout=%s, want the legacy-home hint", stdout)
	}
}
