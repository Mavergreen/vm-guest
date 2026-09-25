package media

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	vmguest "github.com/Mavergreen/vm-guest"
)

const firstbootEntry = "/System/Installation/Packages/mqg-firstboot.pkg"

func embedded(t *testing.T, name string) []byte {
	t.Helper()
	b, err := fs.ReadFile(vmguest.Files, name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestAddToCollection(t *testing.T) {
	orig := embedded(t, "image/autoinstall/OSInstall.collection")
	got, n, err := AddToCollection(orig, firstbootEntry)
	if err != nil {
		t.Fatal(err)
	}
	i := bytes.Index(orig, []byte("</array>"))
	want := string(orig[:i]) + "\t<string>" + firstbootEntry + "</string>\n" + string(orig[i:])
	if string(got) != want {
		t.Fatalf("collection\n%s\nwant\n%s", got, want)
	}
	if n != 3 {
		t.Fatalf("count %d, want 3", n)
	}

	again, n2, err := AddToCollection(got, firstbootEntry)
	if err != nil || !bytes.Equal(again, got) || n2 != 3 {
		t.Fatalf("adding it again: %d, %v, changed=%v", n2, err, !bytes.Equal(again, got))
	}

	if _, _, err := AddToCollection([]byte("<plist version=\"1.0\"><array/></plist>\n"), firstbootEntry); err == nil ||
		!strings.Contains(err.Error(), "</array>") {
		t.Fatalf("no </array>: err = %v", err)
	}

	unclosed := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<array>\n\t<string>/a.pkg</string>\n</plist>\n</array>\n"
	if _, _, err := AddToCollection([]byte(unclosed), firstbootEntry); err == nil ||
		!strings.Contains(err.Error(), "does not parse") {
		t.Fatalf("an <array> never closed before </plist>: err = %v", err)
	}
}

type entry struct {
	mode int64
	data string
}

// readTar is a tar's entries by name, checking what every entry must be:
// a regular file, owned by 0:0, with the fixed mtime.
func readTar(t *testing.T, b []byte) map[string]entry {
	t.Helper()
	got := map[string]entry{}
	tr := tar.NewReader(bytes.NewReader(b))
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return got
		}
		if err != nil {
			t.Fatal(err)
		}
		if h.Typeflag != tar.TypeReg {
			t.Errorf("%s: type %q, want a regular file", h.Name, h.Typeflag)
		}
		if h.Uid != 0 || h.Gid != 0 {
			t.Errorf("%s: owner %d:%d, want 0:0", h.Name, h.Uid, h.Gid)
		}
		if !h.ModTime.Equal(time.Unix(0, 0)) {
			t.Errorf("%s: mtime %v, want the epoch", h.Name, h.ModTime)
		}
		data, err := io.ReadAll(tr)
		if err != nil {
			t.Fatal(err)
		}
		if _, dup := got[h.Name]; dup {
			t.Errorf("%s is in the tar twice", h.Name)
		}
		got[h.Name] = entry{h.Mode, string(data)}
	}
}

func writeFile(t *testing.T, path, data string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestTheInjectablesTar(t *testing.T) {
	dir := t.TempDir()
	p := writeFile(t, filepath.Join(dir, "firstboot-built.pkg"), "xar!firstboot")
	a := writeFile(t, filepath.Join(dir, "a", "openssh.pkg"), "xar!a")
	b := writeFile(t, filepath.Join(dir, "b", "other.pkg"), "xar!b")
	var buf bytes.Buffer
	if err := (Injectables{Autoinstall: true, FirstbootPkg: p, ExtraPkgs: []string{a, b}}).WriteTar(&buf, nil); err != nil {
		t.Fatal(err)
	}
	collection, _, err := AddToCollection(embedded(t, "image/autoinstall/OSInstall.collection"), firstbootEntry)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]entry{
		"private/etc/rc.cdrom.local":                             {0o755, string(embedded(t, "image/autoinstall/autoinstall.sh"))},
		"System/Installation/Packages/Extras/minstallconfig.xml": {0o644, string(embedded(t, "image/autoinstall/minstallconfig.xml"))},
		"System/Installation/Packages/OSInstall.collection":      {0o644, string(collection)},
		"System/Installation/Packages/mqg-firstboot.pkg":         {0o644, "xar!firstboot"},
		"System/Installation/Packages/openssh.pkg":               {0o644, "xar!a"},
		"System/Installation/Packages/other.pkg":                 {0o644, "xar!b"},
	}
	got := readTar(t, buf.Bytes())
	if len(got) != len(want) {
		var names []string
		for n := range got {
			names = append(names, n)
		}
		sort.Strings(names)
		t.Fatalf("the tar holds %q", names)
	}
	for name, w := range want {
		g, ok := got[name]
		switch {
		case !ok:
			t.Errorf("%s is not in the tar", name)
		case g.mode != w.mode:
			t.Errorf("%s: mode %o, want %o", name, g.mode, w.mode)
		case g.data != w.data:
			t.Errorf("%s: contents\n%s\nwant\n%s", name, g.data, w.data)
		}
	}

	buf.Reset()
	if err := (Injectables{Autoinstall: true}).WriteTar(&buf, nil); err != nil {
		t.Fatal(err)
	}
	got = readTar(t, buf.Bytes())
	if c := got["System/Installation/Packages/OSInstall.collection"].data; c != string(embedded(t, "image/autoinstall/OSInstall.collection")) {
		t.Fatalf("without a first-boot package the collection changed:\n%s", c)
	}
	if len(got) != 3 {
		t.Fatalf("without packages the tar holds %d files, want 3", len(got))
	}

	buf.Reset()
	if err := (Injectables{}).WriteTar(&buf, nil); err != nil {
		t.Fatal(err)
	}
	if n := len(readTar(t, buf.Bytes())); n != 0 {
		t.Fatalf("without --autoinstall the tar holds %d files", n)
	}
	if buf.Len() != 1024 || !bytes.Equal(buf.Bytes(), make([]byte, 1024)) {
		t.Fatalf("without --autoinstall the tar is %d bytes, not a bare end-of-archive", buf.Len())
	}
}

// The guest untars the injectables with busybox's tar, not Go's reader.
func TestBusyboxTarReadsTheInjectables(t *testing.T) {
	need(t, "busybox")
	dir := t.TempDir()
	long := writeFile(t, filepath.Join(dir, strings.Repeat("x", 90)+".pkg"), "xar!long")
	longer := writeFile(t, filepath.Join(dir, strings.Repeat("y", 200)+".pkg"), "xar!longer")
	var buf bytes.Buffer
	if err := (Injectables{Autoinstall: true, ExtraPkgs: []string{long, longer}}).WriteTar(&buf, nil); err != nil {
		t.Fatal(err)
	}
	tarFile := writeFile(t, filepath.Join(dir, "inject.tar"), buf.String())
	out, err := exec.Command("busybox", "tar", "tf", tarFile).CombinedOutput()
	if err != nil {
		t.Fatalf("busybox tar tf: %v\n%s", err, out)
	}
	var names []string
	for n := range readTar(t, buf.Bytes()) {
		names = append(names, n)
	}
	sort.Strings(names)
	listed := strings.Fields(string(out))
	sort.Strings(listed)
	if strings.Join(listed, "\n") != strings.Join(names, "\n") {
		t.Fatalf("busybox tar lists\n%s\nwant\n%s", strings.Join(listed, "\n"), strings.Join(names, "\n"))
	}
}

func TestTwoExtrasWithOneBasenameAreRefused(t *testing.T) {
	dir := t.TempDir()
	a := writeFile(t, filepath.Join(dir, "a", "same.pkg"), "xar!a")
	b := writeFile(t, filepath.Join(dir, "b", "same.pkg"), "xar!b")
	err := (Injectables{Autoinstall: true, ExtraPkgs: []string{a, b}}).WriteTar(io.Discard, nil)
	if err == nil || !strings.Contains(err.Error(), a) || !strings.Contains(err.Error(), b) {
		t.Fatalf("err = %v, want one naming %s and %s", err, a, b)
	}
}
