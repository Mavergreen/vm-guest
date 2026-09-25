// Package fetch downloads this project's pinned inputs, verified. One
// primitive, Getter.Get, does every download; the fetchers for Apple's
// installer, the updates and the guest's OpenSSH are built on it.
package fetch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

type Getter struct {
	Client  *http.Client // nil: http.DefaultClient
	Paths   config.Paths
	Log     func(format string, a ...any)
	Retries int           // attempts after the first; 0 means 3
	Backoff time.Duration // first retry's wait, doubling; 0 means 1s
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

func (g *Getter) Get(ctx context.Context, it Item) (string, error) {
	name := it.Filename
	if name == "" {
		var err error
		if name, err = Filename(it.URL); err != nil {
			return "", err
		}
	}
	dest := g.Paths.CacheFile(it.SHA256, name)
	if _, err := os.Stat(dest); err == nil {
		got, err := SHA256File(dest)
		if err != nil {
			return "", err
		}
		if got != it.SHA256 {
			return "", fmt.Errorf("checksum mismatch for %s: want %s, got %s (remove it to fetch again)", dest, it.SHA256, got)
		}
		return dest, nil
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}
	for _, old := range it.Adopt {
		if got, err := SHA256File(old); err == nil {
			if got == it.SHA256 {
				if err := adopt(old, dest); err != nil {
					return "", err
				}
				g.logf("%s: adopted %s (verified)", it.Name, old)
				return dest, nil
			}
			g.logf("%s: not adopting %s: checksum %s, want %s", it.Name, old, got, it.SHA256)
		}
	}
	if it.noFetch {
		return "", errNotCached
	}
	if err := g.download(ctx, it, dest); err != nil {
		return "", err
	}
	return dest, nil
}

func adopt(src, dest string) error {
	part := dest + ".part"
	os.Remove(part)
	if err := os.Link(src, part); err != nil {
		if err := copyFile(src, part); err != nil {
			return err
		}
	}
	return os.Rename(part, dest)
}

func (g *Getter) download(ctx context.Context, it Item, dest string) error {
	retries, wait := g.Retries, g.Backoff
	if retries == 0 {
		retries = 3
	}
	if wait == 0 {
		wait = time.Second
	}
	part := dest + ".part"
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
		retry, err = g.once(ctx, it, part)
		if err == nil || !retry {
			break
		}
	}
	if err != nil {
		return err
	}
	got, err := SHA256File(part)
	if err != nil {
		return err
	}
	if got != it.SHA256 {
		return fmt.Errorf("checksum mismatch for %s: want %s, got %s; nothing was renamed into place (%s kept for inspection)", it.URL, it.SHA256, got, part)
	}
	return os.Rename(part, dest)
}

// once is one attempt. retry reports whether a failure is worth another.
func (g *Getter) once(ctx context.Context, it Item, part string) (retry bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, it.URL, nil)
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
		return ctx.Err() == nil, fmt.Errorf("%s: %w", it.URL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return resp.StatusCode >= 500, fmt.Errorf("%s: HTTP %s", it.URL, resp.Status)
	}
	f, err := os.Create(part)
	if err != nil {
		return false, err
	}
	var src io.Reader = resp.Body
	if resp.ContentLength > 64<<20 {
		src = &progress{r: resp.Body, total: resp.ContentLength, name: it.Name, log: g.logf, next: time.Now().Add(10 * time.Second)}
	}
	_, err = io.Copy(f, src)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return ctx.Err() == nil, fmt.Errorf("%s: %w", it.URL, err)
	}
	return false, nil
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
	var h hash.Hash = sha256.New()
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
	return out.Close()
}
