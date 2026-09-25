package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// guestHome is a VMAVS_HOME with one image whose manifest names the key in
// keys/, a live run of it (this process's pid) forwarding to a test server,
// and the server's port.
func guestHome(t *testing.T) (home string) {
	t.Helper()
	home = t.TempDir()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "build")
	os.MkdirAll(filepath.Join(home, "keys"), 0o700)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519"), pem.EncodeToMemory(block), 0o600)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519.pub"), ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	os.MkdirAll(filepath.Join(home, "images"), 0o755)
	os.WriteFile(filepath.Join(home, "images", "img.qcow2"), nil, 0o644)
	os.WriteFile(filepath.Join(home, "images", "img.manifest"), []byte(fmt.Sprintf(
		"name\timg\nopenssh\t10.5p1-mavericks.2\nsshkey\t%s build\n", ssh.FingerprintSHA256(s.PublicKey()))), 0o644)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	port := addr[strings.LastIndex(addr, ":")+1:]
	dir := filepath.Join(home, "run", fmt.Sprintf("img-%d", os.Getpid()))
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "state"), []byte(fmt.Sprintf("image\timg\nport\t%s\npid\t%d\n", port, os.Getpid())), 0o644)
	return home
}

func sshVmavs(t *testing.T, home string, args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	e := &Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Getenv: func(k string) string { return map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}[k] }}
	code := Run(context.Background(), append([]string{"ssh"}, args...), e)
	return code, out.String(), errb.String()
}

func TestSSHFindsTheRunningGuestAndItsKey(t *testing.T) {
	home := guestHome(t)
	code, out, errs := sshVmavs(t, home, "--", "sw_vers", "-productVersion")
	if code != 0 || out != "ran: sw_vers -productVersion\n" {
		t.Fatalf("code=%d out=%q err=%q", code, out, errs)
	}
}

func TestSSHPassesTheRemoteExitStatusThrough(t *testing.T) {
	home := guestHome(t)
	if code, _, _ := sshVmavs(t, home, "--", "fail"); code != 3 {
		t.Fatalf("code=%d, want the remote status 3", code)
	}
}

func TestSSHWithNoRunningGuestSaysHowToStartOne(t *testing.T) {
	home := t.TempDir()
	code, _, errs := sshVmavs(t, home, "--", "true")
	if code != 1 || !strings.Contains(errs, "vmavs run") {
		t.Fatalf("code=%d err=%q", code, errs)
	}
}
