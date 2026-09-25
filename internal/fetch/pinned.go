package fetch

import (
	"context"
	"path/filepath"

	"github.com/Mavergreen/vm-guest/internal/pins"
)

// Pinned fetches the registry's source name into the cache and returns
// its path: the Go form of lib/vendor.sh's fetch_source, for inputs
// that are neither Apple's nor the guest's OpenSSH -- the firmware's
// tarballs, efibuild.sh and the kext releases. The file is named by its
// URL's last path element, as fetch_source names it, and a verified copy
// of that name in any of adoptDirs (the shell tree's build/ directory)
// is adopted instead of downloaded. The returned path is read-only, as
// every path Get returns is.
func (g *Getter) Pinned(ctx context.Context, reg *pins.Registry, name string, adoptDirs []string) (string, error) {
	src, err := reg.Lookup(name)
	if err != nil {
		return "", err
	}
	filename, err := Filename(src.URL)
	if err != nil {
		return "", err
	}
	var adopt []string
	for _, d := range adoptDirs {
		if d != "" {
			adopt = append(adopt, filepath.Join(d, filename))
		}
	}
	return g.Get(ctx, Item{Name: name, URL: src.URL, SHA256: src.SHA256, Filename: filename, Adopt: adopt})
}
