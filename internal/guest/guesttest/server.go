// Package guesttest is an in-process SSH server that stands in for a
// guest in tests.
package guesttest

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
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
		// What Apple's sshd advertises that x/crypto implements, in its order.
		cfg.Ciphers = []string{"aes128-ctr", "aes192-ctr", "aes256-ctr", "aes128-gcm@openssh.com", "aes256-gcm@openssh.com"}
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
			if o.Legacy {
				c = &gcmTrap{Conn: c, serverCiphers: cfg.Ciphers}
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
			if p.Command == "hang" {
				// Stands in for a command that never returns: sends no
				// output and no exit-status, so the loop below just
				// keeps waiting on `in` -- which only closes once the
				// client tears the whole channel down (guest.Exec does
				// this itself when its ctx is cancelled). A client-side
				// half-close (stdin EOF, sent even for a nil Stdin)
				// must not end this early, which is why this blocks on
				// the request channel rather than on reading ch.
				continue
			}
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

// gcmTrap does what Apple's OpenSSH_6.2p2 (OSSLShim) does when the client
// picks the aes*-gcm@openssh.com it advertises: "fatal: matching cipher is
// not supported" pre-auth, i.e. the connection just closes. On the first
// Read it takes the client's version line and KEXINIT, works out the
// client->server cipher as RFC 4253 7.1 does (the client's first that the
// server offers), and either closes or replays the bytes to the server.
type gcmTrap struct {
	net.Conn
	serverCiphers []string
	r             io.Reader
}

func (c *gcmTrap) Read(b []byte) (int, error) {
	if c.r == nil {
		r, err := c.inspect()
		if err != nil {
			c.Conn.Close()
			return 0, err
		}
		c.r = r
	}
	return c.r.Read(b)
}

var errAppleGCM = errors.New("matching cipher is not supported (Apple sshd + GCM)")

func (c *gcmTrap) inspect() (io.Reader, error) {
	br := bufio.NewReader(c.Conn)
	var seen bytes.Buffer
	line, err := br.ReadString('\n')
	if err != nil {
		return nil, err
	}
	seen.WriteString(line)
	var hdr [5]byte
	if _, err := io.ReadFull(br, hdr[:]); err != nil {
		return nil, err
	}
	body := make([]byte, binary.BigEndian.Uint32(hdr[:4])-1)
	if _, err := io.ReadFull(br, body); err != nil {
		return nil, err
	}
	seen.Write(hdr[:])
	seen.Write(body)
	p := body[1+16:]    // msg type, cookie
	var lists [3]string // kex, host keys, ciphers client->server
	for i := range lists {
		n := binary.BigEndian.Uint32(p)
		lists[i], p = string(p[4:4+n]), p[4+n:]
	}
	offered := map[string]bool{}
	for _, s := range c.serverCiphers {
		offered[s] = true
	}
	for _, name := range strings.Split(lists[2], ",") {
		if offered[name] {
			if strings.Contains(name, "-gcm@") {
				return nil, errAppleGCM
			}
			break
		}
	}
	return io.MultiReader(&seen, br), nil
}
