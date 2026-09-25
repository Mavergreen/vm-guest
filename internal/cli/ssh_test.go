package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/guest/guesttest"
)

// lockRunState takes the same exclusive, non-blocking flock vm.Prepare
// takes on a run's state file, standing in for a live vmavs run: vm.Live
// (and so cli.sshTarget) now decide liveness by whether that lock is
// still held, not by whether a pid is running. It is released, and the
// file closed, when the test ends.
func lockRunState(t *testing.T, statePath string) {
	t.Helper()
	f, err := os.OpenFile(statePath, os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
}

// oneImageKeyed writes VMAVS_HOME/images/<name>.{qcow2,manifest} whose
// manifest authorizes s's key, and returns the manifest's sshkey line's
// fingerprint (already baked in).
func writeKeyedImage(t *testing.T, home, name string, s ssh.Signer) {
	t.Helper()
	os.MkdirAll(filepath.Join(home, "images"), 0o755)
	os.WriteFile(filepath.Join(home, "images", name+".qcow2"), nil, 0o644)
	os.WriteFile(filepath.Join(home, "images", name+".manifest"), []byte(fmt.Sprintf(
		"name\t%s\nopenssh\t10.5p1-mavericks.2\nsshkey\t%s build\n", name, ssh.FingerprintSHA256(s.PublicKey()))), 0o644)
}

// startLiveRun starts a guesttest server authorized for s, and records a
// held (locked) run/<name>-<n>/state pointing at it, the way vmavs run
// would have left one behind.
func startLiveRun(t *testing.T, home, name string, s ssh.Signer, o guesttest.Options) (port string) {
	t.Helper()
	o.AuthorizedKey = s.PublicKey()
	addr := guesttest.Start(t, o)
	port = addr[strings.LastIndex(addr, ":")+1:]
	runDir := filepath.Join(home, "run")
	os.MkdirAll(runDir, 0o755)
	dir, err := os.MkdirTemp(runDir, name+"-")
	if err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(dir, "state")
	os.WriteFile(statePath, []byte(fmt.Sprintf("image\t%s\nport\t%s\npid\t%d\nkeep\tfalse\n", name, port, os.Getpid())), 0o644)
	lockRunState(t, statePath)
	return port
}

// guestHome is a VMAVS_HOME with one image whose manifest names the key in
// keys/, a live run of it forwarding to a test server, and the server's
// port.
func guestHome(t *testing.T) (home string) {
	t.Helper()
	home = shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "build")
	os.MkdirAll(filepath.Join(home, "keys"), 0o700)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519"), pem.EncodeToMemory(block), 0o600)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519.pub"), ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	writeKeyedImage(t, home, "img", s)
	startLiveRun(t, home, "img", s, guesttest.Options{})
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
	home := shortTempDir(t)
	code, _, errs := sshVmavs(t, home, "--", "true")
	if code != 1 || !strings.Contains(errs, "vmavs run") {
		t.Fatalf("code=%d err=%q", code, errs)
	}
}

func TestSSHWithTwoLiveGuestsPicksTheNamedOneWithImage(t *testing.T) {
	home := shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "build")
	os.MkdirAll(filepath.Join(home, "keys"), 0o700)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519"), pem.EncodeToMemory(block), 0o600)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519.pub"), ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)

	writeKeyedImage(t, home, "one", s)
	writeKeyedImage(t, home, "two", s)
	startLiveRun(t, home, "one", s, guesttest.Options{})
	startLiveRun(t, home, "two", s, guesttest.Options{ShellStatus: 9})

	code, out, errs := sshVmavs(t, home, "--image", "two", "--", "sw_vers")
	if code != 0 || out != "ran: sw_vers\n" {
		t.Fatalf("code=%d out=%q err=%q", code, out, errs)
	}
}

func TestSSHWithNoLiveGuestButAPortFallsBackToTheChosenImage(t *testing.T) {
	home := shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "build")
	os.MkdirAll(filepath.Join(home, "keys"), 0o700)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519"), pem.EncodeToMemory(block), 0o600)
	os.WriteFile(filepath.Join(home, "keys", "mqg_ed25519.pub"), ssh.MarshalAuthorizedKey(s.PublicKey()), 0o644)
	writeKeyedImage(t, home, "img", s)

	addr := guesttest.Start(t, guesttest.Options{AuthorizedKey: s.PublicKey()})
	port := addr[strings.LastIndex(addr, ":")+1:]

	code, out, errs := sshVmavs(t, home, "--ssh-port", port, "--", "sw_vers")
	if code != 0 || out != "ran: sw_vers\n" {
		t.Fatalf("code=%d out=%q err=%q", code, out, errs)
	}
}

// TestSSHSpellsThePortFlagAsRunAndEmitDo: one machine-option name for the
// forwarded port across every subcommand (spec §2), and no alias.
func TestSSHSpellsThePortFlagAsRunAndEmitDo(t *testing.T) {
	home := shortTempDir(t)
	code, _, errs := sshVmavs(t, home, "--port", "2222", "--", "true")
	if code != 2 || !strings.Contains(errs, "-port") {
		t.Fatalf("code=%d err=%q, want --port to be a usage error", code, errs)
	}
	_, out, _ := sshVmavs(t, home, "--help")
	if !strings.Contains(out, "[--ssh-port N]") || strings.Contains(out, "--port") {
		t.Fatalf("help=%q, want --ssh-port and no --port", out)
	}
}

func TestSSHWithExplicitKeyIgnoresTheManifestFingerprint(t *testing.T) {
	home := shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	block, _ := ssh.MarshalPrivateKey(priv, "explicit")
	keyPath := filepath.Join(home, "explicit_ed25519")
	os.WriteFile(keyPath, pem.EncodeToMemory(block), 0o600)

	// The manifest names a fingerprint that matches nothing on disk:
	// --key must still work, bypassing guest.ChooseKey entirely.
	writeKeyedImage(t, home, "img", s)
	os.WriteFile(filepath.Join(home, "images", "img.manifest"), []byte(
		"name\timg\nopenssh\t10.5p1-mavericks.2\nsshkey\tSHA256:doesnotmatchanything\n"), 0o644)
	startLiveRun(t, home, "img", s, guesttest.Options{})

	code, out, errs := sshVmavs(t, home, "--key", keyPath, "--", "sw_vers")
	if code != 0 || out != "ran: sw_vers\n" {
		t.Fatalf("code=%d out=%q err=%q", code, out, errs)
	}
}

func TestSSHNamesTheRunningGuestsWhenImageDoesNotMatch(t *testing.T) {
	home := guestHome(t)
	_, _, errs := sshVmavs(t, home, "--image", "nope", "--", "true")
	if !strings.Contains(errs, "img") {
		t.Fatalf("err=%q, want it to name the running guest(s)", errs)
	}
}

func TestSSHReapsStaleRunDirectoriesFirst(t *testing.T) {
	home := guestHome(t)
	stale := filepath.Join(home, "run", "old-stale")
	os.MkdirAll(stale, 0o755)
	os.WriteFile(filepath.Join(stale, "state"), []byte("image\told\nport\t2222\npid\t1\nkeep\tfalse\n"), 0o644)

	code, _, errs := sshVmavs(t, home, "--", "sw_vers")
	if code != 0 {
		t.Fatalf("code=%d err=%q", code, errs)
	}
	if !strings.Contains(errs, "removed stale run directory") || !strings.Contains(errs, "old-stale") {
		t.Fatalf("err=%q, want it to log the removed stale run directory", errs)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale run directory not reaped")
	}
}

// TestSSHLeavesADirectoryVmavsDidNotCreate: ssh reaps too, and must not
// delete what is under run/ unless it is provably a dead vmavs run.
func TestSSHLeavesADirectoryVmavsDidNotCreate(t *testing.T) {
	home := guestHome(t)
	foreign := filepath.Join(home, "run", "someone-elses")
	os.MkdirAll(foreign, 0o755)
	os.WriteFile(filepath.Join(foreign, "precious"), []byte("data"), 0o644)
	old := time.Now().Add(-24 * time.Hour)
	os.Chtimes(foreign, old, old)

	code, _, errs := sshVmavs(t, home, "--", "sw_vers")
	if code != 0 {
		t.Fatalf("code=%d err=%q", code, errs)
	}
	if strings.Contains(errs, "someone-elses") {
		t.Fatalf("err=%q: it must not touch a directory vmavs did not create", errs)
	}
	if _, err := os.Stat(filepath.Join(foreign, "precious")); err != nil {
		t.Fatal("vmavs ssh deleted a directory it did not create")
	}
}

func TestSSHRefusesAnUnreachablePortWithTheBootingHint(t *testing.T) {
	home := shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	writeKeyedImage(t, home, "img", s)
	block, _ := ssh.MarshalPrivateKey(priv, "explicit")
	keyPath := filepath.Join(home, "explicit_ed25519")
	os.WriteFile(keyPath, pem.EncodeToMemory(block), 0o600)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close() // now refused: nothing listens there any more

	code, _, errs := sshVmavs(t, home, "--ssh-port", strconv.Itoa(port), "--key", keyPath, "--", "true")
	if code != 1 || !strings.Contains(errs, "isn't answering SSH yet") {
		t.Fatalf("code=%d err=%q", code, errs)
	}
}

// TestSSHTellsAHandshakeFailureFromAGuestStillBooting: an EOF before the
// guest's sshd says anything is a guest still booting; an EOF after its
// banner is an sshd that is up and failed the handshake, and "still
// booting?" would send the user to wait for nothing.
func TestSSHTellsAHandshakeFailureFromAGuestStillBooting(t *testing.T) {
	home := shortTempDir(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	writeKeyedImage(t, home, "img", s)
	block, _ := ssh.MarshalPrivateKey(priv, "explicit")
	keyPath := filepath.Join(home, "explicit_ed25519")
	os.WriteFile(keyPath, pem.EncodeToMemory(block), 0o600)
	for _, tc := range []struct{ banner, want, not string }{
		{"", "isn't answering SSH yet", "answered, then"},
		{"SSH-2.0-OpenSSH_6.2\r\n", "answered, then the SSH handshake failed", "still booting"},
	} {
		addr := guesttest.Hangup(t, tc.banner)
		port := addr[strings.LastIndex(addr, ":")+1:]
		code, _, errs := sshVmavs(t, home, "--ssh-port", port, "--key", keyPath, "--", "true")
		if code != 1 || !strings.Contains(errs, tc.want) || strings.Contains(errs, tc.not) {
			t.Errorf("banner %q: code=%d err=%q, want %q and not %q", tc.banner, code, errs, tc.want, tc.not)
		}
	}
}

func TestSSHOnCtrlCExitsQuietlyWithStatus130(t *testing.T) {
	home := guestHome(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled: standing in for Ctrl-C landing before, or during, the dial
	var out, errb bytes.Buffer
	e := &Env{Stdin: strings.NewReader(""), Stdout: &out, Stderr: &errb,
		Getenv: func(k string) string { return map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}[k] }}
	code := Run(ctx, []string{"ssh", "--", "true"}, e)
	if code != 130 {
		t.Fatalf("code=%d stderr=%q, want 130 (128+SIGINT, what a shell reports for a signal)", code, errb.String())
	}
	if errb.String() != "" {
		t.Fatalf("stderr=%q, want silence: vmavs did exactly what was asked, not a failure to explain", errb.String())
	}
}
