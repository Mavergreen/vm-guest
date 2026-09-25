package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/guest"
	"github.com/Mavergreen/vm-guest/internal/manifest"
	"github.com/Mavergreen/vm-guest/internal/vm"
)

const sshHelp = `usage: vmavs ssh [--image NAME] [--port N] [--user U] [--key PATH] [-- command...]

Open a shell in the running guest, or run one command there and exit with
its status. The guest is the one "vmavs run" started (--image picks one if
several are running); the key is the one that image authorized, found by
the fingerprint in its manifest. Host keys are not checked: every run's
overlay has fresh ones.
`

func cmdSSH(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("ssh")
	name := fs.String("image", "", "which running image (when more than one is)")
	port := fs.Int("port", 0, "host port forwarded to the guest's 22 (default: the running guest's)")
	user := fs.String("user", config.DefaultSSHUser, "guest account")
	keyPath := fs.String("key", "", "private key (default: the one the image authorized)")
	if err := parse(fs, e, sshHelp, args); err != nil {
		return err
	}
	p, err := paths(e)
	if err != nil {
		return err
	}
	reap(e, "ssh", p)
	m, livePort, err := sshTarget(e, p, *name, *port)
	if err != nil {
		return err
	}
	if *port == 0 {
		*port = livePort
	}
	var signer ssh.Signer
	if *keyPath != "" {
		signer, err = guest.LoadSigner(*keyPath)
	} else {
		_, signer, err = guest.ChooseKey(guest.KeyCandidates(e.Getenv, p.Keys()), m.SSHKeyFingerprint())
	}
	if err != nil {
		return err
	}
	t := guest.Target{Addr: net.JoinHostPort("127.0.0.1", strconv.Itoa(*port)), User: *user,
		Signer: signer, Legacy: m.LegacySSH(), Timeout: 10 * time.Second}
	c, err := guest.Dial(ctx, t)
	if err != nil {
		return bootingHint(err, *port)
	}
	defer c.Close()
	var code int
	if fs.NArg() > 0 {
		code, err = guest.Exec(ctx, c, strings.Join(fs.Args(), " "), e.Stdin, e.Stdout, e.Stderr)
	} else {
		in, ok := e.Stdin.(*os.File)
		if !ok {
			return errors.New("an interactive shell needs a terminal; pass a command after --")
		}
		code, err = guest.Shell(ctx, c, in, e.Stdout, e.Stderr)
	}
	if err != nil {
		return err
	}
	if code != 0 {
		return &ExitError{Code: code}
	}
	return nil
}

// bootingHint explains a Dial failure that has the shape of a guest whose
// sshd has not come up yet: refused (nothing listening), an EOF partway
// through the handshake (the guest reset the connection), or a timeout
// (nothing answered within Target.Timeout).
func bootingHint(err error, port int) error {
	if err == nil {
		return nil
	}
	var netErr net.Error
	refused := errors.Is(err, syscall.ECONNREFUSED)
	timedOut := errors.As(err, &netErr) && netErr.Timeout()
	eof := errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF)
	if refused || timedOut || eof {
		return fmt.Errorf("the guest on port %d isn't answering SSH yet -- is it still booting? "+
			"(vmavs run prints its port): %w", port, err)
	}
	return err
}

// sshTarget is the image to talk to and the port its run forwards. With
// --port and no running guest, the image is --image or the latest built.
func sshTarget(e *Env, p config.Paths, name string, port int) (manifest.Manifest, int, error) {
	live, err := vm.Live(p)
	if err != nil {
		return manifest.Manifest{}, 0, err
	}
	var match []vm.State
	var running []string
	for _, s := range live {
		running = append(running, s.Image)
		if name == "" || s.Image == name {
			match = append(match, s)
		}
	}
	switch {
	case len(match) == 1:
		m, err := manifest.Find(p.Images(), match[0].Image)
		return m, match[0].Port, err
	case len(match) > 1:
		var choices []string
		for _, s := range match {
			choices = append(choices, fmt.Sprintf("%s (port %d)", s.Image, s.Port))
		}
		return manifest.Manifest{}, 0, usagef("several guests are running: %s; pick one with --image", strings.Join(choices, ", "))
	case port != 0:
		m, err := chooseImage(e, p, name)
		return m, port, err
	case name != "" && len(live) > 0:
		return manifest.Manifest{}, 0, usagef("no running guest named %q; running: %s", name, strings.Join(running, ", "))
	default:
		return manifest.Manifest{}, 0, errors.New("no guest is running; start one with `vmavs run`, or pass --port")
	}
}
