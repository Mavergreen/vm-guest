//go:build linux

package guest

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"io"
	"testing"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// TestShellOnATerminalAsksForTheGivenTERMElseXterm: on a real terminal
// Shell requests a pty, with the TERM its caller passed (never one it
// read from the environment itself), and xterm when that is empty.
func TestShellOnATerminalAsksForTheGivenTERMElseXterm(t *testing.T) {
	t.Setenv("TERM", "dumb")
	for _, tc := range []struct{ given, want string }{{"vt220", "vt220"}, {"", "xterm"}} {
		_, priv, _ := ed25519.GenerateKey(rand.Reader)
		s, _ := ssh.NewSignerFromKey(priv)
		terms := make(chan string, 1)
		addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey(), OnPty: func(term string) { terms <- term }})
		c := dialGuest(t, addr, s)
		if _, err := Shell(context.Background(), c, tc.given, guesttest.Pty(t), io.Discard, io.Discard); err != nil {
			t.Fatal(err)
		}
		select {
		case got := <-terms:
			if got != tc.want {
				t.Errorf("Shell(%q) asked for TERM=%q, want %q", tc.given, got, tc.want)
			}
		default:
			t.Errorf("Shell(%q) on a terminal requested no pty", tc.given)
		}
	}
}
