package fetch

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// release serves <tag>/SHA256SUMS and the named packages.
func release(t *testing.T, tag string, pkgs map[string][]byte, sumsOverride map[string]string) *httptest.Server {
	var sums strings.Builder
	for name, body := range pkgs {
		s := sum(body)
		if o, ok := sumsOverride[name]; ok {
			s = o
		}
		fmt.Fprintf(&sums, "%s  %s\n", s, name)
	}
	fmt.Fprintf(&sums, "%s  %s\n", sum([]byte("notes")), "RELEASE-NOTES.md")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/"+tag+"/")
		if p == "SHA256SUMS" {
			w.Write([]byte(sums.String()))
			return
		}
		if b, ok := pkgs[p]; ok {
			w.Write(b)
			return
		}
		w.WriteHeader(404)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func xar(s string) []byte { return []byte("xar!" + s) }

func TestOpenSSHFetchesByTheNamesSUMSGivesBaseFirst(t *testing.T) {
	pkgs := map[string][]byte{
		"OpenSSH-10.5p1-mavericks.2.pkg":                xar("base"),
		"OpenSSH-10.5p1-mavericks.2-System-Replace.pkg": xar("replace"),
	}
	srv := release(t, "10.5p1-mavericks.2", pkgs, nil)
	got, err := getter(t).OpenSSH(context.Background(), srv.URL, "10.5p1-mavericks.2", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got.Base, "OpenSSH-10.5p1-mavericks.2.pkg") || !strings.HasSuffix(got.Replace, "-System-Replace.pkg") {
		t.Fatalf("%+v", got)
	}
}

func TestARenamedAssetPrefixDoesNotBreakTheFetch(t *testing.T) {
	// The golang incident: an asset renamed across a pin bump must not 404
	// because a name was constructed from a prefix.
	pkgs := map[string][]byte{"ssh10-a.pkg": xar("b"), "ssh10-a-system-replace.pkg": xar("r")}
	srv := release(t, "t", pkgs, nil)
	if _, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", nil); err != nil {
		t.Fatal(err)
	}
}

func TestOpenSSHRefusals(t *testing.T) {
	cases := map[string]struct {
		pkgs map[string][]byte
		over map[string]string
		want string
	}{
		"bytes differ from SUMS": {map[string][]byte{"a.pkg": xar("b"), "a-System-Replace.pkg": xar("r")}, map[string]string{"a.pkg": sum([]byte("other"))}, "checksum mismatch"},
		"no replacement":         {map[string][]byte{"a.pkg": xar("b")}, nil, "System-Replace"},
		"two bases":              {map[string][]byte{"a.pkg": xar("b"), "b.pkg": xar("c"), "a-System-Replace.pkg": xar("r")}, nil, "two base"},
		"not a flat package":     {map[string][]byte{"a.pkg": []byte("PK\x03\x04"), "a-System-Replace.pkg": xar("r")}, nil, "xar"},
	}
	for name, c := range cases {
		srv := release(t, "t", c.pkgs, c.over)
		_, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", nil)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}

func TestAMissingReleaseNamesTheTag(t *testing.T) {
	srv := release(t, "real", nil, nil)
	_, err := getter(t).OpenSSH(context.Background(), srv.URL, "9.9p9-mavericks.9", nil)
	if err == nil || !strings.Contains(err.Error(), "9.9p9-mavericks.9") {
		t.Fatalf("err = %v", err)
	}
}

// TestOpenSSHRejectsACaptivePortalSUMSThenSucceedsAgainstARealServer
// reproduces the review's finding: any 200 response was persisted and
// reused forever, even an HTML captive-portal page. It must instead be an
// error naming the SUMS path, must not be persisted, and a subsequent
// call against a real server (same tag) must then succeed.
func TestOpenSSHRejectsACaptivePortalSUMSThenSucceedsAgainstARealServer(t *testing.T) {
	portal := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "<html><body>Sign in to the network</body></html>")
	}))
	defer portal.Close()
	g := getter(t)

	_, err := g.OpenSSH(context.Background(), portal.URL, "t", nil)
	if err == nil {
		t.Fatal("a captive-portal response must be refused")
	}
	sumsPath := g.Paths.OpenSSHSums("t")
	if !strings.Contains(err.Error(), sumsPath) && !strings.Contains(err.Error(), portal.URL) {
		t.Fatalf("err = %v, want it to name the SUMS path or URL", err)
	}
	if _, statErr := os.Stat(sumsPath); !os.IsNotExist(statErr) {
		t.Fatal("a captive-portal response must not be persisted")
	}

	pkgs := map[string][]byte{"a.pkg": xar("b"), "a-System-Replace.pkg": xar("r")}
	real := release(t, "t", pkgs, nil)
	got, err := g.OpenSSH(context.Background(), real.URL, "t", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got.Base, "a.pkg") {
		t.Fatalf("%+v", got)
	}
}

// TestOpenSSHRefusesAnOversizedSUMSResponse: the two valid .pkg lines sit
// first, followed by more padding than fits under the cap. A reader that
// silently stops at the cap would still see two complete, valid lines and
// accept the (truncated) response as legitimate SUMS; reading one byte
// past the cap and refusing anything that reaches it catches this even
// when truncation happens not to corrupt the part that was kept.
func TestOpenSSHRefusesAnOversizedSUMSResponse(t *testing.T) {
	var body strings.Builder
	fmt.Fprintf(&body, "%s  a.pkg\n", sum([]byte("b")))
	fmt.Fprintf(&body, "%s  a-System-Replace.pkg\n", sum([]byte("r")))
	body.WriteString(strings.Repeat("#", maxSumsBytes)) // padding alone exceeds the cap
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(body.String()))
	}))
	defer srv.Close()
	_, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", nil)
	if err == nil || !strings.Contains(err.Error(), srv.URL) || !strings.Contains(err.Error(), "refusing to buffer") {
		t.Fatalf("err = %v, want a refusal naming the URL, not a checksum mismatch from a truncated-but-plausible response", err)
	}
}

// TestParseOpenSSHSumsRefusesAPathInAPackageName: a SUMS row naming a
// package outside the release directory ("../../evil.pkg") must not reach
// Item.Adopt (filepath.Join(adoptDir, name)), which would otherwise let a
// malicious or corrupted SUMS read or overwrite outside adoptDir.
func TestParseOpenSSHSumsRefusesAPathInAPackageName(t *testing.T) {
	bad := fmt.Sprintf("%s  ../../evil.pkg\n%s  a-System-Replace.pkg\n", sum([]byte("x")), sum([]byte("y")))
	_, _, _, err := parseOpenSSHSums([]byte(bad))
	if err == nil || !strings.Contains(err.Error(), "../../evil.pkg") {
		t.Fatalf("err = %v", err)
	}
}

// TestOpenSSHAdoptsFromTheSecondDirWhenTheFirstIsPartial reproduces the
// review's finding: OpenSSH used to take a single adoptDir, and the CLI
// picked one directory by mere existence, so a partial copy in that one
// (present but wrong, or simply incomplete) shadowed a perfectly good
// copy elsewhere and forced a fetch that, offline, would just fail. Every
// directory in adoptDirs must be tried, in order, like InstallESD's own
// adopt list -- with no directory here having any usable content, only
// the network could satisfy this, which the unreachable server proves is
// never contacted.
func TestOpenSSHAdoptsFromTheSecondDirWhenTheFirstIsPartial(t *testing.T) {
	tag := "t"
	baseName, replaceName := "a.pkg", "a-System-Replace.pkg"
	baseBody, replaceBody := xar("base"), xar("replace")

	// partialDir: base.pkg is there but WRONG, and replace.pkg and
	// SHA256SUMS are simply missing -- an incomplete/corrupted copy.
	partialDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(partialDir, baseName), []byte("wrong bytes"), 0o644); err != nil {
		t.Fatal(err)
	}

	// goodDir: everything, correct.
	goodDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(goodDir, baseName), baseBody, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(goodDir, replaceName), replaceBody, 0o644); err != nil {
		t.Fatal(err)
	}
	var sums strings.Builder
	fmt.Fprintf(&sums, "%s  %s\n", sum(baseBody), baseName)
	fmt.Fprintf(&sums, "%s  %s\n", sum(replaceBody), replaceName)
	if err := os.WriteFile(filepath.Join(goodDir, "SHA256SUMS"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	var contacted atomic.Bool
	unreachable := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		contacted.Store(true)
		w.WriteHeader(500)
	}))
	defer unreachable.Close()

	got, err := getter(t).OpenSSH(context.Background(), unreachable.URL, tag, []string{partialDir, goodDir})
	if err != nil {
		t.Fatal(err)
	}
	if contacted.Load() {
		t.Fatal("the network must not be contacted when the second directory has a good copy")
	}
	if !strings.HasSuffix(got.Base, baseName) || !strings.HasSuffix(got.Replace, replaceName) {
		t.Fatalf("%+v", got)
	}
}

func TestOpenSSHTagIsTheEmbeddedPin(t *testing.T) {
	tag, err := OpenSSHTag()
	if err != nil || !strings.Contains(tag, "-mavericks.") {
		t.Fatalf("%q %v", tag, err)
	}
}
