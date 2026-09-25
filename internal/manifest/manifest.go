// Package manifest reads what image/build-image.sh (and, from phase 5,
// vmavs image) writes beside every built image: one "key<TAB>value" per
// line, with # comments.
package manifest

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
)

type Manifest struct {
	Name    string
	Path    string
	ModTime time.Time
	fields  map[string]string
}

func Load(path string) (Manifest, error) {
	f, err := os.Open(path)
	if err != nil {
		return Manifest{}, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return Manifest{}, err
	}
	m := Manifest{Path: path, ModTime: st.ModTime(), fields: map[string]string{}}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "\t")
		if !ok {
			return Manifest{}, fmt.Errorf("%s: not key<TAB>value: %q", path, line)
		}
		m.fields[k] = v
	}
	if err := sc.Err(); err != nil {
		return Manifest{}, err
	}
	m.Name = m.fields["name"]
	if m.Name == "" {
		m.Name = strings.TrimSuffix(filepath.Base(path), ".manifest")
	}
	return m, nil
}

func (m Manifest) Get(key string) string { return m.fields[key] }

// Image is the qcow2 this manifest describes.
func (m Manifest) Image() string { return strings.TrimSuffix(m.Path, ".manifest") + ".qcow2" }

// Hardware is the machine the image was installed and verified on. Fields
// the manifest does not record keep their defaults, except the NIC: an
// image with no nic line predates the choice and was installed with
// usb-net.
func (m Manifest) Hardware() config.Machine {
	h := config.DefaultMachine()
	if nic, ok := m.fields["nic"]; ok {
		h.NIC = nic
	} else {
		h.NIC = config.LegacyNIC
	}
	parts := strings.Fields(m.fields["accel"])
	if len(parts) > 0 {
		h.Accel = parts[0]
		for _, kv := range parts[1:] {
			k, v, _ := strings.Cut(kv, "=")
			switch k {
			case "machine":
				h.Type = v
			case "cpu":
				h.CPU = v
			case "ram":
				if n, err := strconv.Atoi(v); err == nil {
					h.MemoryMB = n
				}
			case "smp":
				if n, err := strconv.Atoi(v); err == nil {
					h.SMP = n
				}
			}
		}
	}
	return h
}

// LegacySSH reports whether the guest runs Apple's OpenSSH 6.2: an image
// built with --no-openssh, or before the openssh line existed (3bde057).
func (m Manifest) LegacySSH() bool {
	v, ok := m.fields["openssh"]
	return !ok || v == "none"
}

// SSHKeyFingerprint is the SHA256 fingerprint of the key the image
// authorized, or "".
func (m Manifest) SSHKeyFingerprint() string {
	if f := strings.Fields(m.fields["sshkey"]); len(f) > 0 {
		return f[0]
	}
	return ""
}

// List is every manifest in dir that has its image beside it, newest
// first.
func List(dir string) ([]Manifest, error) {
	paths, err := manifestFiles(dir)
	if err != nil {
		return nil, err
	}
	var out []Manifest
	for _, p := range paths {
		m, err := Load(p)
		if err != nil {
			return nil, err
		}
		if _, err := os.Stat(m.Image()); err == nil {
			out = append(out, m)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	return out, nil
}

// Any reports whether dir holds at least one manifest with its image
// beside it: whether List would find something, without reading any
// manifest. A missing dir holds nothing.
func Any(dir string) bool {
	paths, err := manifestFiles(dir)
	if err != nil {
		return false
	}
	for _, p := range paths {
		if _, err := os.Stat(Manifest{Path: p}.Image()); err == nil {
			return true
		}
	}
	return false
}

// manifestFiles is every *.manifest in dir, sorted; none when dir does
// not exist. The directory is read, not globbed, so that one holding a
// glob character -- "[" is malformed, "a[1]" matches "a1" -- is taken
// literally.
func manifestFiles(dir string) ([]string, error) {
	ents, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".manifest") {
			paths = append(paths, filepath.Join(dir, e.Name()))
		}
	}
	return paths, nil
}

// Find is the manifest for the image named name.
func Find(dir, name string) (Manifest, error) {
	all, err := List(dir)
	if err != nil {
		return Manifest{}, err
	}
	var names []string
	for _, m := range all {
		if m.Name == name {
			return m, nil
		}
		names = append(names, m.Name)
	}
	return Manifest{}, fmt.Errorf("no built image %q in %s (there: %s)", name, dir, strings.Join(names, ", "))
}
