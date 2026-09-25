package guest

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

// KeyCandidates lists private keys in the order the shell tree searched
// for the key to authorize (lib/sshkey.sh): VMAVS_SSH_KEY, then
// ~/.ssh/id_*, then VMAVS_HOME/keys/*. Only keys with a .pub beside them
// count, except VMAVS_SSH_KEY, which is taken as given.
func KeyCandidates(getenv func(string) string, keysDir string) []string {
	var out []string
	if k := getenv("VMAVS_SSH_KEY"); k != "" {
		out = append(out, k)
	}
	for _, d := range []struct{ dir, prefix string }{
		{filepath.Join(getenv("HOME"), ".ssh"), "id_"},
		{keysDir, ""},
	} {
		for _, pub := range pubKeys(d.dir, d.prefix) {
			priv := strings.TrimSuffix(pub, ".pub")
			if _, err := os.Stat(priv); err == nil {
				out = append(out, priv)
			}
		}
	}
	return out
}

// pubKeys is the shell's "$dir"/<prefix>*.pub, sorted. The directory is
// read, not globbed, so that one holding a glob character -- "[" is
// malformed, "a[1]" matches "a1" -- is taken literally.
func pubKeys(dir, prefix string) []string {
	ents, _ := os.ReadDir(dir)
	var out []string
	for _, e := range ents {
		if n := e.Name(); strings.HasPrefix(n, prefix) && strings.HasSuffix(n, ".pub") {
			out = append(out, filepath.Join(dir, n))
		}
	}
	return out
}

func LoadSigner(path string) (ssh.Signer, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s, err := ssh.ParsePrivateKey(b)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return s, nil
}

// ChooseKey is the candidate whose public key has the fingerprint the
// image's manifest recorded. With no fingerprint, it is the first
// candidate that loads.
func ChooseKey(candidates []string, fingerprint string) (string, ssh.Signer, error) {
	var tried []string
	for _, p := range candidates {
		s, err := LoadSigner(p)
		if err != nil {
			tried = append(tried, fmt.Sprintf("%s (%v)", p, err))
			continue
		}
		if fingerprint == "" || ssh.FingerprintSHA256(s.PublicKey()) == fingerprint {
			return p, s, nil
		}
		tried = append(tried, p)
	}
	return "", nil, fmt.Errorf("no private key matches %s, the key this image authorized; tried: %s. "+
		"Set VMAVS_SSH_KEY or pass --key", fingerprint, strings.Join(tried, ", "))
}
