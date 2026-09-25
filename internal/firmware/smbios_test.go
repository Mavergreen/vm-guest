package firmware

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	vmguest "github.com/Mavergreen/vm-guest"
)

func embeddedConfig(t *testing.T) []byte {
	t.Helper()
	b, err := fs.ReadFile(vmguest.Files, "boot/config/config.plist")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTheTableIsTheLibrarysWordForWord(t *testing.T) {
	var got strings.Builder
	for _, m := range SMBIOSModels {
		got.WriteString(m.Model + "\t" + m.Status + "\t" + m.Evidence + "\n")
	}
	if want := shellLib(t, []string{"smbios.sh"}, "smbios_models"); got.String() != want {
		t.Fatalf("go:\n%s\nshell:\n%s", got.String(), want)
	}
}

func TestTheDefaultIsWhatConfigPlistShips(t *testing.T) {
	if DefaultSMBIOS != "iMac14,2" || ProductName(embeddedConfig(t)) != DefaultSMBIOS {
		t.Fatalf("default %s, config.plist %s", DefaultSMBIOS, ProductName(embeddedConfig(t)))
	}
}

func TestVerdictsAndManifestLinesMatchTheLibrary(t *testing.T) {
	for _, m := range []string{"iMac14,2", "MacPro5,1", "Macmini6,2"} {
		s, d := SMBIOSVerdict(m)
		if want := shellLib(t, []string{"smbios.sh"}, "smbios_verdict '"+m+"'"); s+"\t"+d+"\n" != want {
			t.Errorf("verdict %s:\n go:    %q\n shell: %q", m, s+"\t"+d, want)
		}
		if want := shellLib(t, []string{"smbios.sh"}, "smbios_manifest '"+m+"'"); SMBIOSManifest(m)+"\n" != want {
			t.Errorf("manifest %s differs", m)
		}
	}
	for _, st := range []string{"VERIFIED", "BOOTED", "PANICKED", "NOT-TESTED", "UNLISTED", "WEIRD"} {
		if want := shellLib(t, []string{"smbios.sh"}, "smbios_status_text '"+st+"'"); SMBIOSStatusText(st) != want {
			t.Errorf("status text %s differs", st)
		}
	}
}

func TestWellformedness(t *testing.T) {
	for m, ok := range map[string]bool{
		"iMac14,2": true, "MacPro5,1": true, "My_Model-1.0": true,
		"": false, "iMac<14>": false, "a b": false, "a&b": false, `a"b`: false, "a\nb": false,
		strings.Repeat("a", 64): true, strings.Repeat("a", 65): false,
	} {
		if SMBIOSWellformed(m) != ok {
			t.Errorf("%q: want %v", m, ok)
		}
	}
}

func TestSetProductNameMatchesTheLibraryByteForByte(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	for _, m := range []string{"MacPro5,1", "iMac14,2"} {
		got, err := SetProductName(embeddedConfig(t), m)
		if err != nil {
			t.Fatal(err)
		}
		want := shellLib(t, []string{"smbios.sh"}, "smbios_plist_set boot/config/config.plist '"+m+"'")
		if string(got) != want {
			t.Errorf("%s: the edit differs from smbios_plist_set", m)
		}
	}
}

// This needs no shell: SetProductName is pure Go. It must not be gated
// behind the bash skip above, or it never runs on a host without bash.
func TestSettingTheModelAlreadyThereChangesNoByte(t *testing.T) {
	if same, _ := SetProductName(embeddedConfig(t), DefaultSMBIOS); string(same) != string(embeddedConfig(t)) {
		t.Fatal("setting the model already there must not change a byte")
	}
}

// A comment (or anything else starting with "<") between the SystemProductName
// key and its <string> value defeats awk's `sub(/^[^<]*<string>/, ...)`:
// the substitution silently fails, and both smbios_plist_product_name and
// smbios_plist_set fall back to weaker behaviour. ProductName and
// SetProductName must mirror that exactly, byte for byte, rather than
// doing the sensible thing.
func TestProductNameAndSetProductNameMirrorAWKWhenACommentPrecedesTheStringTag(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	dir := t.TempDir()
	fixture := "<key>SystemProductName</key>\n\t<!-- c --><string>iMac14,2</string>\n"
	path := filepath.Join(dir, "fixture.plist")
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatal(err)
	}

	if got, want := ProductName([]byte(fixture))+"\n", shellLib(t, []string{"smbios.sh"}, "smbios_plist_product_name '"+path+"'"); got != want {
		t.Errorf("ProductName:\n go:    %q\n shell: %q", got, want)
	}

	got, err := SetProductName([]byte(fixture), "MacPro5,1")
	if err != nil {
		t.Fatal(err)
	}
	want := shellLib(t, []string{"smbios.sh"}, "smbios_plist_set '"+path+"' 'MacPro5,1'")
	if string(got) != want {
		t.Errorf("SetProductName:\n go:    %q\n shell: %q", got, want)
	}
}

// A named deviation from the shell: its awk has a latent bug
// here. Its first pattern matches ANY line containing the SystemProductName
// key -- including one that also carries a <string> on the same line -- and
// "next"s past it, so its second pattern (which rewrites the next line that
// contains <string>) fires on whatever key/value follows, not on
// SystemProductName's own value. Rather than port that bug, SetProductName
// refuses this shape outright.
func TestSetProductNameRefusesWhenKeyAndValueShareALine(t *testing.T) {
	plist := "<key>SystemProductName</key><string>x</string>\n"
	_, err := SetProductName([]byte(plist), "MacPro5,1")
	if err == nil || !strings.Contains(err.Error(), "share a line") {
		t.Fatalf("err = %v", err)
	}
}

func TestSetProductNameRefusesWhatItCannotDoSafely(t *testing.T) {
	if _, err := SetProductName(embeddedConfig(t), "a<b"); err == nil {
		t.Fatal("a malformed model must be refused")
	}
	two := strings.Replace(string(embeddedConfig(t)), "<key>SystemProductName</key>",
		"<key>SystemProductName</key>\n<string>x</string>\n<key>SystemProductName</key>", 1)
	if _, err := SetProductName([]byte(two), "MacPro5,1"); err == nil || !strings.Contains(err.Error(), "2 SystemProductName keys") {
		t.Fatalf("err = %v", err)
	}
	if _, err := SetProductName([]byte("<plist></plist>\n"), "MacPro5,1"); err == nil || !strings.Contains(err.Error(), "0 SystemProductName keys") {
		t.Fatalf("err = %v", err)
	}
}

func TestCheckNeverFails(t *testing.T) {
	var log strings.Builder
	logf := func(f string, a ...any) { log.WriteString(f + "\n") }
	for _, m := range []string{"iMac14,2", "MacPro5,1", "Macmini6,2"} {
		SMBIOSCheck(m, logf) // no error to return: the table is guidance
	}
	if !strings.Contains(log.String(), "warning") {
		t.Fatal("an unlisted or panicked model must warn")
	}
}
