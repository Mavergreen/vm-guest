package firmware

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/diskimg"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// shipped makes build/ look as OpenCore and Kexts leave it: five fake
// artifacts with their SHA256SUMS, and the two kext bundles. Neither
// build tool is needed.
func shipped(f *fixture) {
	f.t.Helper()
	art := filepath.Join(f.home, "build", "artifacts")
	if err := os.MkdirAll(art, 0o755); err != nil {
		f.t.Fatal(err)
	}
	for _, n := range ShipNames() {
		if err := os.WriteFile(filepath.Join(art, n), []byte("fake "+n), 0o644); err != nil {
			f.t.Fatal(err)
		}
	}
	if err := writeSums(art, ShipNames()); err != nil {
		f.t.Fatal(err)
	}
	if _, err := f.b.Kexts(context.Background(), f.in); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) efiImage(model string) (string, error) {
	return f.b.EFIImage(context.Background(), model)
}

// imageContents is an image's GPT partitions and its FAT, read back.
type imageContents struct {
	parts []diskimg.Partition
	fat   *diskimg.FATReader
	paths []string // every walked path, sorted
	files map[string][]byte
}

func readEFI(t *testing.T, img string) imageContents {
	t.Helper()
	fh, err := os.Open(img)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { fh.Close() })
	fi, err := fh.Stat()
	if err != nil {
		t.Fatal(err)
	}
	_, parts, err := diskimg.ReadGPT(fh, uint64(fi.Size())/diskimg.SectorSize)
	if err != nil {
		t.Fatal(err)
	}
	fat, err := diskimg.OpenFAT(fh, 2048*512)
	if err != nil {
		t.Fatal(err)
	}
	c := imageContents{parts: parts, fat: fat, files: map[string][]byte{}}
	if err := fat.Walk(func(p string, e diskimg.DirEntry) error {
		c.paths = append(c.paths, p)
		if !e.Dir {
			b, err := fat.ReadFile(p)
			if err != nil {
				return err
			}
			c.files[p] = b
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	sort.Strings(c.paths)
	return c
}

func TestFitsDemandsHeadroomLikeEfiFits(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	cases := []struct {
		mib     int
		payload int64
		want    bool
	}{
		{192, 0, true}, {192, 98041855, true}, {192, 98041856, true}, {192, 98041857, false},
		{192, 200000000, false}, {5, 1, false}, {4, 0, false},
	}
	for _, c := range cases {
		got := Fits(c.mib, c.payload)
		if got != c.want {
			t.Errorf("Fits(%d, %d) = %v, want %v", c.mib, c.payload, got, c.want)
		}
		cmd := exec.Command("bash", "-c", ". lib/common.sh; . lib/efi.sh; efi_fits \"$1\" \"$2\"", "efi_fits",
			strconv.Itoa(c.mib), strconv.FormatInt(c.payload, 10))
		cmd.Dir = repo(t)
		err := cmd.Run()
		var ee *exec.ExitError
		if err != nil && !errors.As(err, &ee) {
			t.Fatal(err)
		}
		if shell := err == nil; shell != got {
			t.Errorf("Fits(%d, %d) = %v, efi_fits says %v", c.mib, c.payload, got, shell)
		}
	}
}

func TestKextsUnpackEachBundleWithItsBinary(t *testing.T) {
	f := newFixture(t)
	got, err := f.b.Kexts(context.Background(), f.in)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(f.home, "build", "kexts")
	want := []string{filepath.Join(dir, "Lilu.kext"), filepath.Join(dir, "VirtualSMC.kext")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Kexts returned %v, want %v", got, want)
	}
	for _, k := range Kexts {
		bundle := filepath.Join(dir, k.Name+".kext")
		if _, err := os.Stat(filepath.Join(bundle, "Contents", "Info.plist")); err != nil {
			t.Error(err)
		}
		fi, err := os.Stat(filepath.Join(bundle, "Contents", "MacOS", k.Name))
		if err != nil || fi.Mode().Perm()&0o100 == 0 {
			t.Errorf("%s's binary: %v, %v", k.Name, fi, err)
		}
	}
}

func TestKextsKeepAnExistingBundle(t *testing.T) {
	f := newFixture(t)
	if _, err := f.b.Kexts(context.Background(), f.in); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(f.home, "build", "kexts", "Lilu.kext", "Contents", "sentinel")
	if err := os.WriteFile(sentinel, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := f.b.Kexts(context.Background(), f.in); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Errorf("the bundle was unpacked again: %v", err)
	}
}

func TestKextsNameTheMissingBinary(t *testing.T) {
	f := newFixture(t)
	z := makeZip(t, t.TempDir(), "Lilu-RELEASE.zip", entry{name: "Lilu.kext/Contents/Info.plist", body: "plist Lilu"})
	f.repin("lilu-release", z)
	_, err := f.b.Kexts(context.Background(), f.in)
	want := filepath.Join(f.home, "build", "kexts", "Lilu.kext") + " is not a kext bundle: no Contents/MacOS/Lilu"
	if err == nil || err.Error() != want {
		t.Fatalf("err = %v\nwant %s", err, want)
	}
}

func TestEFIImageLayout(t *testing.T) {
	f := newFixture(t)
	shipped(f)
	img, err := f.efiImage("")
	if err != nil {
		t.Fatalf("EFIImage: %v\n%s", err, f.log.String())
	}
	if want := filepath.Join(f.home, "build", "opencore.img"); img != want {
		t.Errorf("EFIImage returned %s, want %s", img, want)
	}
	if b, _ := os.ReadFile(img + ".sha256"); string(b) != sha(t, img)+"\n" {
		t.Errorf("the sidecar holds %q", b)
	}
	c := readEFI(t, img)
	if len(c.parts) != 1 {
		t.Fatalf("%d partitions, want 1", len(c.parts))
	}
	p := c.parts[0]
	if p.Type != diskimg.TypeEFISystem || p.FirstLBA != 2048 || p.LastLBA != 393182 || p.Name != "EFI" {
		t.Errorf("partition %+v", p)
	}
	var want []string
	want = append(want, "/EFI", "/EFI/BOOT", "/EFI/OC", "/EFI/OC/Drivers", "/EFI/OC/Kexts", "/EFI/OC/ACPI",
		"/EFI/OC/Tools", "/EFI/OC/Resources", "/EFI/BOOT/BOOTx64.efi", "/EFI/OC/OpenCore.efi",
		"/EFI/OC/Drivers/OpenRuntime.efi", "/EFI/OC/Drivers/OpenPartitionDxe.efi", "/EFI/OC/Drivers/OpenHfsPlus.efi",
		"/EFI/OC/config.plist")
	for _, k := range []string{"Lilu", "VirtualSMC"} {
		b := "/EFI/OC/Kexts/" + k + ".kext"
		want = append(want, b, b+"/Contents", b+"/Contents/MacOS", b+"/Contents/Info.plist", b+"/Contents/MacOS/"+k)
	}
	sort.Strings(want)
	if !reflect.DeepEqual(c.paths, want) {
		t.Errorf("the image holds\n%s\nwant\n%s", strings.Join(c.paths, "\n"), strings.Join(want, "\n"))
	}
	if string(c.files["/EFI/OC/config.plist"]) != string(embeddedConfig(t)) {
		t.Errorf("config.plist is not the repository's")
	}
	if string(c.files["/EFI/BOOT/BOOTx64.efi"]) != "fake BOOTx64.efi" {
		t.Errorf("BOOTx64.efi holds %q", c.files["/EFI/BOOT/BOOTx64.efi"])
	}
	for _, p := range c.paths {
		if strings.Contains(p, "HfsPlusLegacy") {
			t.Errorf("the image holds %s", p)
		}
	}
}

func TestEFIImageIsDeterministic(t *testing.T) {
	f := newFixture(t)
	shipped(f)
	img, err := f.efiImage("")
	if err != nil {
		t.Fatal(err)
	}
	first := sha(t, img)
	for _, p := range []string{img, img + ".sha256"} {
		if err := os.Remove(p); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.efiImage(""); err != nil {
		t.Fatal(err)
	}
	if again := sha(t, img); again != first {
		t.Errorf("two builds differ: %s, then %s", first, again)
	}
}

func TestEFIImageRefusesArtifactsThatDoNotMatchSHA256SUMS(t *testing.T) {
	f := newFixture(t)
	shipped(f)
	if err := os.WriteFile(filepath.Join(f.home, "build", "artifacts", "OpenCore.efi"), []byte("tampered"), 0o644); err != nil {
		t.Fatal(err)
	}
	img := filepath.Join(f.home, "build", "opencore.img")
	if err := os.WriteFile(img, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := f.efiImage("")
	if err == nil || !strings.Contains(err.Error(), "SHA256SUMS") {
		t.Fatalf("err = %v", err)
	}
	if b, _ := os.ReadFile(img); string(b) != "old" {
		t.Errorf("the previous image was replaced")
	}
}

func TestEFIImageNamesTheMissingPiece(t *testing.T) {
	f := newFixture(t)
	_, err := f.efiImage("")
	art := filepath.Join(f.home, "build", "artifacts")
	if want := "no artifacts at " + art + " -- run 'vmavs firmware opencore' first"; err == nil || err.Error() != want {
		t.Fatalf("err = %v\nwant %s", err, want)
	}

	g := newFixture(t)
	shipped(g)
	bundle := filepath.Join(g.home, "build", "kexts", "VirtualSMC.kext")
	if err := os.Remove(filepath.Join(bundle, "Contents", "Info.plist")); err != nil {
		t.Fatal(err)
	}
	_, err = g.efiImage("")
	if err == nil || !strings.Contains(err.Error(), bundle) || !strings.Contains(err.Error(), "Contents/Info.plist") ||
		!strings.Contains(err.Error(), "vmavs firmware efi") {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(g.home, "build", "opencore.img")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("an image was written anyway: %v", err)
	}
}

func TestEFIImageWithAnotherSMBIOS(t *testing.T) {
	want, err := SetProductName(embeddedConfig(t), "MacPro5,1")
	if err != nil {
		t.Fatal(err)
	}

	f := newFixture(t)
	shipped(f)
	if err := os.MkdirAll(filepath.Dir(f.b.ocvalidate()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.b.ocvalidate(), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	img, err := f.efiImage("MacPro5,1")
	if err != nil {
		t.Fatalf("EFIImage: %v\n%s", err, f.log.String())
	}
	derived := filepath.Join(f.home, "build", "config", "config-MacPro5,1.plist")
	if b, _ := os.ReadFile(derived); string(b) != string(want) {
		t.Errorf("%s is not SetProductName's", derived)
	}
	if c := readEFI(t, img); string(c.files["/EFI/OC/config.plist"]) != string(want) {
		t.Errorf("the image's config.plist is not the derived one")
	}
	cs := f.calls(f.b.ocvalidate())
	if len(cs) != 1 || !reflect.DeepEqual(cs[0].Args, []string{derived}) {
		t.Errorf("ocvalidate calls: %v", cs)
	}

	f.ocvalidate = &proc.ExitError{Cmd: f.b.ocvalidate(), Code: 1}
	if _, err := f.efiImage("MacPro5,1"); err == nil || !strings.Contains(err.Error(), "ocvalidate rejected the derived config") {
		t.Errorf("err = %v", err)
	}

	g := newFixture(t)
	shipped(g)
	if _, err := g.efiImage("MacPro5,1"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(g.log.String(), "shipping the derived config unvalidated") {
		t.Errorf("no warning:\n%s", g.log.String())
	}
}

func TestEFIImageRefusesAMalformedSMBIOS(t *testing.T) {
	f := newFixture(t)
	shipped(f)
	_, err := f.efiImage("a<b")
	if err == nil || !strings.Contains(err.Error(), "a<b") {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(f.home, "build", "opencore.img")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("an image was written: %v", err)
	}
}

// TestEFIImageMatchesBuildEFIImageSh builds the image both ways from the
// same artifacts and kexts and holds them equal where they should be.
//
// The differences that are deliberate (rulings 5 and 6), and so not
// compared:
//   - the GPT disk and partition GUIDs: sgdisk's are random, ours derived;
//   - the volume serial number: mformat's is random, ours derived;
//   - the OEM name: mformat writes MTOO4043, we write MSWIN4.1;
//   - hidden sectors: mformat writes 0, we write the partition's LBA;
//   - timestamps: mtools' are now, ours 1980-01-01;
//   - short-name tails: mtools and we may number an 8.3 alias differently,
//     so paths are compared by long name.
//
// mformat's boot-code stub is not compared either: nothing reads it.
func TestEFIImageMatchesBuildEFIImageSh(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("build-efi-image.sh uses GNU-only stat -c, du -sb and find -printf")
	}
	for _, tool := range []string{"bash", "sgdisk", "mformat", "mmd", "mcopy", "mdir", "truncate", "sha256sum"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip(tool + " not installed")
		}
	}
	f := newFixture(t)
	shipped(f)
	shellImg := filepath.Join(f.home, "shell.img")
	cmd := exec.Command("bash", "boot/build-efi-image.sh", shellImg)
	cmd.Dir = repo(t)
	cmd.Env = append(os.Environ(), "MQG_IMAGE_DIR="+f.home, "MQG_BUILD_DIR="+filepath.Join(f.home, "build"),
		"MQG_SMBIOS=", "MTOOLS_SKIP_CHECK=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build-efi-image.sh: %v\n%s", err, out)
	}
	goImg, err := f.efiImage("")
	if err != nil {
		t.Fatal(err)
	}

	sh, g := readEFI(t, shellImg), readEFI(t, goImg)
	if len(sh.parts) != 1 || len(g.parts) != 1 {
		t.Fatalf("partitions: shell %d, go %d", len(sh.parts), len(g.parts))
	}
	sp, gp := sh.parts[0], g.parts[0]
	if sp.FirstLBA != gp.FirstLBA || sp.LastLBA != gp.LastLBA || sp.Type != gp.Type || sp.Name != gp.Name {
		t.Errorf("partition: shell %+v, go %+v", sp, gp)
	}
	sg, gg := sh.fat.G, g.fat.G
	sg.HiddenSectors, gg.HiddenSectors = 0, 0
	if sg != gg {
		t.Errorf("FAT geometry: shell %+v, go %+v", sh.fat.G, g.fat.G)
	}
	if sh.fat.Label != g.fat.Label {
		t.Errorf("volume label: shell %q, go %q", sh.fat.Label, g.fat.Label)
	}
	if !reflect.DeepEqual(sh.paths, g.paths) {
		t.Errorf("paths: shell\n%s\ngo\n%s", strings.Join(sh.paths, "\n"), strings.Join(g.paths, "\n"))
	}
	for p, b := range sh.files {
		if string(g.files[p]) != string(b) {
			t.Errorf("%s: shell %d bytes, go %d bytes, and they differ", p, len(b), len(g.files[p]))
		}
	}
	t.Logf("shell and go agree: partition %d-%d %q, geometry %+v (hidden: shell %d, go %d), %d paths, %d files",
		sp.FirstLBA, sp.LastLBA, sp.Name, gg, sh.fat.G.HiddenSectors, g.fat.G.HiddenSectors, len(g.paths), len(g.files))
	if b, _ := os.ReadFile(shellImg + ".sha256"); string(b) != sha(t, shellImg)+"\n" {
		t.Errorf("the shell's sidecar is not bare hex and a newline: %q", b)
	}
}
