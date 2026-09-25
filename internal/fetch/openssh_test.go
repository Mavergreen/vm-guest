package fetch

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
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
	got, err := getter(t).OpenSSH(context.Background(), srv.URL, "10.5p1-mavericks.2", "")
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
	if _, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", ""); err != nil {
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
		_, err := getter(t).OpenSSH(context.Background(), srv.URL, "t", "")
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}

func TestAMissingReleaseNamesTheTag(t *testing.T) {
	srv := release(t, "real", nil, nil)
	_, err := getter(t).OpenSSH(context.Background(), srv.URL, "9.9p9-mavericks.9", "")
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

	_, err := g.OpenSSH(context.Background(), portal.URL, "t", "")
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
	got, err := g.OpenSSH(context.Background(), real.URL, "t", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got.Base, "a.pkg") {
		t.Fatalf("%+v", got)
	}
}

func TestOpenSSHTagIsTheEmbeddedPin(t *testing.T) {
	tag, err := OpenSSHTag()
	if err != nil || !strings.Contains(tag, "-mavericks.") {
		t.Fatalf("%q %v", tag, err)
	}
}
