package firmware

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// repo is the repository root, for the parity tests that run the shell
// tree's scripts.
func repo(t *testing.T) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..")
}

// script runs one of the shell tree's scripts with args and returns its
// stdout, skipping when bash is absent.
func script(t *testing.T, path string, args ...string) string {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	cmd := exec.Command("bash", append([]string{filepath.Join(repo(t), path)}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s %v: %v", path, args, err)
	}
	return string(out)
}

func lines(s string) []string { return strings.Split(strings.TrimRight(s, "\n"), "\n") }

func TestPinsMatchTheScripts(t *testing.T) {
	var pinLines []string
	for _, p := range OpenCorePins() {
		pinLines = append(pinLines, p.Source+"\t"+p.Commit)
	}
	checks := []struct {
		name string
		got  []string
		want string
	}{
		{"--show-pins", pinLines, script(t, "boot/build-opencore.sh", "--show-pins")},
		{"--list-artifacts", ShipNames(), script(t, "boot/build-opencore.sh", "--list-artifacts")},
		{"--udk-commit", []string{AudkCommit}, script(t, "boot/build-opencore.sh", "--udk-commit")},
		{"--build-options", []string{strings.ReplaceAll(BuildOptions(), "\t", " ")}, script(t, "boot/build-opencore.sh", "--build-options")},
		{"ovmf --list-artifacts", OVMFFiles, script(t, "boot/build-ovmf.sh", "--list-artifacts")},
		{"ovmf --show-build", []string{OVMFDsc + "\t" + Arch + "\t" + EDKToolchain + "\t" + Target}, script(t, "boot/build-ovmf.sh", "--show-build")},
		{"fetch-kexts --list", kextNames(), script(t, "boot/fetch-kexts.sh", "--list")},
		{"fetch-opencorepkg --show-version", []string{"OpenCorePkg " + OCVersion}, script(t, "boot/fetch-opencorepkg.sh", "--show-version")},
		{"build-efi-image --list-contents", efiContents(), script(t, "boot/build-efi-image.sh", "--list-contents")},
		{"fetch-edk2 --list-sources", pinSources(), script(t, "boot/fetch-edk2.sh", "--list-sources")},
	}
	for _, c := range checks {
		if strings.Join(c.got, "\n") != strings.Join(lines(c.want), "\n") {
			t.Errorf("%s:\n go:    %q\n shell: %q", c.name, c.got, lines(c.want))
		}
	}
}

func kextNames() (n []string) {
	for _, k := range Kexts {
		n = append(n, k.Name)
	}
	return n
}

func pinSources() (n []string) {
	for _, p := range OpenCorePins() {
		n = append(n, p.Source)
	}
	return n
}

// efiContents is what build-efi-image.sh --list-contents prints: the
// artifacts in image order, the kext bundles, then the config.
func efiContents() []string {
	c := append([]string{"BOOTx64.efi", "OpenCore.efi"}, EFIDrivers...)
	for _, k := range Kexts {
		c = append(c, k.Name+".kext")
	}
	return append(c, "config.plist")
}

func TestEFIImageSizeMatchesTheScript(t *testing.T) {
	src, err := os.ReadFile(filepath.Join(repo(t), "boot/build-efi-image.sh"))
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("\nIMAGE_MIB=%d\n", EFIImageMiB)
	if !strings.Contains(string(src), want) {
		t.Fatalf("boot/build-efi-image.sh does not say %q", strings.TrimSpace(want))
	}
}

func TestSourceNamesAreThePins(t *testing.T) {
	want := append(pinSources(), "opencorepkg-src")
	if strings.Join(OpenCoreSources(), " ") != strings.Join(want, " ") {
		t.Fatalf("OpenCoreSources = %v", OpenCoreSources())
	}
	all := append(append([]string{}, OpenCoreSources()...), KextSources()...)
	if strings.Join(SourceNames(), " ") != strings.Join(all, " ") {
		t.Fatalf("SourceNames = %v", SourceNames())
	}
}

func TestEveryPinIsInTheEmbeddedRegistryWithItsCommit(t *testing.T) {
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	if err := CheckPins(reg); err != nil {
		t.Fatal(err)
	}
}

func TestCheckPinsRefusesAURLWithoutItsCommit(t *testing.T) {
	reg := registryWith(t, "audk-src", "https://example.test/archive/0000.tar.gz", strings.Repeat("a", 64))
	err := CheckPins(reg)
	if err == nil || !strings.Contains(err.Error(), "audk-src") || !strings.Contains(err.Error(), AudkCommit) {
		t.Fatalf("err = %v", err)
	}
}

func TestCheckPinsRefusesUnpinned(t *testing.T) {
	reg := registryWith(t, "audk-src", "https://example.test/archive/"+AudkCommit+".tar.gz", "TOFU")
	if err := CheckPins(reg); err == nil || !strings.Contains(err.Error(), "audk-src") {
		t.Fatalf("err = %v", err)
	}
}

func TestEveryPinIsAnImmutableURL(t *testing.T) {
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range SourceNames() {
		s, err := reg.Lookup(n)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range []string{"refs/heads", "/master/", "/main/"} {
			if strings.Contains(s.URL, bad) {
				t.Errorf("%s fetches from a mutable branch: %s", n, s.URL)
			}
		}
	}
}

// registryWith is the embedded registry with one row replaced, so a test
// can break exactly one pin.
func registryWith(t *testing.T, name, url, sha string) *pins.Registry {
	t.Helper()
	reg, err := pins.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	b.WriteString(name + "\t" + url + "\t" + sha + "\n") // first match wins
	for _, r := range reg.Rows() {
		b.WriteString(r.Name + "\t" + r.URL + "\t" + r.SHA256 + "\n")
	}
	out, err := pins.Parse(strings.NewReader(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	return out
}
