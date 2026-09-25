package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/media"
	"github.com/Mavergreen/vm-guest/internal/privops"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// recordingMediaBuilder is a mediaBuilder that notes every call instead
// of building or digesting anything.
type recordingMediaBuilder struct {
	calls    []string
	esd      string
	opts     media.Options
	captured *media.Builder

	buildPath    string
	buildErr     error
	describeErr  error
	preflightErr error
	validateErr  error
	digestImg    string
	digest       media.Digest
	listing      string
}

func (r *recordingMediaBuilder) Build(_ context.Context, esd string, o media.Options) (string, error) {
	r.calls = append(r.calls, "Build")
	r.esd, r.opts = esd, o
	return r.buildPath, r.buildErr
}

func (r *recordingMediaBuilder) Validate(o media.Options) error {
	r.calls = append(r.calls, "Validate")
	r.opts = o
	return r.validateErr
}

func (r *recordingMediaBuilder) Preflight() error {
	r.calls = append(r.calls, "Preflight")
	return r.preflightErr
}

func (r *recordingMediaBuilder) Describe(w io.Writer, esd string, o media.Options) error {
	r.calls = append(r.calls, "Describe")
	r.esd, r.opts = esd, o
	if r.describeErr != nil {
		return r.describeErr
	}
	fmt.Fprintln(w, "installer media layout")
	return nil
}

func (r *recordingMediaBuilder) ContentDigest(_ context.Context, img string, listing io.Writer) (media.Digest, error) {
	r.calls = append(r.calls, "ContentDigest")
	r.digestImg = img
	if listing != nil {
		io.WriteString(listing, r.listing)
	}
	return r.digest, nil
}

// stubMediaBuilder makes cmdMedia's newMediaBuilder hand back rec,
// capturing the real *media.Builder cmdMedia built, and restores the
// real one when the test ends.
func stubMediaBuilder(t *testing.T, rec *recordingMediaBuilder) {
	t.Helper()
	orig := newMediaBuilder
	newMediaBuilder = func(b *media.Builder) mediaBuilder {
		rec.captured = b
		return rec
	}
	t.Cleanup(func() { newMediaBuilder = orig })
}

// unameRunner is a proc.Fake that answers uname -r, as privops.NewBackend
// asks it, and nothing else.
func unameRunner() *proc.Fake {
	return &proc.Fake{Handle: func(c proc.Cmd) error {
		if c.Name == "uname" && c.Stdout != nil {
			io.WriteString(c.Stdout, "6.1.0-test\n")
		}
		return nil
	}}
}

// mediaFixture is a VMAVS_HOME holding the shell tree's download of a
// fake InstallESD.dmg, which fetch adopts without a handshake, and an Env
// whose recovery endpoint is unreachable, so nothing can be downloaded.
// It returns the Env, its stdout and stderr, and the path the adopted ESD
// has in the cache.
func mediaFixture(t *testing.T) (*Env, *bytes.Buffer, *bytes.Buffer, string, config.Paths) {
	t.Helper()
	asset := []byte("not really Apple's installer")
	_, reg := fakeAppleCDN(t, asset)
	home := t.TempDir()
	shell := filepath.Join(home, "media", "InstallESD.dmg")
	if err := os.MkdirAll(filepath.Dir(shell), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(shell, asset, 0o644); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	e.Registry = reg
	e.Endpoints = &Endpoints{Recovery: "http://127.0.0.1:1"}
	e.Runner = unameRunner()
	e.PID = 777
	p := config.Paths{Home: home}
	return e, out, errb, p.CacheFile(sum(asset), "InstallESD.dmg"), p
}

func TestMediaBuildsWithTheFlagsItWasGiven(t *testing.T) {
	rec := &recordingMediaBuilder{buildPath: "/the/media.img"}
	stubMediaBuilder(t, rec)
	e, out, errb, esd, p := mediaFixture(t)
	code := Run(context.Background(), []string{"media", "--firstboot-pkg", "/p/P.pkg", "--extra-pkg", "/p/A.pkg",
		"--extra-pkg", "/p/B.pkg", "--extra-space-mib", "70", "--force"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if !slices.Equal(rec.calls, []string{"Validate", "Preflight", "Build"}) {
		t.Fatalf("calls=%v, want Validate, Preflight, then Build", rec.calls)
	}
	if rec.esd != esd {
		t.Fatalf("Build got esd %q, want the adopted %q", rec.esd, esd)
	}
	// --autoinstall was not given: the library, not the CLI, knows that a
	// package implies it (Injectables.Enabled).
	want := media.Options{Injectables: media.Injectables{FirstbootPkg: "/p/P.pkg", ExtraPkgs: []string{"/p/A.pkg", "/p/B.pkg"}},
		ExtraSpaceMiB: 70, Force: true}
	if !reflect.DeepEqual(rec.opts, want) {
		t.Fatalf("Build got %+v, want %+v", rec.opts, want)
	}
	if !rec.opts.Enabled() {
		t.Fatal("a package should enable the injectables")
	}
	if out.String() != "/the/media.img\n" {
		t.Fatalf("stdout=%q, want the built path alone", out.String())
	}
	b := rec.captured
	if b == nil || b.Paths != p || b.PID != 777 || b.Runner != e.Runner || b.Log == nil {
		t.Fatalf("builder = %+v", b)
	}
}

func TestMediaAutoinstallAndKeepWork(t *testing.T) {
	rec := &recordingMediaBuilder{buildPath: "/the/media.img"}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "--autoinstall", "--keep-work"}, e); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	want := media.Options{Injectables: media.Injectables{Autoinstall: true}, KeepWork: true}
	if !reflect.DeepEqual(rec.opts, want) {
		t.Fatalf("Build got %+v, want %+v", rec.opts, want)
	}
}

// TestMediaInPlaceWithoutItsSidecar: Build's path with an error is media
// in place whose sidecar is missing -- the path is still printed, as the
// output it is, and the error still fails the command.
func TestMediaInPlaceWithoutItsSidecar(t *testing.T) {
	rec := &recordingMediaBuilder{buildPath: "/the/media.img", buildErr: errors.New("its sidecar is missing")}
	stubMediaBuilder(t, rec)
	e, out, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media"}, e); code != 1 {
		t.Fatalf("code=%d, want 1", code)
	}
	if out.String() != "/the/media.img\n" {
		t.Fatalf("stdout=%q, want the path", out.String())
	}
	if !strings.Contains(errb.String(), "vmavs media: error: its sidecar is missing") {
		t.Fatalf("stderr=%s", errb.String())
	}
}

func TestMediaAFailedBuildPrintsNothing(t *testing.T) {
	rec := &recordingMediaBuilder{buildErr: errors.New("no")}
	stubMediaBuilder(t, rec)
	e, out, _, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media"}, e); code != 1 || out.String() != "" {
		t.Fatalf("code=%d stdout=%q", code, out.String())
	}
}

func TestMediaFlagsAndTargetsInAnyOrder(t *testing.T) {
	for _, args := range [][]string{
		{"media", "--force", "digest", "--list", "img"},
		{"media", "digest", "img", "--force"},
		{"media", "digest", "--extra-pkg", "x", "img"},
		{"media", "--list"},
		{"media", "digest"},
		{"media", "digest", "a", "b"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			rec := &recordingMediaBuilder{}
			stubMediaBuilder(t, rec)
			e, _, errb, _, _ := mediaFixture(t)
			if code := Run(context.Background(), args, e); code != 2 {
				t.Fatalf("code=%d stderr=%s, want a usage error", code, errb.String())
			}
			if len(rec.calls) != 0 {
				t.Fatalf("calls=%v", rec.calls)
			}
		})
	}
	// The same flags, in either place, are accepted.
	for _, args := range [][]string{
		{"media", "digest", "--list", "img"},
		{"media", "digest", "img", "--list"},
		{"media", "--list", "digest", "img"},
	} {
		rec := &recordingMediaBuilder{}
		stubMediaBuilder(t, rec)
		e, _, errb, _, _ := mediaFixture(t)
		if code := Run(context.Background(), args, e); code != 0 || rec.digestImg != "img" {
			t.Fatalf("%v: code=%d img=%q stderr=%s", args, code, rec.digestImg, errb.String())
		}
	}
}

func TestMediaDescribeFetchesNothing(t *testing.T) {
	asset := []byte("not really Apple's installer")
	srv, reg := fakeAppleCDN(t, asset)
	requests := trackRequests(srv)
	rec := &recordingMediaBuilder{}
	stubMediaBuilder(t, rec)
	home := t.TempDir()
	e, out, errb := fetchEnv(map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()})
	e.Registry, e.Endpoints, e.Runner = reg, &Endpoints{Recovery: srv.URL}, unameRunner()
	if code := Run(context.Background(), []string{"media", "--describe", "--autoinstall"}, e); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if len(*requests) != 0 {
		t.Fatalf("describe made requests: %v", *requests)
	}
	if !slices.Equal(rec.calls, []string{"Describe"}) {
		t.Fatalf("calls=%v, want Describe alone", rec.calls)
	}
	if want := (config.Paths{Home: home}).CacheFile(sum(asset), "InstallESD.dmg"); rec.esd != want {
		t.Fatalf("Describe got %q, want %q", rec.esd, want)
	}
	if !rec.opts.Autoinstall {
		t.Fatalf("Describe got %+v", rec.opts)
	}
	if out.String() != "installer media layout\n" {
		t.Fatalf("stdout=%q", out.String())
	}
	if _, err := os.Stat(filepath.Join(home, "cache")); err == nil {
		t.Fatal("describe made the cache")
	}
}

// TestMediaDescribeRefusalIsAUsageError: Describe refuses only options it
// was given, so its refusal is the invoker's mistake.
func TestMediaDescribeRefusalIsAUsageError(t *testing.T) {
	rec := &recordingMediaBuilder{describeErr: errors.New("--extra-space-mib wants a whole number of MiB")}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "--describe"}, e); code != 2 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
}

func TestMediaDigest(t *testing.T) {
	d := media.Digest{SHA256: strings.Repeat("ab", 32), Files: 3, Bytes: 42}
	rec := &recordingMediaBuilder{digest: d, listing: "x  ./a\ny  ./b\n"}
	stubMediaBuilder(t, rec)
	e, out, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "digest", "img"}, e); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if out.String() != d.String()+"\n" || rec.digestImg != "img" {
		t.Fatalf("stdout=%q img=%q", out.String(), rec.digestImg)
	}

	out.Reset()
	if code := Run(context.Background(), []string{"media", "digest", "--list", "img"}, e); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if out.String() != "x  ./a\ny  ./b\n"+d.String()+"\n" {
		t.Fatalf("stdout=%q, want the listing then the digest", out.String())
	}
}

func TestMediaDigestOfAMissingImageExitsOne(t *testing.T) {
	e, out, errb, _, _ := mediaFixture(t)
	missing := filepath.Join(t.TempDir(), "nothing.img")
	if code := Run(context.Background(), []string{"media", "digest", missing}, e); code != 1 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if out.String() != "" || !strings.Contains(errb.String(), missing) {
		t.Fatalf("stdout=%q stderr=%s", out.String(), errb.String())
	}
}

func TestMediaRefusesBadArguments(t *testing.T) {
	for _, args := range [][]string{
		{"--extra-space-mib", "-1"},
		{"--extra-space-mib", "x"},
		{"--extra-space-mib", "+5"},
		{"--extra-space-mib", "0x10"},
		{"--extra-space-mib", ""},
		{"--privops-timeout", "0"},
		{"--privops-timeout", "-5m"},
		{"--privops-timeout", "soon"},
		{"foo"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			rec := &recordingMediaBuilder{}
			stubMediaBuilder(t, rec)
			e, out, errb, _, _ := mediaFixture(t)
			if code := Run(context.Background(), append([]string{"media"}, args...), e); code != 2 {
				t.Fatalf("code=%d stderr=%s, want 2", code, errb.String())
			}
			if len(rec.calls) != 0 || out.String() != "" {
				t.Fatalf("calls=%v stdout=%q", rec.calls, out.String())
			}
		})
	}
}

// TestMediaExtraSpaceIsDecimal: "070" is seventy, as the shell reads it,
// not the octal flag.Int would make of it.
func TestMediaExtraSpaceIsDecimal(t *testing.T) {
	rec := &recordingMediaBuilder{buildPath: "/m"}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "--extra-space-mib", "070"}, e); code != 0 || rec.opts.ExtraSpaceMiB != 70 {
		t.Fatalf("code=%d opts=%+v stderr=%s", code, rec.opts, errb.String())
	}
}

func TestMediaPrivopsTimeout(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want time.Duration
	}{
		{[]string{"media", "--privops-timeout", "30m"}, 30 * time.Minute},
		{[]string{"media"}, privops.DefaultTimeout},
	} {
		rec := &recordingMediaBuilder{buildPath: "/m"}
		stubMediaBuilder(t, rec)
		e, _, errb, _, _ := mediaFixture(t)
		if code := Run(context.Background(), tc.args, e); code != 0 {
			t.Fatalf("%v: code=%d stderr=%s", tc.args, code, errb.String())
		}
		be, ok := rec.captured.VM.(privops.Backend)
		if !ok {
			t.Fatalf("%v: VM is %T, want a privops.Backend", tc.args, rec.captured.VM)
		}
		if be.Timeout != tc.want || be.QEMU != "qemu-system-x86_64" || be.Runner != e.Runner {
			t.Fatalf("%v: backend = %+v", tc.args, be)
		}
		if runtime.GOOS == "linux" && be.KVer != "6.1.0-test" {
			t.Fatalf("KVer = %q, want uname's answer", be.KVer)
		}
	}
}

// TestMediaDigestTakesAPrivopsTimeout: the digest is a microVM pass too,
// and a slow host needs the same bound raised.
func TestMediaDigestTakesAPrivopsTimeout(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want time.Duration
	}{
		{[]string{"media", "digest", "--privops-timeout", "45m", "img"}, 45 * time.Minute},
		{[]string{"media", "--privops-timeout", "2h", "digest", "img"}, 2 * time.Hour},
		{[]string{"media", "digest", "img"}, privops.DefaultTimeout},
	} {
		rec := &recordingMediaBuilder{}
		stubMediaBuilder(t, rec)
		e, _, errb, _, _ := mediaFixture(t)
		if code := Run(context.Background(), tc.args, e); code != 0 {
			t.Fatalf("%v: code=%d stderr=%s", tc.args, code, errb.String())
		}
		be, ok := rec.captured.VM.(privops.Backend)
		if !ok || be.Timeout != tc.want || rec.digestImg != "img" {
			t.Fatalf("%v: VM %T timeout %v img %q; want %v", tc.args, rec.captured.VM, be.Timeout, rec.digestImg, tc.want)
		}
	}
	rec := &recordingMediaBuilder{}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "digest", "--privops-timeout", "0", "img"}, e); code != 2 || len(rec.calls) != 0 {
		t.Fatalf("a zero timeout: code=%d calls=%v stderr=%s", code, rec.calls, errb.String())
	}
}

func TestMediaHelpBeginsUsage(t *testing.T) {
	e, out, _ := fetchEnv(map[string]string{})
	if code := Run(context.Background(), []string{"media", "--help"}, e); code != 0 {
		t.Fatalf("code=%d", code)
	}
	for _, want := range []string{"usage: vmavs media", "vmavs media digest", "--extra-pkg", "--privops-timeout", "vmavs fetch esd"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("help lacks %q:\n%s", want, out.String())
		}
	}
}

// fixtureBackend makes cmdMedia's privops backend the real one pointed at
// root: its kernels in root/boot (empty unless the test puts one there),
// its modules in root/modules, and its KVM device at root/kvm. Nothing
// the test's host has -- a readable /boot/vmlinuz-linux, a writable
// /dev/kvm, root's permissions -- can change what it reports.
func fixtureBackend(t *testing.T, root string) {
	t.Helper()
	orig := newPrivopsBackend
	newPrivopsBackend = func(r proc.Runner, qemu string, log func(string, ...any)) (privops.Backend, error) {
		b, err := orig(r, qemu, log)
		b.BootDir, b.ModulesDir, b.KVMDevice = filepath.Join(root, "boot"), filepath.Join(root, "modules"), filepath.Join(root, "kvm")
		return b, err
	}
	t.Cleanup(func() { newPrivopsBackend = orig })
}

// TestMediaPreflightsBeforeItFetches: a host that cannot build media
// hears so, naming everything it lacks, before 5.2 GB is downloaded --
// the osrecovery server sees no request at all. This is the real
// builder and the real backend, on a Runner that knows no program, and
// on a fixture host with no kernel and no KVM device.
func TestMediaPreflightsBeforeItFetches(t *testing.T) {
	asset := []byte("not really Apple's installer")
	srv, reg := fakeAppleCDN(t, asset)
	requests := trackRequests(srv)
	home := t.TempDir()
	root := t.TempDir()
	fixtureBackend(t, root)
	e, out, errb := fetchEnv(map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()})
	e.Registry, e.Endpoints, e.Runner = reg, &Endpoints{Recovery: srv.URL}, unameRunner()
	if code := Run(context.Background(), []string{"media"}, e); code != 1 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if len(*requests) != 0 {
		t.Fatalf("fetched before the preflight: %v", *requests)
	}
	want := []string{"dmg2img (not on PATH)", "mkfs.hfsplus (not on PATH)"}
	if runtime.GOOS == "linux" {
		want = append(want, "qemu-system-x86_64 (not on PATH)", "busybox (not on PATH)",
			"a readable kernel image for 6.1.0-test (looked for: "+filepath.Join(root, "boot", "vmlinuz-6.1.0-test"),
			filepath.Join(root, "kvm")+" does not exist")
	} else {
		want = append(want, "the qemu-linux privops backend")
	}
	for _, w := range want {
		if !strings.Contains(errb.String(), w) {
			t.Errorf("stderr does not name %q:\n%s", w, errb.String())
		}
	}
	if out.String() != "" {
		t.Fatalf("stdout=%q", out.String())
	}
	if _, err := os.Stat(filepath.Join(home, "cache")); err == nil {
		t.Fatal("the preflight's failure left a cache behind: something was fetched")
	}
}

// TestMediaWithAnUnusableKVMDeviceFetchesNothing: everything else is
// there, and the KVM device alone is missing or not writable -- the
// microVM would fail at -enable-kvm, so the ESD is not fetched.
func TestMediaWithAnUnusableKVMDeviceFetchesNothing(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the privops backend asks about KVM on Linux only")
	}
	for _, tc := range []struct {
		name, want string
		make       func(t *testing.T, dev string)
	}{
		{"absent", " does not exist (is the kvm module loaded?", func(*testing.T, string) {}},
		{"not writable", " is not writable by this user (is this user in group kvm?", func(t *testing.T, dev string) {
			if os.Geteuid() == 0 {
				t.Skip("root writes a mode-0444 file")
			}
			if err := os.WriteFile(dev, nil, 0o444); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			asset := []byte("not really Apple's installer")
			srv, reg := fakeAppleCDN(t, asset)
			requests := trackRequests(srv)
			root := t.TempDir()
			fixtureBackend(t, root)
			tc.make(t, filepath.Join(root, "kvm"))
			if err := os.MkdirAll(filepath.Join(root, "boot"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "boot", "vmlinuz-6.1.0-test"), []byte("kernel"), 0o644); err != nil {
				t.Fatal(err)
			}
			r := unameRunner()
			// busybox names no file here, so its linkage is unknown, which
			// is not reported: only the KVM device is missing.
			r.Paths = map[string]string{"qemu-system-x86_64": "/q", "busybox": filepath.Join(root, "busybox"),
				"dmg2img": "/d", "mkfs.hfsplus": "/m"}
			e, out, errb := fetchEnv(map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()})
			e.Registry, e.Endpoints, e.Runner = reg, &Endpoints{Recovery: srv.URL}, r
			if code := Run(context.Background(), []string{"media"}, e); code != 1 {
				t.Fatalf("code=%d stderr=%s", code, errb.String())
			}
			if len(*requests) != 0 {
				t.Fatalf("fetched with no usable KVM device: %v", *requests)
			}
			if w := filepath.Join(root, "kvm") + tc.want; !strings.Contains(errb.String(), w) {
				t.Fatalf("stderr does not name %q:\n%s", w, errb.String())
			}
			if strings.Contains(errb.String(), "busybox") || strings.Contains(errb.String(), "kernel image") || out.String() != "" {
				t.Fatalf("stdout=%q stderr=%s, want the KVM device alone", out.String(), errb.String())
			}
		})
	}
}

// TestMediaValidatesBeforeItFetches: a package that is not there is
// refused before the ESD is fetched, by the real builder, in Build's own
// words.
func TestMediaValidatesBeforeItFetches(t *testing.T) {
	asset := []byte("not really Apple's installer")
	srv, reg := fakeAppleCDN(t, asset)
	requests := trackRequests(srv)
	fixtureBackend(t, t.TempDir())
	home := t.TempDir()
	e, out, errb := fetchEnv(map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()})
	e.Registry, e.Endpoints, e.Runner = reg, &Endpoints{Recovery: srv.URL}, unameRunner()
	pkg := filepath.Join(t.TempDir(), "nonexistent.pkg")
	if code := Run(context.Background(), []string{"media", "--firstboot-pkg", pkg}, e); code != 1 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if len(*requests) != 0 {
		t.Fatalf("fetched before validating: %v", *requests)
	}
	if want := "no first-boot package at " + pkg; !strings.Contains(errb.String(), want) || out.String() != "" {
		t.Fatalf("stdout=%q stderr=%s, want %q", out.String(), errb.String(), want)
	}
	if _, err := os.Stat(filepath.Join(home, "cache")); err == nil {
		t.Fatal("a cache was made: something was fetched")
	}
}

// TestMediaAFailedValidationStopsTheBuild: with the builder stubbed, a
// refused option is the command's error, and nothing follows it.
func TestMediaAFailedValidationStopsTheBuild(t *testing.T) {
	rec := &recordingMediaBuilder{validateErr: errors.New("no such --extra-pkg: /x.pkg")}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "--extra-pkg", "/x.pkg"}, e); code != 1 {
		t.Fatalf("code=%d", code)
	}
	if !slices.Equal(rec.calls, []string{"Validate"}) || !strings.Contains(errb.String(), "no such --extra-pkg: /x.pkg") {
		t.Fatalf("calls=%v stderr=%s", rec.calls, errb.String())
	}
}

// TestMediaAFailedPreflightStopsTheBuild: with the builder stubbed, a
// preflight refusal is the command's error, and neither Build nor a fetch
// follows.
func TestMediaAFailedPreflightStopsTheBuild(t *testing.T) {
	rec := &recordingMediaBuilder{preflightErr: errors.New("the media build needs dmg2img (not on PATH)")}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media"}, e); code != 1 {
		t.Fatalf("code=%d", code)
	}
	if !slices.Equal(rec.calls, []string{"Validate", "Preflight"}) || !strings.Contains(errb.String(), "dmg2img (not on PATH)") {
		t.Fatalf("calls=%v stderr=%s", rec.calls, errb.String())
	}
	if strings.Contains(errb.String(), "adopted") {
		t.Fatalf("the ESD was fetched after a failed preflight: %s", errb.String())
	}
}

// TestMediaEmptyPackagePathsAreRefusedAlike: --firstboot-pkg and
// --extra-pkg are one kind of flag, and an empty path is refused by
// both, in the same words.
func TestMediaEmptyPackagePathsAreRefusedAlike(t *testing.T) {
	for _, name := range []string{"--firstboot-pkg", "--extra-pkg"} {
		rec := &recordingMediaBuilder{}
		stubMediaBuilder(t, rec)
		e, _, errb, _, _ := mediaFixture(t)
		if code := Run(context.Background(), []string{"media", name, ""}, e); code != 2 {
			t.Fatalf("%s '': code=%d", name, code)
		}
		want := fmt.Sprintf("invalid value \"\" for flag -%s: wants a path", strings.TrimPrefix(name, "--"))
		if !strings.Contains(errb.String(), want) || len(rec.calls) != 0 {
			t.Fatalf("%s '': calls=%v stderr=%s, want %q", name, rec.calls, errb.String(), want)
		}
	}
	// The last --firstboot-pkg wins, as in the shell.
	rec := &recordingMediaBuilder{buildPath: "/m"}
	stubMediaBuilder(t, rec)
	e, _, errb, _, _ := mediaFixture(t)
	if code := Run(context.Background(), []string{"media", "--firstboot-pkg", "/a.pkg", "--firstboot-pkg", "/b.pkg"}, e); code != 0 || rec.opts.FirstbootPkg != "/b.pkg" {
		t.Fatalf("code=%d opts=%+v stderr=%s", code, rec.opts, errb.String())
	}
}
