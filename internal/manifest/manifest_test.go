package manifest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const images = "testdata/images"

func TestListSkipsManifestsWithoutAnImageAndSortsNewestFirst(t *testing.T) {
	now := time.Now()
	os.Chtimes(filepath.Join(images, "legacy.manifest"), now, now)
	os.Chtimes(filepath.Join(images, "current.manifest"), now.Add(-time.Hour), now.Add(-time.Hour))
	ms, err := List(images)
	if err != nil {
		t.Fatal(err)
	}
	if len(ms) != 2 || ms[0].Name != "legacy" || ms[1].Name != "current" {
		t.Fatalf("got %v", names(ms))
	}
}

func TestHardwareIsWhatTheImageWasInstalledWith(t *testing.T) {
	cur, _ := Find(images, "current")
	h := cur.Hardware()
	if h.Accel != "kvm" || h.Type != "q35" || h.CPU != "Penryn,+ssse3,+sse4.1,+sse4.2" ||
		h.MemoryMB != 4096 || h.SMP != 2 || h.NIC != "e1000-82545em" {
		t.Fatalf("current: %+v", h)
	}
	leg, _ := Find(images, "legacy")
	h = leg.Hardware()
	// No nic line: built before a9f8c61, when usb-net was the only NIC.
	if h.Accel != "tcg" || h.CPU != "Nehalem" || h.MemoryMB != 2048 || h.SMP != 1 || h.NIC != "usb-net" {
		t.Fatalf("legacy: %+v", h)
	}
}

func TestSSHFacts(t *testing.T) {
	cur, _ := Find(images, "current")
	leg, _ := Find(images, "legacy")
	if cur.LegacySSH() || !leg.LegacySSH() {
		t.Fatal("openssh line present → modern; absent → Apple's 6.2")
	}
	if cur.SSHKeyFingerprint() != "SHA256:20V3dlDtWnv2FKbn3sB6ljy2Zb24Ka0RWHf4tjQbPqs" {
		t.Fatalf("fingerprint %q", cur.SSHKeyFingerprint())
	}
	if cur.Image() != filepath.Join(images, "current.qcow2") {
		t.Fatalf("image %q", cur.Image())
	}
}

func TestFindNamesWhatIsAvailable(t *testing.T) {
	_, err := Find(images, "nonesuch")
	if err == nil || !contains(err.Error(), "current") || !contains(err.Error(), "legacy") {
		t.Fatalf("err = %v", err)
	}
}

func names(ms []Manifest) (out []string) {
	for _, m := range ms {
		out = append(out, m.Name)
	}
	return out
}

func contains(s, substr string) bool { return strings.Contains(s, substr) }

// TestAnyIsWhetherListWouldFindSomething: a manifest counts only with its
// image beside it, as in List; a missing directory holds nothing.
func TestAnyIsWhetherListWouldFindSomething(t *testing.T) {
	if !Any(images) {
		t.Fatalf("Any(%s) = false, want true", images)
	}
	empty := t.TempDir()
	if Any(empty) || Any(filepath.Join(empty, "missing")) {
		t.Fatal("an empty or missing directory holds no image")
	}
	os.WriteFile(filepath.Join(empty, "orphan.manifest"), []byte("name\torphan\n"), 0o644)
	if Any(empty) {
		t.Fatal("a manifest without its image is not an image")
	}
}
