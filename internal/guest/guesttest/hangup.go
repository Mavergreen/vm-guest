package guesttest

import (
	"io"
	"net"
	"testing"
	"time"
)

// Hangup serves until the test ends: each connection gets banner (none,
// if it is "") and whatever the client sends is read until it goes quiet,
// then the connection is closed. With no banner it stands in for a guest
// whose sshd is not up yet (QEMU's port forward accepts, then closes);
// with one, for an sshd that answered and then died in the handshake, as
// Apple's OpenSSH 6.2 does on a cipher it advertises but cannot run. It
// returns host:port.
func Hangup(t testing.TB, banner string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				if banner != "" {
					io.WriteString(c, banner)
				}
				// Drain first: closing with unread data would send a
				// reset, not the EOF this stands in for.
				buf := make([]byte, 4096)
				for {
					c.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
					if _, err := c.Read(buf); err != nil {
						return
					}
				}
			}()
		}
	}()
	return ln.Addr().String()
}
