package fetch

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const DefaultOpenSSHReleases = "https://github.com/Mavergreen/openssh/releases/download"

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
func (g *Getter) OpenSSH(ctx context.Context, releases, tag, adoptDir string) (OpenSSHPkgs, error) {
	url := releases + "/" + tag
	sums, err := g.openSSHSums(ctx, url, tag, adoptDir)
	if err != nil {
		return OpenSSHPkgs{}, err
	}
	var base, replace string
	want := map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(sums))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 || !strings.HasSuffix(f[1], ".pkg") {
			continue
		}
		name := f[1]
		want[name] = f[0]
		if strings.Contains(name, "System-Replace") || strings.Contains(name, "system-replace") {
			if replace != "" {
				return OpenSSHPkgs{}, fmt.Errorf("two replacement packages in SHA256SUMS: %s and %s", replace, name)
			}
			replace = name
		} else {
			if base != "" {
				return OpenSSHPkgs{}, fmt.Errorf("two base packages in SHA256SUMS: %s and %s", base, name)
			}
			base = name
		}
	}
	if base == "" {
		return OpenSSHPkgs{}, fmt.Errorf("no base .pkg named in SHA256SUMS -- release %s looks wrong", tag)
	}
	if replace == "" {
		return OpenSSHPkgs{}, fmt.Errorf("no System-Replace .pkg named in SHA256SUMS -- release %s looks wrong", tag)
	}
	out := OpenSSHPkgs{Tag: tag}
	for _, p := range []struct {
		name string
		dst  *string
	}{{base, &out.Base}, {replace, &out.Replace}} {
		it := Item{Name: p.name, URL: url + "/" + p.name, SHA256: want[p.name]}
		if adoptDir != "" {
			it.Adopt = []string{filepath.Join(adoptDir, p.name)}
		}
		path, err := g.Get(ctx, it)
		if err != nil {
			return OpenSSHPkgs{}, err
		}
		if ok, err := HasXarMagic(path); err != nil || !ok {
			return OpenSSHPkgs{}, fmt.Errorf("%s is not a flat package (no xar magic)", path)
		}
		*p.dst = path
	}
	g.logf("OpenSSH %s verified: %s, %s", tag, base, replace)
	return out, nil
}

// openSSHSums fetches (or reuses/adopts) the release's own SHA256SUMS.
// SHA256SUMS itself is not pinned: it is trusted as the release's
// statement of its own checksums (INHERITED from fetch-openssh.sh), and
// it comes over TLS from GitHub.
func (g *Getter) openSSHSums(ctx context.Context, url, tag, adoptDir string) ([]byte, error) {
	dest := filepath.Join(g.Paths.Cache(), "openssh", tag, "SHA256SUMS")
	if b, err := os.ReadFile(dest); err == nil && len(b) > 0 {
		return b, nil
	}
	if adoptDir != "" {
		if b, err := os.ReadFile(filepath.Join(adoptDir, "SHA256SUMS")); err == nil && len(b) > 0 {
			return b, writeAtomic(dest, b)
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url+"/SHA256SUMS", nil)
	if err != nil {
		return nil, err
	}
	c := g.Client
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("cannot fetch %s/SHA256SUMS: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cannot fetch %s/SHA256SUMS (%s) -- is %s a real release?", url, resp.Status, tag)
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(resp.Body); err != nil {
		return nil, err
	}
	return buf.Bytes(), writeAtomic(dest, buf.Bytes())
}

func writeAtomic(dest string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(dest+".part", b, 0o644); err != nil {
		return err
	}
	return os.Rename(dest+".part", dest)
}
