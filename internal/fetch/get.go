// Package fetch downloads this project's pinned inputs, verified. One
// primitive, Getter.Get, does every download; the fetchers for Apple's
// installer, the updates and the guest's OpenSSH are built on it.
package fetch

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

type Getter struct {
	Client  *http.Client // nil: http.DefaultClient
	Paths   config.Paths
	Log     func(format string, a ...any)
	Retries int           // attempts after the first; 0 means 3, negative means 0
	Backoff time.Duration // first retry's wait, doubling; 0 means 1s

	// StallTimeout aborts (and retries) an attempt that has read no body
	// bytes for this long: a captive portal or a stuck connection can hold
	// a socket open without ever failing it outright. 0 means 2 minutes.
	StallTimeout time.Duration
}

type Item struct {
	Name     string // for messages
	URL      string
	SHA256   string
	Filename string // "" derives it from URL
	Header   http.Header
	Adopt    []string // existing files to verify and reuse before downloading

	// noFetch, when set, makes Get check the cache and Adopt only, never
	// the network: errNotCached if neither has it.
	noFetch bool
}

// errNotCached is Get's result with Item.noFetch set, when nothing cached
// or adoptable satisfies the item.
var errNotCached = errors.New("not in the cache and no adoptable copy")

var sha256Hex = regexp.MustCompile(`^[0-9a-f]{64}$`)

// validateSHA256 refuses anything that is not exactly 64 lowercase hex
// characters: CacheFile joins it straight into a path, so a checksum
// column holding something like "../../../escaped" would otherwise escape
// the cache directory.
func validateSHA256(s string) error {
	if !sha256Hex.MatchString(s) {
		return fmt.Errorf("refusing checksum %q: want 64 lowercase hex characters", s)
	}
	return nil
}

// validateFilename refuses a name that would not stay inside the cache
// directory it is joined into: empty, ".", "..", or containing a path
// separator. A URL like https://h/x/.. derives exactly ".." as its last
// path segment, and Filename does not itself reject that.
func validateFilename(name string) error {
	if name == "" || name == "." || name == ".." {
		return fmt.Errorf("refusing filename %q", name)
	}
	if strings.ContainsRune(name, '/') || (os.PathSeparator != '/' && strings.ContainsRune(name, os.PathSeparator)) {
		return fmt.Errorf("refusing filename %q: contains a path separator", name)
	}
	return nil
}

// Filename is the URL's last path segment, query string and all, as
// lib/vendor.sh fetch_source derives it.
func Filename(url string) (string, error) {
	i := strings.Index(url, "://")
	if i < 0 || !strings.Contains(url[i+3:], "/") {
		return "", fmt.Errorf("cannot derive a filename from %s -- it has no path; add one to the registry entry", url)
	}
	name := url[strings.LastIndex(url, "/")+1:]
	if name == "" {
		return "", fmt.Errorf("cannot derive a filename from %s -- it ends in \"/\"", url)
	}
	return name, nil
}

// Get returns a verified path to it: from the cache, else adopted from one
// of it.Adopt (verified before AND after being placed -- see adoptCandidate),
// else downloaded.
//
// A cached file may share an inode with a file elsewhere (the shell
// tree's own download, adopted by a hard link): nothing in this package
// ever opens a cached file for writing, truncates it or changes its mode.
// Every write happens on a freshly created, uniquely named file, verified
// in full, then renamed into place; nothing unverified is ever renamed to
// its final name.
func (g *Getter) Get(ctx context.Context, it Item) (string, error) {
	name := it.Filename
	if name == "" {
		var err error
		if name, err = Filename(it.URL); err != nil {
			return "", err
		}
	}
	if err := validateFilename(name); err != nil {
		return "", err
	}
	if err := validateSHA256(it.SHA256); err != nil {
		return "", err
	}
	dest := g.Paths.CacheFile(it.SHA256, name)
	dir := filepath.Dir(dest)

	if _, err := os.Stat(dest); err == nil {
		got, err := SHA256File(dest)
		if err != nil {
			return "", err
		}
		if got != it.SHA256 {
			return "", fmt.Errorf("checksum mismatch for %s: want %s, got %s (remove it to fetch again)", dest, it.SHA256, got)
		}
		return dest, nil
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("stat %s: %w", dest, err)
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	g.cleanStaleTemps(it, dir, name)
	for _, old := range it.Adopt {
		if g.adoptCandidate(it, old, dest, dir, name) {
			return dest, nil
		}
	}

	if it.noFetch {
		return "", errNotCached
	}
	if err := g.download(ctx, it, dir, name, dest); err != nil {
		return "", err
	}
	return dest, nil
}

// stallDuration is StallTimeout, defaulted: 0 or negative means 2
// minutes. A negative value is never meaningful (time.NewTimer treats it
// as "fire immediately", which would abort every attempt as instantly
// stalled), so it gets the same default as unset.
func (g *Getter) stallDuration() time.Duration {
	if g.StallTimeout <= 0 {
		return 2 * time.Minute
	}
	return g.StallTimeout
}

// cleanStaleTemps removes this item's own leftover temp files and
// directories from an earlier attempt that never finished cleanly: a
// process killed by SIGKILL, OOM, or power loss leaves a uniquely named
// ".<name>.<rand>.part" file (attempt's own temp), or a ".adopt-*"
// directory (adoptCandidate's), behind forever, since nothing else ever
// removes them. A live attempt keeps its temp's mtime fresh with every
// byte written, or self-aborts at the stall timeout, so anything older
// than max(10x the stall timeout, 30 minutes) is provably dead -- and
// provably ours, since nothing but vmavs creates anything inside this
// directory. Removing a stale entry that happens to be a hard link
// cannot hurt the file it points to: removing a directory entry only
// drops that entry's reference to the inode, leaving every other link
// (including whatever it might have been adopted from) untouched.
func (g *Getter) cleanStaleTemps(it Item, dir, name string) {
	threshold := 10 * g.stallDuration()
	if threshold < 30*time.Minute {
		threshold = 30 * time.Minute
	}
	cutoff := time.Now().Add(-threshold)

	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	prefix := "." + name + "."
	for _, e := range entries {
		n := e.Name()
		isTempFile := !e.IsDir() && strings.HasPrefix(n, prefix) && strings.HasSuffix(n, ".part") && len(n) > len(prefix)+len(".part")
		isAdoptDir := e.IsDir() && strings.HasPrefix(n, ".adopt-")
		if !isTempFile && !isAdoptDir {
			continue
		}
		info, err := e.Info()
		if err != nil || info.ModTime().After(cutoff) {
			continue // fresh (still being written), or gone already -- leave a live attempt alone
		}
		full := filepath.Join(dir, n)
		if isAdoptDir {
			if err := os.RemoveAll(full); err == nil {
				g.logf("%s: removed a stale leftover directory %s (older than %v)", it.Name, full, threshold)
			}
			continue
		}
		if err := os.Remove(full); err == nil {
			g.logf("%s: removed a stale leftover temp %s (older than %v)", it.Name, full, threshold)
		}
	}
}

// testAdoptHook, when set, runs after adoptCandidate has hashed a
// candidate and confirmed it matches, but before that candidate is linked
// or copied into the cache: a seam for a test to simulate the source
// changing in that window, which the re-hash below this hook must catch.
var testAdoptHook func()

// adoptCandidate hashes old and, if it matches it.SHA256, places a
// verified copy of it at dest. It hashes old a second time, after placing
// it (whether by hard link, which shares old's inode, or by copy) and
// immediately before the rename: old could have been replaced or changed
// between the first hash and the link/copy, and only this second check
// catches that -- hashing only once and trusting the placement would let
// unverified bytes into the cache.
//
// old is resolved through any symlinks first (filepath.EvalSymlinks): on
// Linux, os.Link on a symlink links the symlink itself, not its target,
// which for a relative symlink then breaks as soon as it is moved to a
// new directory (its relative target no longer resolves from there).
// Resolving first means the link (or copy) is always of a real file.
//
// Every failure here -- old cannot be resolved or read, it does not
// match, placing it fails, or the re-hash fails or does not match -- is
// reported (via g.Log, except a candidate that simply does not exist)
// and the candidate is skipped, never treated as a reason to fail the
// whole Get: an adoption candidate is an optimization, and one candidate
// being unusable says nothing about whether the next one, or a download,
// will work.
func (g *Getter) adoptCandidate(it Item, old, dest, dir, name string) bool {
	real, err := filepath.EvalSymlinks(old)
	if err != nil {
		if !os.IsNotExist(err) {
			g.logf("%s: cannot resolve %s for adoption: %v", it.Name, old, err)
		}
		return false
	}
	got, err := SHA256File(real)
	if err != nil {
		if !os.IsNotExist(err) {
			g.logf("%s: cannot check %s for adoption: %v", it.Name, old, err)
		}
		return false
	}
	if got != it.SHA256 {
		g.logf("%s: not adopting %s: checksum %s, want %s", it.Name, old, got, it.SHA256)
		return false
	}
	if testAdoptHook != nil {
		testAdoptHook()
	}

	tmpDir, err := os.MkdirTemp(dir, ".adopt-*")
	if err != nil {
		g.logf("%s: cannot prepare to adopt %s: %v", it.Name, old, err)
		return false
	}
	defer os.RemoveAll(tmpDir)
	tmp := filepath.Join(tmpDir, name)

	if err := os.Link(real, tmp); err != nil {
		if err := copyFile(real, tmp); err != nil {
			g.logf("%s: cannot adopt %s: %v", it.Name, old, err)
			return false
		}
	}

	got2, err := SHA256File(tmp)
	if err != nil {
		g.logf("%s: cannot verify the adopted copy of %s: %v", it.Name, old, err)
		return false
	}
	if got2 != it.SHA256 {
		g.logf("%s: not adopting %s: it changed while being adopted (now %s, want %s)", it.Name, old, got2, it.SHA256)
		return false
	}
	if err := os.Rename(tmp, dest); err != nil {
		g.logf("%s: cannot place the adopted copy of %s: %v", it.Name, old, err)
		return false
	}
	g.logf("%s: adopted %s (verified)", it.Name, old)
	return true
}

// download tries the network, retrying failures worth retrying. Each
// attempt owns a uniquely named temp file it creates itself and removes on
// any failure: no fixed ".part" name is ever used, so a second run, a
// crash mid-download, or a file an earlier attempt left behind can never
// make this attempt write through a name that already points somewhere
// else (an earlier crash's leftover, or -- the bug this guards against --
// an adopted file's shared inode).
func (g *Getter) download(ctx context.Context, it Item, dir, name, dest string) error {
	g.cleanStaleTemps(it, dir, name)
	retries := g.Retries
	switch {
	case retries == 0:
		retries = 3
	case retries < 0:
		retries = 0
	}
	wait := g.Backoff
	if wait == 0 {
		wait = time.Second
	}
	var err error
	for attempt := 0; attempt <= retries; attempt++ {
		if attempt > 0 {
			g.logf("%s: retrying in %v (%v)", it.Name, wait, err)
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return ctx.Err()
			}
			wait *= 2
		}
		var retry bool
		retry, err = g.attempt(ctx, it, dir, name, dest)
		if err == nil || !retry {
			return err
		}
	}
	return err
}

// attempt is one full download try: a unique temp file, hashed while it is
// written, verified and renamed into place on success. It removes its own
// temp file on every failure (network error, stall, or checksum mismatch)
// -- nothing is kept "for inspection": a unique name is never reused, so
// there is nothing a next attempt could confuse for its own.
func (g *Getter) attempt(ctx context.Context, it Item, dir, name, dest string) (retry bool, err error) {
	f, err := os.CreateTemp(dir, "."+name+".*.part")
	if err != nil {
		return false, err
	}
	tmp := f.Name()
	ok := false
	defer func() {
		if !ok {
			f.Close()
			os.Remove(tmp)
		}
	}()

	stall := g.stallDuration()
	attemptCtx, watch := newStallWatch(ctx, stall)
	defer watch.Stop()

	classify := func(err error) (bool, error) {
		return classifyAttemptErr(ctx, watch, stall, it.URL, err)
	}

	req, err := http.NewRequestWithContext(attemptCtx, http.MethodGet, it.URL, nil)
	if err != nil {
		return false, err
	}
	for k, vs := range it.Header {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	c := g.Client
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		return classify(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return resp.StatusCode >= 500, fmt.Errorf("%s: HTTP %s", it.URL, resp.Status)
	}

	var src io.Reader = watch.Reader(resp.Body)
	if resp.ContentLength > 64<<20 {
		src = &progress{r: src, total: resp.ContentLength, name: it.Name, log: g.logf, next: time.Now().Add(10 * time.Second)}
	}
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), src)
	if err != nil {
		return classify(err)
	}
	if err := f.Sync(); err != nil {
		return false, err
	}
	if err := f.Close(); err != nil {
		return false, err
	}
	got := hex.EncodeToString(h.Sum(nil))
	if got != it.SHA256 {
		return false, fmt.Errorf("checksum mismatch for %s: want %s, got %s; nothing was renamed into place", it.URL, it.SHA256, got)
	}
	if err := os.Rename(tmp, dest); err != nil {
		return false, err
	}
	ok = true
	return false, nil
}

// classifyErr reports whether a network-level failure is worth retrying.
// TLS/certificate failures and a malformed URL or unsupported scheme are
// permanent -- another attempt cannot fix them -- so only everything else
// (connection failures, timeouts, a short body) is retried.
func classifyErr(err error) bool {
	if err == nil {
		return false
	}
	var certErr *tls.CertificateVerificationError
	if errors.As(err, &certErr) {
		return false
	}
	var hostErr x509.HostnameError
	if errors.As(err, &hostErr) {
		return false
	}
	var authErr x509.UnknownAuthorityError
	if errors.As(err, &authErr) {
		return false
	}
	var invalidErr x509.CertificateInvalidError
	if errors.As(err, &invalidErr) {
		return false
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) && urlErr.Err != nil {
		msg := urlErr.Err.Error()
		if strings.Contains(msg, "unsupported protocol scheme") || strings.Contains(msg, "missing protocol scheme") {
			return false
		}
	}
	return true
}

// stallWatch cancels its context if Reader's returned reader goes d
// without a successful read: a captive portal or a stuck connection can
// hold a socket open, past headers, without ever failing outright.
// Shared by attempt (downloads) and fetchSumsOnce (SHA256SUMS), so both
// abort-and-retry a stalled response the same way.
type stallWatch struct {
	cancel  context.CancelFunc
	reset   chan struct{}
	done    chan struct{}
	stalled atomic.Bool
}

func newStallWatch(ctx context.Context, d time.Duration) (context.Context, *stallWatch) {
	attemptCtx, cancel := context.WithCancel(ctx)
	w := &stallWatch{cancel: cancel, reset: make(chan struct{}, 1), done: make(chan struct{})}
	go func() {
		timer := time.NewTimer(d)
		defer timer.Stop()
		for {
			select {
			case <-w.reset:
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				timer.Reset(d)
			case <-timer.C:
				w.stalled.Store(true)
				cancel()
				return
			case <-w.done:
				return
			}
		}
	}()
	return attemptCtx, w
}

// Reader wraps r so every successful read resets the watchdog.
func (w *stallWatch) Reader(r io.Reader) io.Reader { return &stallGuard{r: r, reset: w.reset} }

// Stop releases the watchdog goroutine and the context. Idempotent
// callers defer this exactly once per newStallWatch.
func (w *stallWatch) Stop() {
	close(w.done)
	w.cancel()
}

// classifyAttemptErr turns a network-level failure into (retry, error):
// the overall context being done always wins (no retry); a confirmed
// stall is retryable and says so; everything else goes through
// classifyErr.
func classifyAttemptErr(ctx context.Context, w *stallWatch, stall time.Duration, url string, err error) (bool, error) {
	if ctx.Err() != nil {
		return false, err
	}
	if w.stalled.Load() {
		return true, fmt.Errorf("%s: no data for %v: %w", url, stall, err)
	}
	return classifyErr(err), fmt.Errorf("%s: %w", url, err)
}

// stallGuard signals reset on every byte read, so a stallWatch's
// goroutine can tell "still receiving data" from "the connection is stuck".
type stallGuard struct {
	r     io.Reader
	reset chan<- struct{}
}

func (s *stallGuard) Read(b []byte) (int, error) {
	n, err := s.r.Read(b)
	if n > 0 {
		select {
		case s.reset <- struct{}{}:
		default:
		}
	}
	return n, err
}

type progress struct {
	r           io.Reader
	done, total int64
	name        string
	log         func(string, ...any)
	next        time.Time
}

func (p *progress) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.done += int64(n)
	if time.Now().After(p.next) {
		p.log("%s: %d of %d MiB", p.name, p.done>>20, p.total>>20)
		p.next = time.Now().Add(10 * time.Second)
	}
	return n, err
}

func (g *Getter) logf(format string, a ...any) {
	if g.Log != nil {
		g.Log(format, a...)
	}
}

func SHA256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// HasXarMagic reports whether path starts with "xar!", the flat-package
// magic every .pkg this project handles must carry.
func HasXarMagic(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	b := make([]byte, 4)
	if _, err := io.ReadFull(f, b); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
			return false, nil
		}
		return false, err
	}
	return string(b) == "xar!", nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
