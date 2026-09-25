package fetch

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const DefaultOpenSSHReleases = "https://github.com/Mavergreen/openssh/releases/download"

// maxSumsBytes caps how much of a SHA256SUMS response is read: a captive
// portal or another non-answer is commonly an HTML page, not a truncated
// SUMS file, and there is no reason to buffer an unbounded one.
const maxSumsBytes = 1 << 20 // 1 MiB

type OpenSSHPkgs struct{ Tag, Base, Replace string }

// OpenSSHTag is the release components/openssh/version pins (Renovate
// bumps it; the -mavericks.N suffix is the family's).
func OpenSSHTag() (string, error) {
	b, err := fs.ReadFile(vmguest.Files, "components/openssh/version")
	if err != nil {
		return "", err
	}
	tag := pins.ComponentVersion(b)
	if tag == "" {
		return "", fmt.Errorf("components/openssh/version names no release tag")
	}
	return tag, nil
}

// OpenSSH fetches the release's two packages, verified against the
// release's own SHA256SUMS. Nothing constructs an asset name from a
// prefix: the names are whatever SUMS says, so a renamed prefix cannot
// 404 across a pin bump.
//
// adoptDirs is tried in order, like InstallESD's adopt list: a partial or
// stale copy in the first directory must not shadow a good one in the
// second -- Get's own adoption loop already tries every candidate and
// verifies each one, so handing it every directory (rather than picking
// one here by existence alone) is what makes that guarantee reach this
// far.
func (g *Getter) OpenSSH(ctx context.Context, releases, tag string, adoptDirs []string) (OpenSSHPkgs, error) {
	url := releases + "/" + tag
	sumsPath := g.Paths.OpenSSHSums(tag)
	sums, err := g.fetchOpenSSHSums(ctx, url, tag, adoptDirs, sumsPath)
	if err != nil {
		return OpenSSHPkgs{}, err
	}
	base, replace, want, err := parseOpenSSHSums(sums)
	if err != nil {
		return OpenSSHPkgs{}, fmt.Errorf("%s: %w -- release %s looks wrong", sumsPath, err, tag)
	}
	out := OpenSSHPkgs{Tag: tag}
	for _, p := range []struct {
		name string
		dst  *string
	}{{base, &out.Base}, {replace, &out.Replace}} {
		it := Item{Name: p.name, URL: url + "/" + p.name, SHA256: want[p.name]}
		for _, dir := range adoptDirs {
			if dir == "" {
				continue
			}
			it.Adopt = append(it.Adopt, filepath.Join(dir, p.name))
		}
		path, err := g.Get(ctx, it)
		if err != nil {
			return OpenSSHPkgs{}, err
		}
		ok, err := HasXarMagic(path)
		if err != nil {
			return OpenSSHPkgs{}, fmt.Errorf("%s: %w", path, err)
		}
		if !ok {
			return OpenSSHPkgs{}, fmt.Errorf("%s is not a flat package (no xar magic)", path)
		}
		*p.dst = path
	}
	g.logf("OpenSSH %s verified: %s, %s", tag, base, replace)
	return out, nil
}

// parseOpenSSHSums classifies SHA256SUMS' rows by name -- ".pkg" lines
// only -- into exactly one base package and one System-Replace package,
// validating each row's checksum column (ruling C's format check applies
// here too: SUMS is not itself pinned, and a malformed column must not
// reach CacheFile).
func parseOpenSSHSums(b []byte) (base, replace string, want map[string]string, err error) {
	want = map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 || !strings.HasSuffix(f[1], ".pkg") {
			continue
		}
		name := f[1]
		if err := validateFilename(name); err != nil {
			return "", "", nil, fmt.Errorf("entry %q: %w", name, err)
		}
		if err := validateSHA256(f[0]); err != nil {
			return "", "", nil, fmt.Errorf("entry for %s: %w", name, err)
		}
		want[name] = f[0]
		if strings.Contains(name, "System-Replace") || strings.Contains(name, "system-replace") {
			if replace != "" {
				return "", "", nil, fmt.Errorf("two replacement packages in SHA256SUMS: %s and %s", replace, name)
			}
			replace = name
		} else {
			if base != "" {
				return "", "", nil, fmt.Errorf("two base packages in SHA256SUMS: %s and %s", base, name)
			}
			base = name
		}
	}
	if err := sc.Err(); err != nil {
		return "", "", nil, err
	}
	if base == "" {
		return "", "", nil, fmt.Errorf("no base .pkg named in SHA256SUMS")
	}
	if replace == "" {
		return "", "", nil, fmt.Errorf("no System-Replace .pkg named in SHA256SUMS")
	}
	return base, replace, want, nil
}

// fetchOpenSSHSums returns the release's own SHA256SUMS: reused from the
// cache, or adopted from the shell tree's download (trying every dir in
// adoptDirs in order, like OpenSSH's own package adoption, so a partial
// copy in one directory cannot shadow a good one in another), when either
// already parses to exactly one base and one replacement package;
// otherwise fetched from the network with the same retry/backoff as a
// download. Content that does not parse is never persisted -- a cached
// SUMS that somehow fails to parse is an error naming its path, not a
// silent re-fetch, because a hand-edited or hand-restored cache file
// deserves attention, not to be quietly discarded.
//
// SHA256SUMS itself is not pinned: it is trusted as the release's
// statement of its own checksums (INHERITED from fetch-openssh.sh), and
// it comes over TLS from GitHub.
func (g *Getter) fetchOpenSSHSums(ctx context.Context, url, tag string, adoptDirs []string, dest string) ([]byte, error) {
	if b, err := os.ReadFile(dest); err == nil {
		if len(b) > 0 {
			if _, _, _, perr := parseOpenSSHSums(b); perr != nil {
				return nil, fmt.Errorf("%s does not parse as SHA256SUMS: %w (remove it to fetch again)", dest, perr)
			}
			return b, nil
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("%s: %w", dest, err)
	}

	for _, dir := range adoptDirs {
		if dir == "" {
			continue
		}
		old := filepath.Join(dir, "SHA256SUMS")
		b, err := os.ReadFile(old)
		if err != nil || len(b) == 0 {
			continue
		}
		if _, _, _, perr := parseOpenSSHSums(b); perr == nil {
			if err := writeAtomic(dest, b); err != nil {
				return nil, err
			}
			return b, nil
		} else {
			g.logf("not adopting %s: %v", old, perr)
		}
	}

	b, err := g.fetchSums(ctx, url+"/SHA256SUMS", tag)
	if err != nil {
		return nil, err
	}
	if _, _, _, perr := parseOpenSSHSums(b); perr != nil {
		return nil, fmt.Errorf("%s/SHA256SUMS: does not parse as SHA256SUMS: %w", url, perr)
	}
	if err := writeAtomic(dest, b); err != nil {
		return nil, err
	}
	return b, nil
}

// fetchSums fetches url with the same retry/backoff policy as a download,
// and the same stall timeout: a captive portal is as happy to hold a SUMS
// request open as a 5 GB one.
func (g *Getter) fetchSums(ctx context.Context, url, tag string) ([]byte, error) {
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
	var b []byte
	var err error
	for attempt := 0; attempt <= retries; attempt++ {
		if attempt > 0 {
			g.logf("%s: retrying in %v (%v)", url, wait, err)
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			wait *= 2
		}
		var retry bool
		b, retry, err = g.fetchSumsOnce(ctx, url, tag)
		if err == nil || !retry {
			return b, err
		}
	}
	return b, err
}

func (g *Getter) fetchSumsOnce(ctx context.Context, url, tag string) ([]byte, bool, error) {
	stall := g.stallDuration()
	attemptCtx, watch := newStallWatch(ctx, stall)
	defer watch.Stop()

	req, err := http.NewRequestWithContext(attemptCtx, http.MethodGet, url, nil)
	if err != nil {
		return nil, false, err
	}
	c := g.Client
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		retry, werr := classifyAttemptErr(ctx, watch, stall, url, err)
		return nil, retry, werr
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode >= 500, fmt.Errorf("cannot fetch %s (%s) -- is %s a real release?", url, resp.Status, tag)
	}
	var buf bytes.Buffer
	// Read one byte past the cap: reaching it means the real response is
	// too big (or unbounded) rather than silently truncating a response
	// that happens to be exactly the cap, or worse, one just over it.
	src := watch.Reader(resp.Body)
	n, err := io.Copy(&buf, io.LimitReader(src, maxSumsBytes+1))
	if err != nil {
		retry, werr := classifyAttemptErr(ctx, watch, stall, url, err)
		return nil, retry, werr
	}
	if n > maxSumsBytes {
		return nil, false, fmt.Errorf("%s: response is at least %d bytes -- refusing to buffer more of what should be a small text file", url, n)
	}
	return buf.Bytes(), false, nil
}

func writeAtomic(dest string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	tmpDir, err := os.MkdirTemp(filepath.Dir(dest), ".sums-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)
	tmp := filepath.Join(tmpDir, filepath.Base(dest))
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}
