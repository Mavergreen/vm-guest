package vmguest

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
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
