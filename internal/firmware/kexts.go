package firmware

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// kextsDir is where the kext bundles are unpacked: build/kexts.
func (b *Builder) kextsDir() string { return filepath.Join(b.Paths.Build(), "kexts") }

// Kexts unpacks each pinned kext release's bundle into build/kexts, once:
// the layout the EFI image copies from. These are the only things in the
// image not built here (acidanthera ships them as binaries); they are
// pinned by checksum, and each bundle must hold the two files
// config.plist names for it, checked by name so a failure says which.
func (b *Builder) Kexts(ctx context.Context, in Inputs) ([]string, error) {
	var out []string
	for _, k := range Kexts {
		bundle := filepath.Join(b.kextsDir(), k.Name+".kext")
		if _, err := os.Stat(bundle); err == nil {
			b.logf("%s.kext already unpacked at %s", k.Name, bundle)
		} else {
			archive, err := b.input(in, k.Source)
			if err != nil {
				return nil, err
			}
			if err := extractKext(ctx, archive, k.Name, bundle); err != nil {
				return nil, err
			}
		}
		if err := checkKext(bundle, k.Name); err != nil {
			return nil, err
		}
		b.logf("%s.kext ready at %s", k.Name, bundle)
		out = append(out, bundle)
	}
	return out, nil
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
