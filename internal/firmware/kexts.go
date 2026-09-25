package firmware

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// kextsDir is where the kext bundles are unpacked: build/kexts.
func (b *Builder) kextsDir() string { return filepath.Join(b.Paths.Build(), "kexts") }

// kextMarker is where Kexts records which pinned release a bundle it
// unpacked came from: build/kexts/.<name>.kext.sha256, the zip's sha256.
func (b *Builder) kextMarker(name string) string {
	return filepath.Join(b.kextsDir(), "."+name+".kext.sha256")
}

// Kexts unpacks each pinned kext release's bundle into build/kexts: the
// layout the EFI image copies from. These are the only things in the
// image not built here (acidanthera ships them as binaries); they are
// pinned by checksum, and each bundle must hold the two files
// config.plist names for it, checked by name so a failure says which.
//
// A bundle is unpacked once, and a marker beside it records the release
// it came from, so that a pin bump replaces it rather than shipping the
// old one:
//   - marker equal to the pin: the bundle is kept;
//   - another marker: the bundle is this code's, from an older pin, and
//     is replaced by the pinned release's;
//   - no marker (the shell tree unpacked it): the pinned release is
//     unpacked beside it and compared, path by path and byte by byte. If
//     they are the same the marker is written; if not, it is an error,
//     and the bundle is left alone -- nothing proves it is ours to delete.
func (b *Builder) Kexts(ctx context.Context, in Inputs) ([]string, error) {
	var out []string
	for _, k := range Kexts {
		bundle := filepath.Join(b.kextsDir(), k.Name+".kext")
		if err := b.kext(ctx, in, k, bundle); err != nil {
			return nil, err
		}
		if err := checkKext(bundle, k.Name); err != nil {
			return nil, err
		}
		b.logf("%s.kext ready at %s", k.Name, bundle)
		out = append(out, bundle)
	}
	return out, nil
}

// kext brings bundle up to the pinned release of k.
func (b *Builder) kext(ctx context.Context, in Inputs, k Kext, bundle string) error {
	pin, err := b.Registry.Lookup(k.Source)
	if err != nil {
		return err
	}
	marker := b.kextMarker(k.Name)
	have, markerErr := os.ReadFile(marker)
	if markerErr != nil && !errors.Is(markerErr, fs.ErrNotExist) {
		return markerErr
	}
	if _, err := os.Lstat(bundle); errors.Is(err, fs.ErrNotExist) {
		archive, err := b.input(in, k.Source)
		if err != nil {
			return err
		}
		if err := extractKext(ctx, archive, k.Name, bundle); err != nil {
			return err
		}
		return writeFileAtomic(marker, []byte(pin.SHA256+"\n"), 0o644)
	} else if err != nil {
		return err
	}
	if markerErr == nil && strings.TrimRight(string(have), "\n") == pin.SHA256 {
		b.logf("%s.kext already unpacked at %s", k.Name, bundle)
		return nil
	}

	archive, err := b.input(in, k.Source)
	if err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(b.kextsDir(), "."+k.Name+".kext.unpack-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	fresh := filepath.Join(tmp, k.Name+".kext")
	if err := extractKext(ctx, archive, k.Name, fresh); err != nil {
		return err
	}

	if markerErr == nil {
		b.logf("%s.kext at %s is from another pin (%s); replacing it with %s", k.Name, bundle,
			strings.TrimRight(string(have), "\n"), pin.SHA256)
		if err := os.RemoveAll(bundle); err != nil {
			return err
		}
		if err := os.Rename(fresh, bundle); err != nil {
			return err
		}
		return writeFileAtomic(marker, []byte(pin.SHA256+"\n"), 0o644)
	}

	same, err := sameTree(bundle, fresh)
	if err != nil {
		return err
	}
	if !same {
		return fmt.Errorf("%s does not match the pinned %s (%s); remove it and re-run", bundle, k.Source, pin.SHA256)
	}
	b.logf("%s.kext at %s matches the pinned %s; keeping it", k.Name, bundle, k.Source)
	return writeFileAtomic(marker, []byte(pin.SHA256+"\n"), 0o644)
}

// sameTree says whether two directory trees hold the same paths, each
// the same kind (directory, file, or other), and the same file bytes.
func sameTree(a, b string) (bool, error) {
	ta, err := readTree(a)
	if err != nil {
		return false, err
	}
	tb, err := readTree(b)
	if err != nil {
		return false, err
	}
	if len(ta) != len(tb) {
		return false, nil
	}
	for p, x := range ta {
		y, ok := tb[p]
		if !ok || x.kind != y.kind || !bytes.Equal(x.data, y.data) {
			return false, nil
		}
	}
	return true, nil
}

type treeEntry struct {
	kind fs.FileMode
	data []byte
}

// readTree is every path under dir with its kind and, for a regular
// file, its bytes. Symlinks are not followed.
func readTree(dir string) (map[string]treeEntry, error) {
	t := map[string]treeEntry{}
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		e := treeEntry{kind: d.Type()}
		if d.Type().IsRegular() {
			if e.data, err = os.ReadFile(p); err != nil {
				return err
			}
		}
		t[filepath.ToSlash(rel)] = e
		return nil
	})
	return t, err
}

// checkKext checks bundle holds the two paths config.plist names for a
// kext, PlistPath and ExecutablePath, as regular files.
func checkKext(bundle, name string) error {
	for _, want := range []string{filepath.Join("Contents", "Info.plist"), filepath.Join("Contents", "MacOS", name)} {
		if fi, err := os.Stat(filepath.Join(bundle, want)); err != nil || !fi.Mode().IsRegular() {
			return fmt.Errorf("%s is not a kext bundle: no %s", bundle, filepath.ToSlash(want))
		}
	}
	return nil
}
