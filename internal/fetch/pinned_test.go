package fetch

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// canHardLink reports whether dir's filesystem supports hard links: a
// probe, since t.TempDir() may sit on a filesystem (some CI containers,
// some overlays) where os.Link always fails and adoptCandidate falls
// back to a copy -- a different inode, which TestPinnedAdoptsFrom... must
// then not treat as a failure.
func canHardLink(t *testing.T, dir string) bool {
	t.Helper()
	a := filepath.Join(dir, ".hardlink-check-a")
	b := filepath.Join(dir, ".hardlink-check-b")
	if err := os.WriteFile(a, []byte("x"), 0o644); err != nil {
		return false
	}
	defer os.Remove(a)
	if err := os.Link(a, b); err != nil {
		return false
	}
	os.Remove(b)
	return true
}

// registry parses one row into a *pins.Registry, for Pinned's tests.
func registry(t *testing.T, name, url, sha string) *pins.Registry {
	t.Helper()
	reg, err := pins.Parse(strings.NewReader(name + "\t" + url + "\t" + sha + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	return reg
}

func TestPinnedDownloadsVerifiesAndCaches(t *testing.T) {
	body := []byte("firmware bytes")
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	reg := registry(t, "x", srv.URL+"/dir/x.tar.gz", sum(body))

	p, err := g.Pinned(context.Background(), reg, "x", nil)
	if err != nil {
		t.Fatal(err)
	}
	if want := g.Paths.CacheFile(sum(body), "x.tar.gz"); p != want {
		t.Fatalf("p = %q, want %q", p, want)
	}
	if b, err := os.ReadFile(p); err != nil || string(b) != string(body) {
		t.Fatalf("content = %q, %v", b, err)
	}
	if _, err := g.Pinned(context.Background(), reg, "x", nil); err != nil || hits != 1 {
		t.Fatalf("second Pinned must use the cache: hits=%d err=%v", hits, err)
	}
}

func TestPinnedAdoptsFromTheShellTreesBuildDirectory(t *testing.T) {
	body := []byte("already fetched by the shell tree")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
	}))
	defer srv.Close()
	g := getter(t)
	reg := registry(t, "x", srv.URL+"/dir/x.tar.gz", sum(body))

	adoptDir := t.TempDir()
	old := filepath.Join(adoptDir, "x.tar.gz")
	if err := os.WriteFile(old, body, 0o644); err != nil {
		t.Fatal(err)
	}

	p, err := g.Pinned(context.Background(), reg, "x", []string{adoptDir})
	if err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(p); err != nil || string(b) != string(body) {
		t.Fatalf("content = %q, %v", b, err)
	}
	if canHardLink(t, g.Paths.Home) {
		pInfo, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		oldInfo, err := os.Stat(old)
		if err != nil {
			t.Fatal(err)
		}
		if !os.SameFile(pInfo, oldInfo) {
			t.Fatalf("adopted file is not the same inode as %s", old)
		}
	}
}

func TestPinnedRefusesAnUnpinnedSource(t *testing.T) {
	g := getter(t)
	reg := registry(t, "x", "https://example.test/dir/x.tar.gz", "TOFU")
	if _, err := g.Pinned(context.Background(), reg, "x", nil); err == nil ||
		!strings.Contains(err.Error(), "x") || !strings.Contains(err.Error(), "pinned") {
		t.Fatalf("err = %v", err)
	}
}

func TestPinnedRefusesAURLWithNoFilename(t *testing.T) {
	g := getter(t)
	for _, url := range []string{"https://example.test", "https://example.test/dir/"} {
		reg := registry(t, "x", url, sum([]byte("x")))
		if _, err := g.Pinned(context.Background(), reg, "x", nil); err == nil ||
			!strings.Contains(err.Error(), "cannot derive a filename") {
			t.Fatalf("url %s: err = %v", url, err)
		}
	}
}

// TestPinnedKeepsAQueryStringInTheFilename: the query string is part of
// the cached filename, as lib/vendor.sh's fetch_source names it
// (vendor.bats). validateFilename refuses a "/" but allows a "?".
func TestPinnedKeepsAQueryStringInTheFilename(t *testing.T) {
	body := []byte("versioned asset")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	defer srv.Close()
	g := getter(t)
	reg := registry(t, "x", srv.URL+"/f.zip?v=2", sum(body))
	p, err := g.Pinned(context.Background(), reg, "x", nil)
	if err != nil {
		t.Fatal(err)
	}
	if want := g.Paths.CacheFile(sum(body), "f.zip?v=2"); p != want {
		t.Fatalf("p = %q, want %q", p, want)
	}
}

// TestPinnedSkipsEmptyAdoptDirs: an adoptDirs entry of "" must be
// ignored, not turned into "./x.tar.gz" (which could exist by accident in
// whatever directory the test binary happens to run from).
func TestPinnedSkipsEmptyAdoptDirs(t *testing.T) {
	body := []byte("payload")
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	reg := registry(t, "x", srv.URL+"/dir/x.tar.gz", sum(body))

	if wd, err := os.Getwd(); err == nil {
		accidental := filepath.Join(wd, "x.tar.gz")
		if _, err := os.Stat(accidental); err == nil {
			t.Fatalf("refusing to run: %s already exists", accidental)
		}
	}

	p, err := g.Pinned(context.Background(), reg, "x", []string{""})
	if err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Fatalf("hits = %d, want a download since the empty adoptDirs entry was skipped", hits)
	}
	if b, err := os.ReadFile(p); err != nil || string(b) != string(body) {
		t.Fatalf("content = %q, %v", b, err)
	}
}
