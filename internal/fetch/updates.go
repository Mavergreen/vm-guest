package fetch

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

// updateSources is image/fetch-updates.sh's table, in install order.
var updateSources = map[string][]string{
	"none":     nil,
	"security": {"apple-secupd-2016-004"},
	"all": {
		"apple-secupd-2016-004",
		"apple-safari-9.1.3",
		"apple-itunes-12.6.2-corefp",
		"apple-itunes-12.6.2-mobiledevice",
		"apple-itunes-12.6.2-itunesaccess",
		"apple-itunes-12.6.2-itunesx",
		"apple-itunes-12.6.2-coreadi",
	},
}

func UpdateNames(selection string) ([]string, error) {
	names, ok := updateSources[selection]
	if !ok {
		return nil, fmt.Errorf("unknown updates selection %q: choose one of %s", selection, strings.Join(config.UpdateChoices, ", "))
	}
	return append([]string(nil), names...), nil
}

type Update struct{ Name, Path, Staged string }

// StagedName is how the installer media presents the n-th update
// (1-based): the install order is legible in the name, and the prefix
// keeps it from colliding with Apple's own packages on the media.
func StagedName(n int, path string) string {
	return fmt.Sprintf("mqg-update-%02d-%s", n, filepath.Base(path))
}

// Updates fetches one selection, verified against the registry, in the
// order the guest must install them. "none" fetches nothing.
func (g *Getter) Updates(ctx context.Context, reg *pins.Registry, selection, adoptDir string) ([]Update, error) {
	names, err := UpdateNames(selection)
	if err != nil {
		return nil, err
	}
	var out []Update
	for i, n := range names {
		src, err := reg.Lookup(n)
		if err != nil {
			return nil, err
		}
		it := Item{Name: n, URL: src.URL, SHA256: src.SHA256}
		if adoptDir != "" {
			if fn, err := Filename(src.URL); err == nil {
				it.Adopt = []string{filepath.Join(adoptDir, fn)}
			}
		}
		path, err := g.Get(ctx, it)
		if err != nil {
			return nil, err
		}
		if ok, err := HasXarMagic(path); err != nil || !ok {
			return nil, fmt.Errorf("%s is not a flat package (no xar magic)", path)
		}
		out = append(out, Update{Name: n, Path: path, Staged: StagedName(i+1, path)})
	}
	return out, nil
}
