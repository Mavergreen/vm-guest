//go:build linux

package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// TestSSHAsksForTheTERMItsEnvironmentNames: the interactive shell's pty
// is requested with the TERM from Env.Getenv -- the environment cli was
// given -- not whatever the test process (or anything else) happens to
// have in os.Getenv.
func TestSSHAsksForTheTERMItsEnvironmentNames(t *testing.T) {
	t.Setenv("TERM", "dumb")
	home := shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "build")
	os.MkdirAll(filepath.Join(home, "keys"), 0o700)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519"), pem.EncodeToMemory(block), 0o600)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519.pub"), ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	writeKeyedImage(t, home, "img", s)
	terms := make(chan string, 1)
	startLiveRun(t, home, "img", s, guesttest.Options{OnPty: func(term string) { terms <- term }})

	var out, errb bytes.Buffer
	env := map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir(), "TERM": "vt220"}
	e := &Env{Stdin: guesttest.Pty(t), Stdout: &out, Stderr: &errb, Getenv: func(k string) string { return env[k] }}
	if code := Run(context.Background(), []string{"ssh"}, e); code != 0 {
		t.Fatalf("code=%d err=%q", code, errb.String())
	}
	select {
	case term := <-terms:
		if term != "vt220" {
			t.Fatalf("pty requested with TERM=%q, want vt220 from Env.Getenv", term)
		}
	default:
		t.Fatal("no pty was requested")
	}
}
