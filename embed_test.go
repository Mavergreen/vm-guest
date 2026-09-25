package vmguest

import (
	"bufio"
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The embedded copies must be the files in this tree: a binary built from
// this commit carries exactly what this commit says.
func TestEmbeddedFilesAreTheFilesOnDisk(t *testing.T) {
	want := []string{
		"assets/pins/sources.tsv",
		"components/openssh/version",
		"boot/config/config.plist",
		"media/apple-packages.sha256",
		"image/payload/firstboot.sh",
		"image/payload/postinstall",
		"image/payload/com.mqg.firstboot.plist",
		"boot/patches/0001-build_oc-source-pinned-efibuild.patch",
		"boot/patches/0002-ovmf-pin-the-c-dialect.patch",
		"boot/patches/0003-firmware-drop-werror.patch",
		"media/privops/assemble.sh",
		"media/privops/content-digest.sh",
		"media/privops/extract-basesystem.sh",
		"media/privops/fix-ownership.sh",
		"media/privops/verify-packages.sh",
		"image/autoinstall/autoinstall.sh",
		"image/autoinstall/minstallconfig.xml",
		"image/autoinstall/OSInstall.collection",
		"assets/privops/init.sh",
	}
	for _, p := range want {
		emb, err := fs.ReadFile(Files, p)
		if err != nil {
			t.Errorf("%s not embedded: %v", p, err)
			continue
		}
		disk, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(emb, disk) || len(emb) == 0 {
			t.Errorf("%s: embedded copy differs from the file on disk", p)
		}
	}
}

// Every patch on disk must be embedded, so a new one under boot/patches
// cannot be forgotten from the //go:embed line.
func TestEveryPatchOnDiskIsEmbedded(t *testing.T) {
	disk, err := filepath.Glob("boot/patches/*.patch")
	if err != nil || len(disk) == 0 {
		t.Fatalf("glob: %v %v", disk, err)
	}
	for _, p := range disk {
		if _, err := fs.ReadFile(Files, p); err != nil {
			t.Errorf("%s is on disk but not embedded", p)
		}
	}
}

// assets/privops/init.sh is the microVM's /init, and until phase 6
// deletes it the shell tree carries the same script as a heredoc inside
// lib/privops-qemu-linux.sh (Ruling 7 of phase 4). The two must not
// drift: the Go backend and the shell one boot the same guest.
func TestInitIsTheShellTreesHeredoc(t *testing.T) {
	f, err := os.Open("lib/privops-qemu-linux.sh")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	const start = `    cat > "$root/init" <<'INIT'`
	var heredoc bytes.Buffer
	in, found, closed := false, false, false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case !in && !found && line == start:
			in, found = true, true
		case in && line == "INIT":
			in, closed = false, true
		case in:
			heredoc.WriteString(line + "\n")
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if !found || !closed {
		t.Fatalf("no complete <<'INIT' heredoc in lib/privops-qemu-linux.sh (start %v, end %v)", found, closed)
	}
	emb, err := fs.ReadFile(Files, "assets/privops/init.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(emb, heredoc.Bytes()) {
		t.Fatalf("assets/privops/init.sh (%d bytes) differs from the heredoc (%d bytes)", len(emb), heredoc.Len())
	}
	if !strings.HasPrefix(heredoc.String(), "#!/bin/busybox sh\n") {
		t.Fatalf("the heredoc does not start with the busybox shebang: %q", heredoc.String()[:min(40, heredoc.Len())])
	}
}
