// Package guesttest is an in-process SSH server that stands in for a
// guest in tests.
package guesttest

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"fmt"
	"net"
	"testing"

	"golang.org/x/crypto/ssh"
)

type Options struct {
	AuthorizedKey ssh.PublicKey
	// Legacy makes the server offer what Apple's OpenSSH 6.2 offers: an
	// ssh-rsa host key, diffie-hellman-group14-sha1 key exchange, and only
	// SHA-1 ("ssh-rsa") signatures from an RSA user key.
	Legacy bool
	// ShellStatus is the exit status a "shell" session ends with, unless
	// ShellNoStatus is set.
	ShellStatus uint32
	// ShellNoStatus ends a "shell" session by closing the channel without
	// ever sending an exit-status message -- the shape an interactive
	// session takes when the connection simply drops (guest.status()'s
	// *ssh.ExitMissingError case).
	ShellNoStatus bool
}

// Start serves until the test ends. It returns host:port.
func Start(t testing.TB, o Options) string {
	t.Helper()
	hostKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	host, err := ssh.NewSignerFromKey(hostKey)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(_ ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			if bytes.Equal(k.Marshal(), o.AuthorizedKey.Marshal()) {
				return nil, nil
			}
			return nil, errors.New("key not authorized")
		},
	}
	if o.Legacy {
		host, err = ssh.NewSignerWithAlgorithms(host.(ssh.AlgorithmSigner), []string{ssh.KeyAlgoRSA})
		if err != nil {
			t.Fatal(err)
		}
		cfg.KeyExchanges = []string{"diffie-hellman-group14-sha1"}
		cfg.PublicKeyAuthAlgorithms = []string{ssh.KeyAlgoRSA}
	}
	cfg.AddHostKey(host)
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
			go serve(c, cfg, o)
		}
	}()
	return ln.Addr().String()
}

func serve(c net.Conn, cfg *ssh.ServerConfig, o Options) {
	defer c.Close()
	_, chans, reqs, err := ssh.NewServerConn(c, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			nc.Reject(ssh.UnknownChannelType, "session only")
			continue
		}
		ch, in, err := nc.Accept()
		if err != nil {
			continue
		}
		go handleSession(ch, in, o)
	}
}

// handleSession answers exactly the requests guest.Exec and guest.Shell
// send: "exec" (guest.Exec), and "pty-req" followed by "shell"
// (guest.Shell). Anything else is refused.
func handleSession(ch ssh.Channel, in <-chan *ssh.Request, o Options) {
	defer ch.Close()
	for req := range in {
		switch req.Type {
		case "exec":
			var p struct{ Command string }
			ssh.Unmarshal(req.Payload, &p)
			req.Reply(true, nil)
			fmt.Fprintf(ch, "ran: %s\n", p.Command)
			code := uint32(0)
			if p.Command == "fail" {
				code = 3
			}
			ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{code}))
			return
		case "pty-req":
			req.Reply(true, nil)
		case "shell":
			req.Reply(true, nil)
			fmt.Fprintf(ch, "shell\n")
			if !o.ShellNoStatus {
				ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{o.ShellStatus}))
			}
			return
		default:
			req.Reply(false, nil)
		}
	}
}
