package config

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestHomeIsVMAVS_HOMEElseXDGStyleDefault(t *testing.T) {
	if h, _ := Home(env(map[string]string{"VMAVS_HOME": "/x", "HOME": "/h"})); h != "/x" {
		t.Fatalf("got %q", h)
	}
	if h, _ := Home(env(map[string]string{"HOME": "/h"})); h != "/h/.local/share/vmavs" {
		t.Fatalf("got %q", h)
	}
	if _, err := Home(env(nil)); err == nil {
		t.Fatal("no HOME and no VMAVS_HOME must be an error")
	}
}

func TestHomeIsMadeAbsolute(t *testing.T) {
	h, err := Home(env(map[string]string{"VMAVS_HOME": "rel/vmavs"}))
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(h) {
		t.Fatalf("got %q, want absolute (a relative VMAVS_HOME would break every overlay's backing-file path)", h)
	}
}

func TestHomeRejectsATildePrefix(t *testing.T) {
	_, err := Home(env(map[string]string{"VMAVS_HOME": "~/vmavs"}))
	if err == nil || !strings.Contains(err.Error(), "$HOME") {
		t.Fatalf("err = %v, want a hint to use $HOME", err)
	}
}

// TestHomeRejectsTheRootDirectory: VMAVS_HOME=/ would make run/ the
// system's /run, and put vmavs's own directories at the top of the tree.
func TestHomeRejectsTheRootDirectory(t *testing.T) {
	for _, h := range []string{"/", "//", "/.", "/tmp/.."} {
		if got, err := Home(env(map[string]string{"VMAVS_HOME": h})); err == nil {
			t.Errorf("VMAVS_HOME=%s: got %q, want an error", h, got)
		}
	}
}

func TestLegacyHintOnlyWhenOnlyTheOldHomeExists(t *testing.T) {
	old := "/h/.local/share/mavericks-qemu-guest"
	exists := func(p string) bool { return p == old }
	hint := LegacyHint(env(map[string]string{"HOME": "/h"}), exists)
	if !strings.Contains(hint, "export VMAVS_HOME="+old) || !strings.Contains(hint, "mv "+old) {
		t.Fatalf("hint = %q", hint)
	}
	if LegacyHint(env(map[string]string{"HOME": "/h", "VMAVS_HOME": "/x"}), exists) != "" {
		t.Fatal("an explicit VMAVS_HOME needs no hint")
	}
	both := func(p string) bool { return true }
	if LegacyHint(env(map[string]string{"HOME": "/h"}), both) != "" {
		t.Fatal("no hint once the new home exists")
	}
}

func TestOpenCoreImageFallsBackToTheShellTreesPath(t *testing.T) {
	home := t.TempDir()
	p := Paths{Home: home}
	if got := p.OpenCoreImage(); got != filepath.Join(home, "build", "opencore.img") {
		t.Fatalf("with neither present, want the new path, got %q", got)
	}
	mustWrite(t, filepath.Join(home, "work", "opencore-p3.img"))
	if got := p.OpenCoreImage(); got != filepath.Join(home, "work", "opencore-p3.img") {
		t.Fatalf("legacy only: got %q", got)
	}
	mustWrite(t, filepath.Join(home, "build", "opencore.img"))
	if got := p.OpenCoreImage(); got != filepath.Join(home, "build", "opencore.img") {
		t.Fatalf("both: the new path wins, got %q", got)
	}
}

func TestMachineFlagsOverrideOnlyWhatWasSet(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	flagged := DefaultMachine()
	flagged.Register(fs)
	if err := fs.Parse([]string{"--memory", "8192"}); err != nil {
		t.Fatal(err)
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	fromImage := DefaultMachine()
	fromImage.NIC = "usb-net"
	fromImage.Override(flagged, func(n string) bool { return set[n] })
	if fromImage.MemoryMB != 8192 || fromImage.NIC != "usb-net" {
		t.Fatalf("got %+v", fromImage)
	}
}

func TestMachineValidateRefusesAnUnknownNIC(t *testing.T) {
	m := DefaultMachine()
	m.NIC = "rtl8139"
	if err := m.Validate(); err == nil || !strings.Contains(err.Error(), "e1000-82545em") {
		t.Fatalf("err = %v", err)
	}
}

func TestQEMUHonoursVMAVS_QEMU(t *testing.T) {
	if QEMU(env(nil)) != "qemu-system-x86_64" || QEMU(env(map[string]string{"VMAVS_QEMU": "/q"})) != "/q" {
		t.Fatal("VMAVS_QEMU not honoured")
	}
}

// mustWrite creates path, and its parent directories, as an empty file.
func mustWrite(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
}
