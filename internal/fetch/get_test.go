package fetch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
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

// TestDownloadNeverWritesThroughAPreexistingPartName reproduces the
// reviewer's finding: the old code always wrote a download to a FIXED
// name, dest+".part". If that name is already a hard link to some other
// file -- left behind by a crashed adopt, or simply planted here -- the
// old code's os.Create truncated that shared inode before a single byte
// was verified, corrupting whatever else pointed at it (in the field,
// the shell tree's own download). This must never happen: every attempt
// creates its own uniquely named temp file and never opens a
// pre-existing path for writing.
func TestDownloadNeverWritesThroughAPreexistingPartName(t *testing.T) {
	g := getter(t)
	want := sum([]byte("good"))
	dest := g.Paths.CacheFile(want, "x.zip")
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	original := filepath.Join(t.TempDir(), "original")
	if err := os.WriteFile(original, []byte("good"), 0o644); err != nil {
		t.Fatal(err)
	}
	fixedPart := dest + ".part" // the OLD fixed name this code must never touch
	if err := os.Link(original, fixedPart); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("evil")) }))
	defer srv.Close()

	if _, err := g.Get(context.Background(), Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: want}); err == nil {
		t.Fatal("a checksum mismatch must still be an error")
	}
	if b, err := os.ReadFile(original); err != nil || string(b) != "good" {
		t.Fatalf("the original, reachable through a pre-existing fixed .part link, was overwritten: %q %v", b, err)
	}
	if b, err := os.ReadFile(fixedPart); err != nil || string(b) != "good" {
		t.Fatalf("the fixed .part name's shared inode was overwritten: %q %v", b, err)
	}
}

// TestConcurrentGetsOfOneItemNeverProduceATornFile: with a fixed .part
// name, one goroutine's verify-then-rename could race a second goroutine
// still writing into what just became the first's dest, handing back a
// path whose bytes changed after Get verified them. Each attempt's own
// unique temp file rules this out.
func TestConcurrentGetsOfOneItemNeverProduceATornFile(t *testing.T) {
	good := []byte("the correct bytes, more than a few of them")
	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&n, 1) == 1 {
			w.Write(good)
			return
		}
		w.Write([]byte("evil bytes of a different length"))
	}))
	defer srv.Close()
	g := getter(t)
	it := Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: sum(good)}

	var wg sync.WaitGroup
	paths := make([]string, 2)
	errs := make([]error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			paths[i], errs[i] = g.Get(context.Background(), it)
		}(i)
	}
	wg.Wait()

	succeeded := 0
	for i, err := range errs {
		if err == nil {
			succeeded++
			b, rerr := os.ReadFile(paths[i])
			if rerr != nil || sum(b) != it.SHA256 {
				t.Fatalf("returned path's bytes do not verify: err=%v bytes=%q", rerr, b)
			}
		}
	}
	if succeeded == 0 {
		t.Fatal("the request that received the correct bytes must succeed")
	}
	dest := g.Paths.CacheFile(it.SHA256, "x.zip")
	if b, err := os.ReadFile(dest); err == nil && sum(b) != it.SHA256 {
		t.Fatalf("the cache file is torn or unverified: sum = %s", sum(b))
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
	var mu sync.Mutex
	g.Log = func(f string, a ...any) {
		mu.Lock()
		defer mu.Unlock()
		logged = append(logged, fmt.Sprintf(f, a...))
	}
	p, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: sum(body), Adopt: []string{bad, old}})
	if err != nil {
		t.Fatal(err)
	}
	if want := g.Paths.CacheFile(sum(body), "x.zip"); p != want {
		t.Fatalf("p = %q, want the cache path %q", p, want)
	}
	if b, _ := os.ReadFile(p); string(b) != string(body) {
		t.Fatal("adopted file differs")
	}
	if b, _ := os.ReadFile(old); string(b) != string(body) {
		t.Fatal("adoption must not disturb the original")
	}
	sawSkip, sawAdopted := false, false
	for _, l := range logged {
		if strings.Contains(l, "not adopting") && strings.Contains(l, bad) {
			sawSkip = true
		}
		if strings.Contains(l, "adopted") && strings.Contains(l, old) {
			sawAdopted = true
		}
	}
	if !sawSkip {
		t.Errorf("logged = %v, want a line about skipping %s", logged, bad)
	}
	if !sawAdopted {
		t.Errorf("logged = %v, want a line about adopting %s", logged, old)
	}
}

// TestAdoptionVerifiesWhatItPlacedNotJustWhatItHashed reproduces the
// review's finding that adoption hashed the source once, then linked or
// copied it without checking that what got placed was still what got
// hashed. testAdoptHook fires in that exact window.
func TestAdoptionVerifiesWhatItPlacedNotJustWhatItHashed(t *testing.T) {
	g := getter(t)
	good := []byte("good")
	old := filepath.Join(t.TempDir(), "x.zip")
	if err := os.WriteFile(old, good, 0o644); err != nil {
		t.Fatal(err)
	}

	prev := testAdoptHook
	testAdoptHook = func() {
		// Simulate the source being replaced in the window between the
		// first hash and the link/copy: a new inode with different bytes
		// at the same path.
		os.Remove(old)
		os.WriteFile(old, []byte("swapped underfoot"), 0o644)
	}
	t.Cleanup(func() { testAdoptHook = prev })

	_, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: sum(good), Adopt: []string{old}})
	if err == nil {
		t.Fatal("adoption of a source that changed underfoot must fall through to a (failing) download, not succeed")
	}
	dest := g.Paths.CacheFile(sum(good), "x.zip")
	if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
		t.Fatal("adoption placed unverified bytes into the cache")
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

func TestNoFetchNeverContactsTheNetwork(t *testing.T) {
	var contacted atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		contacted.Store(true)
		w.WriteHeader(500)
	}))
	defer srv.Close()
	g := getter(t)
	want := sum([]byte("good"))
	_, err := g.Get(context.Background(), Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: want, noFetch: true})
	if !errors.Is(err, errNotCached) {
		t.Fatalf("err = %v, want errNotCached", err)
	}
	if contacted.Load() {
		t.Fatal("noFetch must never contact the network")
	}
}

// TestPathTraversalInputsAreRejected: a checksum column like
// "../../../escaped" or a "https://h/x/.." URL must never reach
// CacheFile/os.Create unvalidated.
func TestPathTraversalInputsAreRejected(t *testing.T) {
	g := getter(t)
	if _, err := g.Get(context.Background(), Item{Name: "x", URL: "http://h/x/a.zip", SHA256: "../../../escaped"}); err == nil || !strings.Contains(err.Error(), `"../../../escaped"`) {
		t.Fatalf("a non-hex checksum must be refused: %v", err)
	}
	if _, err := g.Get(context.Background(), Item{Name: "x", URL: "https://h/x/..", SHA256: sum([]byte("x"))}); err == nil || !strings.Contains(err.Error(), `".."`) {
		t.Fatalf("a \"..\" filename must be refused: %v", err)
	}
	if _, err := os.Stat(g.Paths.Cache()); !os.IsNotExist(err) {
		t.Fatal("a rejected item must create nothing under the cache directory")
	}
}

func TestATruncatedBodyIsRetried(t *testing.T) {
	body := []byte("payload bytes, more than just a few of them")
	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&n, 1) == 1 {
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.WriteHeader(200)
			w.Write(body[:len(body)/2]) // declared more than sent: io.ErrUnexpectedEOF
			return
		}
		w.Write(body)
	}))
	defer srv.Close()
	g := getter(t)
	p, err := g.Get(context.Background(), Item{Name: "t", URL: srv.URL + "/t", SHA256: sum(body)})
	if err != nil || n != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if b, _ := os.ReadFile(p); string(b) != string(body) {
		t.Fatal("wrong bytes after the retry")
	}
}

func TestAStalledDownloadIsAbortedAndRetried(t *testing.T) {
	body := []byte("ok")
	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&n, 1) == 1 {
			w.Header().Set("Content-Length", "1000000")
			w.WriteHeader(200)
			w.(http.Flusher).Flush()
			time.Sleep(500 * time.Millisecond) // well past the test's stall timeout
			return
		}
		w.Write(body)
	}))
	defer srv.Close()
	g := &Getter{Paths: config.Paths{Home: t.TempDir()}, Backoff: time.Millisecond, StallTimeout: 50 * time.Millisecond, Log: func(string, ...any) {}}
	p, err := g.Get(context.Background(), Item{Name: "t", URL: srv.URL + "/t", SHA256: sum(body)})
	if err != nil || n != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if b, _ := os.ReadFile(p); string(b) != string(body) {
		t.Fatal("wrong bytes after the stall retry")
	}
}

// TestNegativeStallTimeoutIsTreatedAsDefault: time.NewTimer treats a
// negative duration as "fire immediately", so a negative StallTimeout
// would otherwise abort every attempt as instantly stalled. stallDuration
// must default it exactly like 0.
func TestNegativeStallTimeoutIsTreatedAsDefault(t *testing.T) {
	g := &Getter{StallTimeout: -1}
	if got := g.stallDuration(); got != 2*time.Minute {
		t.Fatalf("stallDuration() = %v, want the 2-minute default", got)
	}
}

// TestANegativeStallTimeoutDoesNotAbortAnOrdinaryDownload: the behavioural
// version of the above -- a real (if slow-ish) download must still
// succeed on the first attempt, not be aborted and retried as if it had
// stalled.
func TestANegativeStallTimeoutDoesNotAbortAnOrdinaryDownload(t *testing.T) {
	body := []byte("ok, no stall here")
	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&n, 1)
		w.Write(body)
	}))
	defer srv.Close()
	g := &Getter{Paths: config.Paths{Home: t.TempDir()}, Backoff: time.Millisecond, StallTimeout: -1, Log: func(string, ...any) {}}
	if _, err := g.Get(context.Background(), Item{Name: "t", URL: srv.URL + "/t", SHA256: sum(body)}); err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
}

// TestStaleTempsAreRemovedBeforeADownloadFreshOnesAreLeftAlone: a temp
// file or adopt directory left behind by a killed process (SIGKILL, OOM,
// power loss) is stale once it is older than the cleanup threshold and
// must be removed before the next attempt; one that is merely in
// progress (a fresh mtime) must be left alone.
func TestStaleTempsAreRemovedBeforeADownloadFreshOnesAreLeftAlone(t *testing.T) {
	g := getter(t)
	body := []byte("fresh download")
	dest := g.Paths.CacheFile(sum(body), "x.zip")
	dir := filepath.Dir(dest)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	old := time.Now().Add(-31 * time.Minute)

	staleTemp := filepath.Join(dir, ".x.zip.123456.part")
	if err := os.WriteFile(staleTemp, []byte("dead attempt"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(staleTemp, old, old); err != nil {
		t.Fatal(err)
	}

	staleAdoptDir := filepath.Join(dir, ".adopt-abc123")
	if err := os.Mkdir(staleAdoptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(staleAdoptDir, old, old); err != nil {
		t.Fatal(err)
	}

	freshTemp := filepath.Join(dir, ".x.zip.654321.part")
	if err := os.WriteFile(freshTemp, []byte("in progress"), 0o644); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	defer srv.Close()

	if _, err := g.Get(context.Background(), Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: sum(body)}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(staleTemp); !os.IsNotExist(err) {
		t.Fatal("a stale temp must be removed before a new download")
	}
	if _, err := os.Stat(staleAdoptDir); !os.IsNotExist(err) {
		t.Fatal("a stale adopt directory must be removed before a new download")
	}
	if _, err := os.Stat(freshTemp); err != nil {
		t.Fatal("a fresh temp must be left alone")
	}
}

// TestAdoptionResolvesASymlinkCandidate: os.Link on Linux links a symlink
// itself, not its target; for a relative symlink, once linked into a new
// directory its relative target no longer resolves. adoptCandidate must
// resolve the symlink first, so the cache entry is always a real file (or
// a hard link to one), never a symlink -- and never a broken one.
func TestAdoptionResolvesASymlinkCandidate(t *testing.T) {
	body := []byte("target content")
	for _, kind := range []string{"absolute", "relative"} {
		t.Run(kind, func(t *testing.T) {
			g := getter(t)
			targetDir := t.TempDir()
			target := filepath.Join(targetDir, "real.zip")
			if err := os.WriteFile(target, body, 0o644); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(targetDir, "link.zip")
			linkTo := target
			if kind == "relative" {
				linkTo = "real.zip"
			}
			if err := os.Symlink(linkTo, link); err != nil {
				t.Fatal(err)
			}
			p, err := g.Get(context.Background(), Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: sum(body), Adopt: []string{link}})
			if err != nil {
				t.Fatal(err)
			}
			info, err := os.Lstat(p)
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode()&os.ModeSymlink != 0 {
				t.Fatal("the cache entry must not be a symlink")
			}
			if b, err := os.ReadFile(p); err != nil || string(b) != string(body) {
				t.Fatalf("content = %q, %v", b, err)
			}
		})
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
