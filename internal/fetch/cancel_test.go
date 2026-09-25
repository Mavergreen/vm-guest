//go:build unix

package fetch

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// TestAnAlreadyCancelledGetDoesNothing: spec §2 has a signal cancel the
// command in progress. A Get whose context is already done must say so --
// not adopt a perfectly good candidate and report success, which is what
// it used to do (so a Ctrl-C'd `vmavs fetch` could exit 0).
func TestAnAlreadyCancelledGetDoesNothing(t *testing.T) {
	body := []byte("good")
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Write(body)
	}))
	defer srv.Close()
	old := filepath.Join(t.TempDir(), "x.zip")
	if err := os.WriteFile(old, body, 0o644); err != nil {
		t.Fatal(err)
	}
	g := getter(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := g.Get(ctx, Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: sum(body), Adopt: []string{old}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if _, err := os.Stat(g.Paths.Cache()); !os.IsNotExist(err) {
		t.Fatalf("a cancelled Get adopted or created something under %s (%v)", g.Paths.Cache(), err)
	}
	if hits.Load() != 0 {
		t.Fatalf("a cancelled Get made %d request(s)", hits.Load())
	}
}

// TestCancellingMidHashReturnsPromptly: the adoption candidate is a FIFO
// that never ends, so hashing it can only stop by noticing the context.
// The writer keeps writing after cancelling, so a hash that ignored ctx
// would never return.
func TestCancellingMidHashReturnsPromptly(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "x.zip")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		w, err := os.OpenFile(fifo, os.O_WRONLY, 0)
		if err != nil {
			return
		}
		defer w.Close()
		chunk := make([]byte, 64<<10)
		for n := 0; ; n++ {
			if n == 16 {
				cancel() // a megabyte in: mid-hash
			}
			if _, err := w.Write(chunk); err != nil {
				return // the reader gave up: EPIPE
			}
		}
	}()

	g := getter(t)
	done := make(chan error, 1)
	go func() {
		_, err := g.Get(ctx, Item{Name: "x", URL: "http://127.0.0.1:1/x.zip", SHA256: sum([]byte("good")), Adopt: []string{fifo}})
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v, want context.Canceled", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Get kept hashing after its context was cancelled")
	}
	if _, err := os.Stat(g.Paths.Cache()); !os.IsNotExist(err) {
		t.Fatalf("a cancelled Get left %s behind (%v)", g.Paths.Cache(), err)
	}
}

// TestCancellingMidDownloadLeavesNoTemp: the download's temp file is
// removed, and so is the cache directory made for it.
func TestCancellingMidDownloadLeavesNoTemp(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(make([]byte, 1<<16))
		w.(http.Flusher).Flush()
		cancel()
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer srv.Close()
	defer close(release)
	g := getter(t)
	_, err := g.Get(ctx, Item{Name: "x", URL: srv.URL + "/x.zip", SHA256: sum([]byte("good"))})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if _, err := os.Stat(g.Paths.Cache()); !os.IsNotExist(err) {
		t.Fatalf("a cancelled download left %s behind (%v)", g.Paths.Cache(), err)
	}
}
