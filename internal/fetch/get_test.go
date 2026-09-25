package fetch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

func sum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func getter(t *testing.T) *Getter {
	return &Getter{Paths: config.Paths{Home: t.TempDir()}, Backoff: time.Millisecond, Log: func(string, ...any) {}}
}

func TestFilenameRules(t *testing.T) {
	for url, want := range map[string]string{
		"https://h/x/a.zip":       "a.zip",
		"https://h/x/a.zip?v=2":   "a.zip?v=2",
		"http://h/InstallESD.dmg": "InstallESD.dmg",
	} {
		if got, err := Filename(url); err != nil || got != want {
			t.Errorf("%s: %q %v", url, got, err)
		}
	}
	for _, bad := range []string{"https://h", "https://h/x/"} {
		if _, err := Filename(bad); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
}

func TestGetDownloadsVerifiesAndCaches(t *testing.T) {
	body := []byte("payload bytes")
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	it := Item{Name: "x", URL: srv.URL + "/d/x.zip", SHA256: sum(body)}
	p, err := g.Get(context.Background(), it)
	if err != nil || p != g.Paths.CacheFile(sum(body), "x.zip") {
		t.Fatalf("%q %v", p, err)
	}
	if _, err := g.Get(context.Background(), it); err != nil || hits != 1 {
		t.Fatalf("second Get must use the cache: hits=%d err=%v", hits, err)
	}
}

func TestAMismatchedDownloadNeverTakesItsFinalName(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("evil")) }))
	defer srv.Close()
	g := getter(t)
	want := sum([]byte("good"))
	_, err := g.Get(context.Background(), Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: want})
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(g.Paths.CacheFile(want, "x.zip")); !os.IsNotExist(err) {
		t.Fatal("an unverified download was renamed into place")
	}
}

func TestARotCachedFileIsAnErrorNotARedownload(t *testing.T) {
	g := getter(t)
	want := sum([]byte("good"))
	dest := g.Paths.CacheFile(want, "x.zip")
	os.MkdirAll(filepath.Dir(dest), 0o755)
	os.WriteFile(dest, []byte("rotted"), 0o644)
	_, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: want})
	if err == nil || !strings.Contains(err.Error(), dest) {
		t.Fatalf("err = %v", err)
	}
}

func TestAdoptionReusesAVerifiedFileWithoutTheNetwork(t *testing.T) {
	g := getter(t)
	body := []byte("already downloaded by the shell tree")
	old := filepath.Join(t.TempDir(), "x.zip")
	os.WriteFile(old, body, 0o644)
	bad := filepath.Join(t.TempDir(), "x.zip")
	os.WriteFile(bad, []byte("wrong"), 0o644)
	var logged []string
	g.Log = func(f string, a ...any) { logged = append(logged, f) }
	p, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: sum(body), Adopt: []string{bad, old}})
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != string(body) {
		t.Fatal("adopted file differs")
	}
	if b, _ := os.ReadFile(old); string(b) != string(body) {
		t.Fatal("adoption must not disturb the original")
	}
}

func TestRetriesServerErrorsButNotClientErrors(t *testing.T) {
	body := []byte("ok")
	var n int32
	flaky := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&n, 1) < 3 {
			w.WriteHeader(503)
			return
		}
		w.Write(body)
	}))
	defer flaky.Close()
	g := getter(t)
	if _, err := g.Get(context.Background(), Item{Name: "f", URL: flaky.URL + "/f", SHA256: sum(body)}); err != nil || n != 3 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	var m int32
	gone := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&m, 1)
		w.WriteHeader(404)
	}))
	defer gone.Close()
	_, err := g.Get(context.Background(), Item{Name: "g", URL: gone.URL + "/g", SHA256: sum(body)})
	if err == nil || m != 1 || !strings.Contains(err.Error(), "404") {
		t.Fatalf("m=%d err=%v", m, err)
	}
}

func TestHeadersAreSent(t *testing.T) {
	body := []byte("tok")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "AssetToken=abc" {
			w.WriteHeader(403)
			return
		}
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	h := http.Header{}
	h.Set("Cookie", "AssetToken=abc")
	if _, err := g.Get(context.Background(), Item{Name: "t", URL: srv.URL + "/t", SHA256: sum(body), Header: h}); err != nil {
		t.Fatal(err)
	}
}

func TestHasXarMagic(t *testing.T) {
	d := t.TempDir()
	good, bad := filepath.Join(d, "g.pkg"), filepath.Join(d, "b.pkg")
	os.WriteFile(good, []byte("xar!fake"), 0o644)
	os.WriteFile(bad, []byte("PK\x03\x04"), 0o644)
	if ok, _ := HasXarMagic(good); !ok {
		t.Fatal("xar! not recognised")
	}
	if ok, _ := HasXarMagic(bad); ok {
		t.Fatal("zip taken for xar")
	}
}
