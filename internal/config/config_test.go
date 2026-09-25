package config

import (
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

// TestLegacyHintIsAboutImagesNotDirectories: the hint turns on whether
// the old home's images/ holds an image and the new one's holds none --
// never on whether the new home merely exists, since any vmavs fetch
// (even a failed one) could create it and silence the hint for good.
func TestLegacyHintIsAboutImagesNotDirectories(t *testing.T) {
	old := "/h/.local/share/mavericks-qemu-guest"
	cur := "/h/.local/share/vmavs"
	oldImages := func(dir string) bool { return dir == old+"/images" }
	nowhere := func(string) bool { return false }

	hint := LegacyHint(env(map[string]string{"HOME": "/h"}), oldImages, nowhere)
	if !strings.Contains(hint, "export VMAVS_HOME="+old) || !strings.Contains(hint, "mv "+old+" "+cur) {
		t.Fatalf("hint = %q", hint)
	}
	if LegacyHint(env(map[string]string{"HOME": "/h", "VMAVS_HOME": "/x"}), oldImages, nowhere) != "" {
		t.Fatal("an explicit VMAVS_HOME needs no hint")
	}
	if LegacyHint(env(map[string]string{"HOME": "/h"}), nowhere, func(p string) bool { return p == old }) != "" {
		t.Fatal("an old home with no images needs no hint")
	}
	both := func(string) bool { return true }
	if LegacyHint(env(map[string]string{"HOME": "/h"}), both, both) != "" {
		t.Fatal("no hint once the new home has an image of its own")
	}
}

// TestLegacyHintWhenTheNewHomeExistsSaysOnlyExport: once the new home
// exists (a vmavs fetch made it, say), it may hold hard links into the
// old one, so moving the old home over it is not advice to give.
func TestLegacyHintWhenTheNewHomeExistsSaysOnlyExport(t *testing.T) {
	old := "/h/.local/share/mavericks-qemu-guest"
	cur := "/h/.local/share/vmavs"
	oldImages := func(dir string) bool { return dir == old+"/images" }
	curExists := func(p string) bool { return p == cur }
	hint := LegacyHint(env(map[string]string{"HOME": "/h"}), oldImages, curExists)
	if !strings.Contains(hint, "export VMAVS_HOME="+old) {
		t.Fatalf("hint = %q, want the export advice", hint)
	}
	if strings.Contains(hint, "mv ") {
		t.Fatalf("hint = %q, must not suggest mv once %s exists", hint, cur)
	}
}

func TestCacheFileIsContentAddressed(t *testing.T) {
	p := Paths{Home: "/h"}
	if got := p.CacheFile("abc123", "x.zip"); got != filepath.Join("/h", "cache", "abc123", "x.zip") {
		t.Fatalf("got %q", got)
	}
}

func TestOpenSSHSumsIsKeyedByTagNotByServer(t *testing.T) {
	p := Paths{Home: "/h"}
	if got := p.OpenSSHSums("10.5p1-mavericks.2"); got != filepath.Join("/h", "cache", "openssh", "10.5p1-mavericks.2", "SHA256SUMS") {
		t.Fatalf("got %q", got)
	}
}

func TestLegacyHome(t *testing.T) {
	if got := LegacyHome(env(map[string]string{"HOME": "/h"})); got != "/h/.local/share/mavericks-qemu-guest" {
		t.Fatalf("got %q", got)
	}
	if got := LegacyHome(env(nil)); got != "" {
		t.Fatalf("without HOME, want \"\", got %q", got)
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

// TestShellDownloadPaths: where the shell tree keeps what vmavs fetch
// adopts, all in one place for phase 6 to delete.
func TestShellDownloadPaths(t *testing.T) {
	p := Paths{Home: "/h"}
	for got, want := range map[string]string{
		p.ShellESD():              "/h/media/InstallESD.dmg",
		p.ShellOpenSSH("9.9p1-x"): "/h/openssh/9.9p1-x",
		p.ShellUpdates():          "/h/updates",
	} {
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
}

func TestOpenCoreImageOutIgnoresTheShellTreesPath(t *testing.T) {
	home := t.TempDir()
	p := Paths{Home: home}
	if err := os.MkdirAll(p.Work(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p.Work(), "opencore-p3.img"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := p.OpenCoreImageOut(); got != filepath.Join(home, "build", "opencore.img") {
		t.Fatalf("got %s", got)
	}
}

func TestMediaPaths(t *testing.T) {
	p := Paths{Home: "/h"}
	if p.InstallerMedia() != "/h/build/installer-media.img" || p.MediaWork() != "/h/work/media" {
		t.Fatal(p.InstallerMedia(), p.MediaWork())
	}
}
