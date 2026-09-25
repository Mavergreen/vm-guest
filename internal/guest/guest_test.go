package guest

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/pem"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// writeKey writes a private key and its .pub beside it; returns the path.
func writeKey(t *testing.T, dir, name string, priv any) string {
	t.Helper()
	block, err := ssh.MarshalPrivateKey(priv, name)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	os.WriteFile(p, pem.EncodeToMemory(block), 0o600)
	s, _ := ssh.NewSignerFromKey(priv)
	os.WriteFile(p+".pub", ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	return p
}

func TestExecRunsTheCommandAndReturnsItsStatus(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	c, err := Dial(context.Background(), Target{Addr: addr, User: "mavsuser", Signer: s, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	// stdout and stderr are two goroutines copying concurrently
	// (golang.org/x/crypto/ssh's Session.Start); one bytes.Buffer for
	// both is a data race (found by `go test -race`, and by this test
	// itself flaking under plain `go test`; the guesttest server here
	// only ever writes stdout, so stderr is discarded rather than given
	// a second buffer nothing would land in).
	var out bytes.Buffer
	code, err := Exec(context.Background(), c, "sw_vers", nil, &out, io.Discard)
	if err != nil || code != 0 || out.String() != "ran: sw_vers\n" {
		t.Fatalf("code=%d err=%v out=%q", code, err, out.String())
	}
	code, err = Exec(context.Background(), c, "fail", nil, &out, io.Discard)
	if err != nil || code != 3 {
		t.Fatalf("fail: code=%d err=%v", code, err)
	}
}

func TestExecReturnsPromptlyWhenCtxIsCancelled(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	c, err := Dial(context.Background(), Target{Addr: addr, User: "mavsuser", Signer: s, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	if _, err := Exec(ctx, c, "hang", nil, io.Discard, io.Discard); err == nil {
		t.Fatal("want an error once ctx is cancelled")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("Exec took %v after ctx was cancelled, want it to return promptly", elapsed)
	}
}

func TestDialReturnsPromptlyAgainstASilentListener(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			defer c.Close()
			// Accepts and never speaks: the handshake never completes,
			// so only Dial's own deadline can end it.
			io.Copy(io.Discard, c)
		}
	}()
	start := time.Now()
	_, err = Dial(context.Background(), Target{Addr: ln.Addr().String(), User: "mavsuser",
		Signer: mustEd(t), Timeout: 200 * time.Millisecond})
	if err == nil {
		t.Fatal("want an error from a silent listener")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("Dial took %v, want it to return within its Timeout", elapsed)
	}
}

func TestLegacyReachesAnOpenSSH62ShapedServerWithAnRSAKey(t *testing.T) {
	// REASONED stand-in for Apple's OpenSSH 6.2; Task 9 measures the real one.
	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	s, _ := ssh.NewSignerFromKey(rk)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey(), Legacy: true})
	c, err := Dial(context.Background(), Target{Addr: addr, User: "mavsuser", Signer: s, Legacy: true, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
}

func TestLegacyConfigOffersWhatOpenSSH62Needs(t *testing.T) {
	cfg := Target{Legacy: true, Signer: mustEd(t)}.ClientConfig()
	if !slices.Contains(cfg.HostKeyAlgorithms, "ssh-rsa") || !slices.Contains(cfg.KeyExchanges, "diffie-hellman-group14-sha1") {
		t.Fatalf("host keys %v, kex %v", cfg.HostKeyAlgorithms, cfg.KeyExchanges)
	}
	modern := Target{Signer: mustEd(t)}.ClientConfig()
	if modern.HostKeyAlgorithms != nil || modern.KeyExchanges != nil {
		t.Fatal("a modern guest gets x/crypto's defaults, untouched")
	}
}

func TestChooseKeyPicksTheOneTheImageAuthorized(t *testing.T) {
	dir := t.TempDir()
	_, a, _ := ed25519.GenerateKey(rand.Reader)
	_, b, _ := ed25519.GenerateKey(rand.Reader)
	pa := writeKey(t, dir, "id_a", a)
	pb := writeKey(t, dir, "id_b", b)
	sb, _ := ssh.NewSignerFromKey(b)
	want := ssh.FingerprintSHA256(sb.PublicKey())
	path, _, err := ChooseKey([]string{pa, pb}, want)
	if err != nil || path != pb {
		t.Fatalf("path=%q err=%v", path, err)
	}
	_, _, err = ChooseKey([]string{pa}, want)
	if err == nil || !strings.Contains(err.Error(), want) || !strings.Contains(err.Error(), "VMAVS_SSH_KEY") {
		t.Fatalf("err = %v", err)
	}
}

func TestKeyCandidatesOrder(t *testing.T) {
	home := t.TempDir()
	keys := filepath.Join(t.TempDir(), "keys")
	os.MkdirAll(filepath.Join(home, ".ssh"), 0o700)
	os.MkdirAll(keys, 0o700)
	_, k, _ := ed25519.GenerateKey(rand.Reader)
	user := writeKey(t, filepath.Join(home, ".ssh"), "id_ed25519", k)
	built := writeKey(t, keys, "mqg_rsa", k)
	getenv := func(n string) string { return map[string]string{"HOME": home, "VMAVS_SSH_KEY": "/explicit"}[n] }
	got := KeyCandidates(getenv, keys)
	if !slices.Equal(got, []string{"/explicit", user, built}) {
		t.Fatalf("got %v", got)
	}
}

func mustEd(t *testing.T) ssh.Signer {
	_, k, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(k)
	return s
}

// nonTerminal is a stand-in for os.Stdin that term.IsTerminal reports
// false for, so Shell never requests a pty or raw mode in these tests.
func nonTerminal(t *testing.T) *os.File {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	t.Cleanup(func() { r.Close() })
	return r
}

func dialGuest(t *testing.T, addr string, s ssh.Signer) *ssh.Client {
	t.Helper()
	c, err := Dial(context.Background(), Target{Addr: addr, User: "mavsuser", Signer: s, Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestShellRunsAnInteractiveSessionAndReturnsItsStatus(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	c := dialGuest(t, addr, s)
	var out, errOut bytes.Buffer
	code, err := Shell(context.Background(), c, nonTerminal(t), &out, &errOut)
	if err != nil || code != 0 || out.String() != "shell\n" {
		t.Fatalf("code=%d err=%v out=%q", code, err, out.String())
	}
}

func TestShellPropagatesAChosenExitStatus(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey(), ShellStatus: 7})
	c := dialGuest(t, addr, s)
	var out bytes.Buffer
	code, err := Shell(context.Background(), c, nonTerminal(t), &out, io.Discard)
	if err != nil || code != 7 {
		t.Fatalf("code=%d err=%v", code, err)
	}
}

func TestShellWithNoExitStatusIs255(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey(), ShellNoStatus: true})
	c := dialGuest(t, addr, s)
	var out bytes.Buffer
	code, err := Shell(context.Background(), c, nonTerminal(t), &out, io.Discard)
	if err != nil || code != 255 {
		t.Fatalf("code=%d err=%v", code, err)
	}
}

func TestStatusTreatsAMissingExitStatusAs255(t *testing.T) {
	code, err := status(&ssh.ExitMissingError{})
	if err != nil || code != 255 {
		t.Fatalf("code=%d err=%v", code, err)
	}
}
