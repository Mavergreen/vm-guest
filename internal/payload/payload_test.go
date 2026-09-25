package payload

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/proc"
	"golang.org/x/crypto/ssh"
)

// --- test helpers ----------------------------------------------------

func rsaPubKey(t *testing.T) []byte {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := ssh.NewPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return ssh.MarshalAuthorizedKey(pub)
}

func ed25519PubKey(t *testing.T) []byte {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return ssh.MarshalAuthorizedKey(sshPub)
}

// fakePkg writes a fake flat package -- "xar!" plus filler, never Apple's
// bytes -- at dir/name, and returns its path.
func fakePkg(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("xar!not a real package, just filler for the tests"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// extractPostinstall reads the one file a flatPackage's Scripts member
// carries.
func extractPostinstall(t *testing.T, pkg []byte) []byte {
	t.Helper()
	_, members, err := readXar(pkg)
	if err != nil {
		t.Fatal(err)
	}
	scripts, ok := members["Scripts"]
	if !ok {
		t.Fatal("package has no Scripts member")
	}
	raw := gunzip(t, scripts)
	entries, err := readODC(raw)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name == "./postinstall" {
			return e.Data
		}
	}
	t.Fatal("Scripts has no ./postinstall entry")
	return nil
}

// shellPostinstall runs build-firstboot-pkg.sh with the given arguments
// and returns the postinstall it assembled, for byte-for-byte comparison
// against Postinstall's own output. It skips when python3, sha256sum or
// bash is unavailable; CI has all three.
func shellPostinstall(t *testing.T, args ...string) []byte {
	t.Helper()
	for _, cmd := range []string{"python3", "sha256sum", "bash"} {
		if _, err := exec.LookPath(cmd); err != nil {
			t.Skipf("%s not available", cmd)
		}
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "sh.pkg")
	script := filepath.Join(repoRoot(), "image", "payload", "build-firstboot-pkg.sh")
	cmdArgs := append([]string{script, "--out", out}, args...)
	cmd := exec.Command("bash", cmdArgs...)
	cmd.Env = append(os.Environ(), "MQG_IMAGE_DIR="+dir)
	if combined, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build-firstboot-pkg.sh: %v: %s", err, combined)
	}
	pkg, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	return extractPostinstall(t, pkg)
}

// --- Task 10's ten tests ----------------------------------------------

func TestBashQuoteMatchesBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	corpus := []string{
		"mavsuser", "Mavericks User", "/bin/bash", "a.pkg b.pkg ", "it's",
		"$HOME", "~root", "a=~b", "#x", "x#", "100%", "a,b", "semi;colon",
		`""`, `back\slash`,
	}
	for _, s := range corpus {
		got, err := bashQuote(s)
		if err != nil {
			t.Errorf("bashQuote(%q): %v", s, err)
			continue
		}
		out, err := exec.Command("bash", "-c", `printf %q "$1"`, "_", s).Output()
		if err != nil {
			t.Fatalf("bash printf %%q: %v", err)
		}
		if got != string(out) {
			t.Errorf("bashQuote(%q) = %q, bash printf %%q gives %q", s, got, out)
		}
	}
	for _, c := range []byte{0x00, 0x01, 0x09, 0x0a, 0x7f, 0x80, 0xff} {
		if _, err := bashQuote(string([]byte{c})); err == nil {
			t.Errorf("bashQuote(0x%02x): want an error, got none", c)
		}
	}
}

func TestConfDefaultsAreTheShellTreesByteForByte(t *testing.T) {
	dir := t.TempDir()
	key := rsaPubKey(t)
	keyPath := filepath.Join(dir, "rsa.pub")
	if err := os.WriteFile(keyPath, key, 0o644); err != nil {
		t.Fatal(err)
	}

	c := DefaultConfig()
	conf, err := Conf(c)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Postinstall(conf, key)
	if err != nil {
		t.Fatal(err)
	}

	want := shellPostinstall(t, "--ssh-key", keyPath)
	if !bytes.Equal(got, want) {
		t.Fatalf("postinstall differs from the shell tree's:\n--- go ---\n%s\n--- shell ---\n%s", got, want)
	}
}

func TestConfWithOpenSSHAndUpdatesMatchesTheShell(t *testing.T) {
	dir := t.TempDir()
	key := ed25519PubKey(t)
	keyPath := filepath.Join(dir, "ed25519.pub")
	if err := os.WriteFile(keyPath, key, 0o644); err != nil {
		t.Fatal(err)
	}

	base := fakePkg(t, dir, "openssh-6.9p1-mavericks.2-base.pkg")
	replace := fakePkg(t, dir, "openssh-6.9p1-mavericks.2-replace.pkg")
	upd := fakePkg(t, dir, "mqg-update-01-SecUpd2016-004Mavericks.pkg")

	c := DefaultConfig()
	c.OpenSSHPkgs = []string{base, replace}
	c.OpenSSHTag = "10.5p1-mavericks.2"
	c.UpdatePkgs = []string{upd}
	c.Updates = "security"

	conf, err := Conf(c)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Postinstall(conf, key)
	if err != nil {
		t.Fatal(err)
	}

	want := shellPostinstall(t, "--ssh-key", keyPath,
		"--openssh-pkg", base, "--openssh-pkg", replace, "--openssh-tag", c.OpenSSHTag,
		"--updates", "security", "--update-pkg", upd)
	if !bytes.Equal(got, want) {
		t.Fatalf("postinstall differs from the shell tree's:\n--- go ---\n%s\n--- shell ---\n%s", got, want)
	}
}

func TestANoneConfSaysNothingAboutUpdates(t *testing.T) {
	conf, err := Conf(DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(conf, []byte("MQG_FB_UPDATES")) {
		t.Fatalf("a --updates none conf mentions updates:\n%s", conf)
	}
}

func TestKeyRules(t *testing.T) {
	dir := t.TempDir()

	write := func(name string, data []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, data, 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}

	t.Run("ed25519 without OpenSSH is refused", func(t *testing.T) {
		c := DefaultConfig()
		c.SSHKey = write("e1.pub", ed25519PubKey(t))
		_, err := validateConfig(c, t.Logf)
		if err == nil || !strings.Contains(err.Error(), "6.5") {
			t.Fatalf("want an error mentioning 6.5, got %v", err)
		}
	})

	t.Run("ed25519 with OpenSSH is accepted", func(t *testing.T) {
		c := DefaultConfig()
		c.SSHKey = write("e2.pub", ed25519PubKey(t))
		c.OpenSSHPkgs = []string{fakePkg(t, dir, "b1.pkg"), fakePkg(t, dir, "b2.pkg")}
		c.OpenSSHTag = "10.5p1-mavericks.2"
		if _, err := validateConfig(c, t.Logf); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("a private key is refused", func(t *testing.T) {
		c := DefaultConfig()
		c.SSHKey = write("priv", []byte("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n"))
		_, err := validateConfig(c, t.Logf)
		if err == nil || !strings.Contains(err.Error(), "PRIVATE") {
			t.Fatalf("want an error mentioning PRIVATE, got %v", err)
		}
	})

	t.Run("not a key is refused", func(t *testing.T) {
		c := DefaultConfig()
		c.SSHKey = write("notkey", []byte("not a key\n"))
		if _, err := validateConfig(c, t.Logf); err == nil {
			t.Fatal("want an error")
		}
	})

	t.Run("a missing file is refused", func(t *testing.T) {
		c := DefaultConfig()
		c.SSHKey = filepath.Join(dir, "does-not-exist.pub")
		if _, err := validateConfig(c, t.Logf); err == nil {
			t.Fatal("want an error")
		}
	})
}

func TestPackageRules(t *testing.T) {
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "k.pub")
	if err := os.WriteFile(keyPath, rsaPubKey(t), 0o644); err != nil {
		t.Fatal(err)
	}
	base := func() Config {
		c := DefaultConfig()
		c.SSHKey = keyPath
		return c
	}

	t.Run("a whitespace basename is refused", func(t *testing.T) {
		c := base()
		c.UpdatePkgs = []string{fakePkg(t, dir, "has space.pkg")}
		c.Updates = "security"
		_, err := validateConfig(c, t.Logf)
		if err == nil || !strings.Contains(err.Error(), "whitespace") {
			t.Fatalf("want an error mentioning whitespace, got %v", err)
		}
	})

	t.Run("a non-xar file is refused", func(t *testing.T) {
		p := filepath.Join(dir, "notpkg.pkg")
		if err := os.WriteFile(p, []byte("not a package"), 0o644); err != nil {
			t.Fatal(err)
		}
		c := base()
		c.UpdatePkgs = []string{p}
		c.Updates = "security"
		_, err := validateConfig(c, t.Logf)
		if err == nil || !strings.Contains(err.Error(), "xar") {
			t.Fatalf("want an error mentioning xar magic, got %v", err)
		}
	})

	t.Run("OpenSSH packages without a tag are refused", func(t *testing.T) {
		c := base()
		c.OpenSSHPkgs = []string{fakePkg(t, dir, "b1.pkg"), fakePkg(t, dir, "b2.pkg")}
		_, err := validateConfig(c, t.Logf)
		if err == nil || !strings.Contains(err.Error(), "OpenSSHTag") {
			t.Fatalf("want an error mentioning OpenSSHTag, got %v", err)
		}
	})

	t.Run("updates none with packages is refused", func(t *testing.T) {
		c := base()
		c.UpdatePkgs = []string{fakePkg(t, dir, "u1.pkg")}
		c.Updates = "none"
		if _, err := validateConfig(c, t.Logf); err == nil {
			t.Fatal("want an error")
		}
	})

	t.Run("security without packages is refused", func(t *testing.T) {
		c := base()
		c.Updates = "security"
		if _, err := validateConfig(c, t.Logf); err == nil {
			t.Fatal("want an error")
		}
	})

	t.Run("sometimes is refused", func(t *testing.T) {
		c := base()
		c.Updates = "sometimes"
		if _, err := validateConfig(c, t.Logf); err == nil {
			t.Fatal("want an error")
		}
	})
}

func TestAMissingTrailingNewlineStillTerminatesTheHeredoc(t *testing.T) {
	conf, err := Conf(DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	key := []byte("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC comment-with-no-trailing-newline")
	post, err := Postinstall(conf, key)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(post, append(append([]byte{}, key...), '\n', 'M', 'Q', 'G', '_', 'E', 'O', 'F', '_', 'A', 'U', 'T', 'H', 'O', 'R', 'I', 'Z', 'E', 'D', '_', 'K', 'E', 'Y', 'S', '\n')) {
		t.Fatalf("MQG_EOF_AUTHORIZED_KEYS is not on its own line after the key:\n%s", post)
	}
}

func TestBuildWritesThePackageAndSidecarDeterministically(t *testing.T) {
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "id_rsa.pub")
	if err := os.WriteFile(keyPath, rsaPubKey(t), 0o644); err != nil {
		t.Fatal(err)
	}
	c := DefaultConfig()
	c.SSHKey = keyPath

	r := proc.Exec{}
	ctx := context.Background()

	out1 := filepath.Join(dir, "mqg-firstboot.pkg")
	sha1, err := Build(ctx, r, c, out1, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	pkg1, err := os.ReadFile(out1)
	if err != nil {
		t.Fatal(err)
	}
	if string(pkg1[:4]) != "xar!" {
		t.Fatalf("package does not start with xar!: %q", pkg1[:4])
	}

	out2 := filepath.Join(dir, "second", "mqg-firstboot.pkg")
	sha2, err := Build(ctx, r, c, out2, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if sha1 != sha2 {
		t.Fatalf("sha256 differs between two builds of the same inputs: %s vs %s", sha1, sha2)
	}

	sidecar, err := os.ReadFile(out1 + ".sha256")
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("%s  %s\n", sha1, filepath.Base(out1))
	if string(sidecar) != want {
		t.Fatalf("sidecar = %q, want %q", sidecar, want)
	}
}

func TestTheBuiltPostinstallInstallsThePayloadOnATargetOffline(t *testing.T) {
	dir := t.TempDir()
	key := rsaPubKey(t)
	keyPath := filepath.Join(dir, "id_rsa.pub")
	if err := os.WriteFile(keyPath, key, 0o644); err != nil {
		t.Fatal(err)
	}
	c := DefaultConfig()
	c.SSHKey = keyPath

	out := filepath.Join(dir, "mqg-firstboot.pkg")
	if _, err := Build(context.Background(), proc.Exec{}, c, out, t.Logf); err != nil {
		t.Fatal(err)
	}
	pkg, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	post := extractPostinstall(t, pkg)

	postPath := filepath.Join(dir, "postinstall")
	if err := os.WriteFile(postPath, post, 0o755); err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(dir, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}

	// $1 package path, $2 install destination, $3 THE TARGET VOLUME, $4
	// root of the target system -- the OS X Installer's own convention
	// (see image/payload/postinstall's header comment), and what
	// tests/payload.bats's "installs the payload on a target, offline"
	// exercises the shell version with.
	cmd := exec.Command("sh", postPath, "/pkg", "/dest", target, "/")
	if combined, err := cmd.CombinedOutput(); err != nil {
		// chown failing here (not root) is expected and the script
		// ignores it; a real failure is everything else.
		t.Fatalf("postinstall: %v: %s", err, combined)
	}

	confDir := filepath.Join(target, "private", "var", "db", ".mqg-firstboot")

	gotSh, err := os.ReadFile(filepath.Join(confDir, "firstboot.sh"))
	if err != nil {
		t.Fatal(err)
	}
	wantSh, err := fs.ReadFile(vmguest.Files, "image/payload/firstboot.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotSh, wantSh) {
		t.Error("firstboot.sh on the target differs from the embedded copy")
	}

	gotKey, err := os.ReadFile(filepath.Join(confDir, "authorized_keys"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotKey, key) {
		t.Error("authorized_keys on the target differs from the key that was asked for")
	}

	conf, err := os.ReadFile(filepath.Join(confDir, "firstboot.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(conf, []byte("MQG_FB_USER=mavsuser")) {
		t.Error("firstboot.conf does not carry MQG_FB_USER=mavsuser")
	}
	if bytes.Contains(conf, []byte("MQG_FB_PASSWORD")) {
		t.Error("firstboot.conf mentions a password that was never asked for")
	}

	gotPlist, err := os.ReadFile(filepath.Join(target, "Library", "LaunchDaemons", "com.mqg.firstboot.plist"))
	if err != nil {
		t.Fatal(err)
	}
	wantPlist, err := fs.ReadFile(vmguest.Files, "image/payload/com.mqg.firstboot.plist")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotPlist, wantPlist) {
		t.Error("the LaunchDaemon plist on the target differs from the embedded copy")
	}

	if _, err := os.Stat(filepath.Join(target, "private", "var", "db", ".AppleSetupDone")); err != nil {
		t.Errorf(".AppleSetupDone was not created: %v", err)
	}

	checkMode := func(path string, want os.FileMode) {
		t.Helper()
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != want {
			t.Errorf("%s: mode %o, want %o", path, info.Mode().Perm(), want)
		}
	}
	checkMode(filepath.Join(confDir, "firstboot.sh"), 0o755)
	checkMode(filepath.Join(confDir, "firstboot.conf"), 0o600)
	checkMode(filepath.Join(confDir, "authorized_keys"), 0o644)
	checkMode(filepath.Join(target, "Library", "LaunchDaemons", "com.mqg.firstboot.plist"), 0o644)
}

func TestBuildRefusesAnInvalidPostinstall(t *testing.T) {
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "id_rsa.pub")
	if err := os.WriteFile(keyPath, rsaPubKey(t), 0o644); err != nil {
		t.Fatal(err)
	}
	c := DefaultConfig()
	c.SSHKey = keyPath

	out := filepath.Join(dir, "mqg-firstboot.pkg")
	fake := &proc.Fake{Handle: func(cmd proc.Cmd) error {
		return &proc.ExitError{Cmd: cmd.String(), Code: 1}
	}}

	_, err := Build(context.Background(), fake, c, out, t.Logf)
	if err == nil || !strings.Contains(err.Error(), "not valid shell") {
		t.Fatalf("want an error mentioning \"not valid shell\", got %v", err)
	}
	if _, statErr := os.Stat(out); !os.IsNotExist(statErr) {
		t.Fatal("Build wrote a package despite the invalid postinstall")
	}
}
