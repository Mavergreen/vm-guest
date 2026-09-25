package diskimg

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
)

// Known answers: spec §7's golden bytes for what this package writes.
// The other tests show the output is stable and well-formed; these show
// it is the SAME output as before, so a change to a single byte of the
// format fails here, by name. Generated 2026-09-25. Regenerate only on a
// deliberate format change, and say why in the commit.
const (
	// DerivedGUID's answers for the two seeds the EFI image uses.
	goldenESPGUID  = "37995765-B0E5-4B23-9753-FBD408201128" // "opencore esp"
	goldenDiskGUID = "B91EACC4-B4B3-4E01-B7C8-6340A7B2C1A1" // "opencore disk"

	// The 40 MiB filesystem TestFATIsDeterministic builds.
	goldenFAT40 = "e3b0cd527933ecfae3539cb2096390e53496289d50b7ed8c685fe15239b19635"
	// A 192 MiB disk holding only the GPT: espOn(mib192), disk GUID
	// DerivedGUID("test disk"), every other byte zero.
	goldenGPT192 = "6b624adfa02755373d625d716b5c86506bbd33a3f1667afff1d54c92da7813bd"
)

func sum(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// derive is DerivedGUID's rule written out again, from the text end:
// the first 16 bytes of SHA-256("vmavs diskimg " + seed), version 4 in
// the high nibble of byte 6, the RFC 4122 variant in the top two bits of
// byte 8, printed 8-4-4-4-12 in upper-case hex. It pins the derivation
// itself, not just that the answer is stable.
func derive(seed string) string {
	s := sha256.Sum256([]byte("vmavs diskimg " + seed))
	b := s[:16]
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := strings.ToUpper(hex.EncodeToString(b))
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
}

func TestDerivedGUIDKnownAnswers(t *testing.T) {
	for _, c := range []struct{ seed, want string }{
		{"opencore esp", goldenESPGUID},
		{"opencore disk", goldenDiskGUID},
	} {
		got := DerivedGUID(c.seed).String()
		if got != c.want {
			t.Errorf("DerivedGUID(%q) = %s, the pinned answer is %s", c.seed, got, c.want)
		}
		if d := derive(c.seed); got != d {
			t.Errorf("DerivedGUID(%q) = %s, its rule gives %s", c.seed, got, d)
		}
	}
}

func TestFATGoldenBytes(t *testing.T) {
	f := mustFAT(t)
	if err := f.Mkdir("/EFI"); err != nil {
		t.Fatal(err)
	}
	if err := f.WriteFile("/EFI/config.plist", []byte("<plist/>")); err != nil {
		t.Fatal(err)
	}
	img, _ := build(t, f, 40)
	if got := sum(img); got != goldenFAT40 {
		t.Errorf("the 40 MiB filesystem's sha256 is %s, pinned %s", got, goldenFAT40)
	}
}

func TestGPTGoldenBytes(t *testing.T) {
	img := make(image, mib192*SectorSize)
	if err := WriteGPT(img, mib192, DerivedGUID("test disk"), espOn(mib192)); err != nil {
		t.Fatal(err)
	}
	if got := sum(img); got != goldenGPT192 {
		t.Errorf("the 192 MiB GPT-only disk's sha256 is %s, pinned %s", got, goldenGPT192)
	}
}
