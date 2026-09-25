// Package guest talks to a running guest over SSH, with Go's own client:
// no ssh binary and no known_hosts.
package guest

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/term"
)

type Target struct {
	Addr   string
	User   string
	Signer ssh.Signer
	// Legacy is a guest running Apple's OpenSSH 6.2 (manifest.LegacySSH).
	Legacy  bool
	Timeout time.Duration
}

// ClientConfig trusts any host key: every overlay has fresh host keys, so
// a pinned one would be wrong by construction. What authenticates is the
// user key the image authorized.
func (t Target) ClientConfig() *ssh.ClientConfig {
	signer := t.Signer
	cfg := &ssh.ClientConfig{
		User:            t.User,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         t.Timeout,
	}
	if t.Legacy {
		// OpenSSH 6.2 offers only ssh-rsa/ssh-dss host keys and SHA-1
		// key exchanges, and predates rsa-sha2 signatures (RFC 8332).
		// The shell equivalent is ssh_opts() in image/build-image.sh.
		sup, ins := ssh.SupportedAlgorithms(), ssh.InsecureAlgorithms()
		cfg.HostKeyAlgorithms = append(append([]string{}, sup.HostKeys...), ins.HostKeys...)
		cfg.KeyExchanges = append(append([]string{}, sup.KeyExchanges...), ins.KeyExchanges...)
		if as, ok := signer.(ssh.AlgorithmSigner); ok && signer.PublicKey().Type() == ssh.KeyAlgoRSA {
			if s, err := ssh.NewSignerWithAlgorithms(as, []string{ssh.KeyAlgoRSA}); err == nil {
				signer = s
			}
		}
	}
	cfg.Auth = []ssh.AuthMethod{ssh.PublicKeys(signer)}
	return cfg
}

// Dial connects and completes the SSH handshake. The handshake itself is
// bounded by t.Timeout (net.Conn's deadline, since ssh.NewClientConn takes
// no context); ctx bounds the dial and, if cancelled while the handshake
// is still running, closes the connection under it so the handshake fails
// promptly instead of waiting out the full timeout.
func Dial(ctx context.Context, t Target) (*ssh.Client, error) {
	d := net.Dialer{Timeout: t.Timeout}
	conn, err := d.DialContext(ctx, "tcp", t.Addr)
	if err != nil {
		return nil, err
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-done:
		}
	}()
	if t.Timeout > 0 {
		conn.SetDeadline(time.Now().Add(t.Timeout))
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, t.Addr, t.ClientConfig())
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("ssh %s@%s: %w", t.User, t.Addr, err)
	}
	conn.SetDeadline(time.Time{}) // handshake is over; the client manages its own I/O from here
	return ssh.NewClient(c, chans, reqs), nil
}

// Exec runs one command and returns its exit status. Cancelling ctx closes
// the session, so a guest that never answers (or never exits) does not
// hang vmavs; the caller then sees ctx.Err().
func Exec(ctx context.Context, c *ssh.Client, command string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	s, err := c.NewSession()
	if err != nil {
		return 0, err
	}
	defer s.Close()
	s.Stdin, s.Stdout, s.Stderr = stdin, stdout, stderr
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			s.Close()
		case <-done:
		}
	}()
	code, err := status(s.Run(command))
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	return code, err
}

// Shell is an interactive login shell on a terminal. Cancelling ctx closes
// the session the same way Exec does.
func Shell(ctx context.Context, c *ssh.Client, in *os.File, out, errOut io.Writer) (int, error) {
	s, err := c.NewSession()
	if err != nil {
		return 0, err
	}
	defer s.Close()
	s.Stdin, s.Stdout, s.Stderr = in, out, errOut
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			s.Close()
		case <-done:
		}
	}()
	fd := int(in.Fd())
	if term.IsTerminal(fd) {
		old, err := term.MakeRaw(fd)
		if err != nil {
			return 0, err
		}
		defer term.Restore(fd, old)
		w, h, err := term.GetSize(fd)
		if err != nil {
			w, h = 80, 24
		}
		termName := os.Getenv("TERM")
		if termName == "" {
			termName = "xterm"
		}
		if err := s.RequestPty(termName, h, w, ssh.TerminalModes{ssh.ECHO: 1}); err != nil {
			return 0, err
		}
	}
	if err := s.Shell(); err != nil {
		return 0, err
	}
	code, err := status(s.Wait())
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	return code, err
}

func status(err error) (int, error) {
	var xe *ssh.ExitError
	if errors.As(err, &xe) {
		return xe.ExitStatus(), nil
	}
	var missing *ssh.ExitMissingError
	if errors.As(err, &missing) {
		// The server closed the session without ever sending an
		// exit-status or exit-signal message -- RFC 4254 §6.10 allows
		// this, and it is what an interactive shell's session commonly
		// looks like when it ends by the connection simply dropping.
		// OpenSSH's own ssh(1) exits 255 in that case, so vmavs does too.
		return 255, nil
	}
	if err != nil {
		return 0, err
	}
	return 0, nil
}
