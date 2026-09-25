package payload

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"testing"
)

func repoRoot() string {
	_, here, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(here), "..", "..")
}

func gunzip(t *testing.T, b []byte) []byte {
	r, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestCPIOEntriesCarryFileTypeBits(t *testing.T) {
	// Without them PackageKit's cpio reader fails "copier error 21 ... bad
	// file format" (NOTES.md, P4): 040755 and 100755, never 000755.
	b := makeODC([]cpioEntry{{Name: ".", Mode: 0o755, Dir: true}, {Name: "./postinstall", Mode: 0o755, Data: []byte("#!/bin/sh\n")}})
	es, err := readODC(b)
	if err != nil || len(es) != 2 {
		t.Fatalf("%+v %v", es, err)
	}
	if !bytes.Contains(b, []byte("070707000000000001040755")) || !bytes.Contains(b, []byte("000002100755")) || !bytes.Contains(b, []byte("TRAILER!!!")) {
		t.Fatalf("headers: %q", b[:160])
	}
}

func TestTheXarHeaderAndTOCChecksum(t *testing.T) {
	blob, err := flatPackage([]byte("#!/bin/sh\nexit 0\n"), "com.mqg.firstboot", "1.0")
	if err != nil {
		t.Fatal(err)
	}
	if string(blob[:4]) != "xar!" || binary.BigEndian.Uint16(blob[4:]) != 28 || binary.BigEndian.Uint16(blob[6:]) != 1 || binary.BigEndian.Uint32(blob[24:]) != 1 {
		t.Fatalf("header % x", blob[:28])
	}
	toc, members, err := readXar(blob)
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 2 || members["PackageInfo"] == nil || members["Scripts"] == nil {
		t.Fatalf("members %v", members)
	}
	if !regexp.MustCompile(`<creation-time>1970-01-01T00:00:00</creation-time>`).MatchString(toc) {
		t.Fatal("creation-time is not the fixed epoch")
	}
}

func TestTheSameInputsGiveAByteIdenticalPackage(t *testing.T) {
	a, _ := flatPackage([]byte("x\n"), "com.mqg.firstboot", "1.0")
	b, _ := flatPackage([]byte("x\n"), "com.mqg.firstboot", "1.0")
	if !bytes.Equal(a, b) {
		t.Fatal("two builds differ")
	}
}

// Structural parity with image/payload/mkflatpkg.py: the same TOC (bar
// the Scripts member's compressed length and checksums), the same
// PackageInfo, the same decompressed cpio.
func TestSameContentsAsMkflatpkg(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available; CI runs this")
	}
	dir := t.TempDir()
	scripts := filepath.Join(dir, "scripts")
	os.MkdirAll(scripts, 0o755)
	post := []byte("#!/bin/sh\necho hello\nexit 0\n")
	os.WriteFile(filepath.Join(scripts, "postinstall"), post, 0o755)
	pyOut := filepath.Join(dir, "py.pkg")
	cmd := exec.Command("python3", filepath.Join(repoRoot(), "image", "payload", "mkflatpkg.py"),
		"--scripts", scripts, "--identifier", "com.mqg.firstboot", "--version", "1.0", "--out", pyOut)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	py, _ := os.ReadFile(pyOut)
	gob, err := flatPackage(post, "com.mqg.firstboot", "1.0")
	if err != nil {
		t.Fatal(err)
	}
	pyTOC, pyM, err := readXar(py)
	if err != nil {
		t.Fatal(err)
	}
	goTOC, goM, _ := readXar(gob)
	if !bytes.Equal(pyM["PackageInfo"], goM["PackageInfo"]) {
		t.Fatalf("PackageInfo differs:\n%s\n%s", pyM["PackageInfo"], goM["PackageInfo"])
	}
	if !bytes.Equal(gunzip(t, pyM["Scripts"]), gunzip(t, goM["Scripts"])) {
		t.Fatal("decompressed Scripts differ")
	}
	norm := regexp.MustCompile(`(<(length|size|extracted-checksum|archived-checksum)[^>]*>)[^<]*`)
	if norm.ReplaceAllString(pyTOC, "$1*") != norm.ReplaceAllString(goTOC, "$1*") {
		t.Fatalf("TOCs differ beyond lengths and checksums:\n%s\n---\n%s", pyTOC, goTOC)
	}
	t.Logf("compressed sizes: python %d bytes, go %d bytes (deflate implementations differ)", len(py), len(gob))
}
