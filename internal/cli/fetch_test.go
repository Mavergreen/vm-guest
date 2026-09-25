package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

func sum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func xar(s string) []byte { return []byte("xar!" + s) }

// fakeAppleCDN is a minimal osrecovery+CDN stand-in: it does not
// replicate the handshake's key derivation (fetch's own tests already
// cover that in detail) -- it only needs to look enough like Apple's
// servers for fetch.Recovery.Handshake, reached through cmdFetch, to
// complete and hand back a URL matching reg's pinned one.
func fakeAppleCDN(t *testing.T, asset []byte) (*httptest.Server, *pins.Registry) {
	t.Helper()
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "GET" && r.URL.Path == "/":
			http.SetCookie(w, &http.Cookie{Name: "session", Value: "001~0A1B2C3D4E5F60718293A4B5C6D7E8F9"})
		case r.Method == "POST" && r.URL.Path == "/InstallationPayload/OSInstaller":
			fmt.Fprintf(w, "AU: %s/content/InstallESD.dmg\nAT: tok123\n", srv.URL)
		case r.URL.Path == "/content/InstallESD.dmg":
			if r.Header.Get("Cookie") != "AssetToken=tok123" {
				w.WriteHeader(403)
				return
			}
			w.Header().Set("Content-Length", fmt.Sprint(len(asset)))
			if r.Method == "GET" {
				w.Write(asset)
			}
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(srv.Close)
	reg, err := pins.Parse(strings.NewReader(fmt.Sprintf("%s\t%s/content/InstallESD.dmg\t%s\n", fetch.ESDSource, srv.URL, sum(asset))))
	if err != nil {
		t.Fatal(err)
	}
	return srv, reg
}

// fakeOpenSSHRelease serves <tag>/SHA256SUMS and the two named packages,
// for whatever tag the embedded pin (components/openssh/version) names.
func fakeOpenSSHRelease(t *testing.T, tag string, base, replace []byte) *httptest.Server {
	t.Helper()
	baseName := "OpenSSH-" + tag + ".pkg"
	replaceName := "OpenSSH-" + tag + "-System-Replace.pkg"
	pkgs := map[string][]byte{baseName: base, replaceName: replace}
	var sums strings.Builder
	fmt.Fprintf(&sums, "%s  %s\n", sum(base), baseName)
	fmt.Fprintf(&sums, "%s  %s\n", sum(replace), replaceName)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/"+tag+"/")
		if p == "SHA256SUMS" {
			w.Write([]byte(sums.String()))
			return
		}
		if b, ok := pkgs[p]; ok {
			w.Write(b)
			return
		}
		w.WriteHeader(404)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// fetchEnv is an Env set up like vmavs() but with VMAVS_HOME/HOME in temp
// dirs and room for the fetch-only fields.
func fetchEnv(env map[string]string) (*Env, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	e := &Env{
		Stdin:  strings.NewReader(""),
		Stdout: &out,
		Stderr: &errb,
		Getenv: func(k string) string { return env[k] },
	}
	return e, &out, &errb
}

func TestFetchOpenSSHPrintsBaseThenReplace(t *testing.T) {
	tag, err := fetch.OpenSSHTag()
	if err != nil {
		t.Fatal(err)
	}
	srv := fakeOpenSSHRelease(t, tag, xar("base"), xar("replace"))
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	e.Endpoints = &Endpoints{OpenSSHReleases: srv.URL}
	code := Run(context.Background(), []string{"fetch", "openssh"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 2 || !strings.HasSuffix(lines[0], "OpenSSH-"+tag+".pkg") || !strings.HasSuffix(lines[1], "System-Replace.pkg") {
		t.Fatalf("stdout=%q", out.String())
	}
}

func TestFetchUpdatesNoneFetchesAndPrintsNothing(t *testing.T) {
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	code := Run(context.Background(), []string{"fetch", "updates", "--updates", "none"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if out.String() != "" {
		t.Fatalf("stdout=%q, want nothing for --updates none", out.String())
	}
}

func TestFetchESDAdoptsFromVMAVS_HOMEWithoutAHandshake(t *testing.T) {
	asset := []byte("not really Apple's installer")
	_, reg := fakeAppleCDN(t, asset)
	home := t.TempDir()
	media := filepath.Join(home, "media", "InstallESD.dmg")
	if err := os.MkdirAll(filepath.Dir(media), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(media, asset, 0o644); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	e.Registry = reg
	// An unreachable recovery endpoint proves no handshake happened.
	e.Endpoints = &Endpoints{Recovery: "http://127.0.0.1:1"}
	code := Run(context.Background(), []string{"fetch", "esd"}, e)
	if code != 0 {
		t.Fatalf("code=%d stdout=%s stderr=%s", code, out.String(), errb.String())
	}
	if !strings.Contains(errb.String(), "adopted") {
		t.Fatalf("stderr=%q, want an adoption note", errb.String())
	}
	if b, err := os.ReadFile(media); err != nil || string(b) != string(asset) {
		t.Fatalf("the original was disturbed: %q, %v", b, err)
	}
	if strings.TrimSpace(out.String()) == "" {
		t.Fatal("stdout should carry the adopted path")
	}
}

func TestFetchUnknownTargetNamesTheThreeChoices(t *testing.T) {
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, _, errb := fetchEnv(env)
	code := Run(context.Background(), []string{"fetch", "bogus"}, e)
	if code != 2 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	for _, want := range []string{"esd", "openssh", "updates"} {
		if !strings.Contains(errb.String(), want) {
			t.Errorf("stderr=%q lacks %q", errb.String(), want)
		}
	}
}

func TestFetchProbeIsEsdOnly(t *testing.T) {
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, _, errb := fetchEnv(env)
	code := Run(context.Background(), []string{"fetch", "openssh", "--probe"}, e)
	if code != 2 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
}

func TestFetchESDProbePrintsURLAndSizeAndDownloadsNothing(t *testing.T) {
	asset := []byte("0123456789")
	srv, reg := fakeAppleCDN(t, asset)
	home := t.TempDir()
	env := map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	e.Registry = reg
	e.Endpoints = &Endpoints{Recovery: srv.URL}
	code := Run(context.Background(), []string{"fetch", "esd", "--probe"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	fields := strings.Fields(out.String())
	if len(fields) != 2 || !strings.HasSuffix(fields[0], "/InstallESD.dmg") || fields[1] != fmt.Sprint(len(asset)) {
		t.Fatalf("stdout=%q", out.String())
	}
	if _, err := os.Stat(filepath.Join(home, "cache")); !os.IsNotExist(err) {
		t.Fatal("--probe must create no cache file")
	}
}

// TestFetchArgOrderingsParseCorrectly is a table-driven test over the
// orderings the fix-round-1 review asked for: targets and flags mixed in
// either order, --updates in its "X", "=X" and single-dash forms, and the
// standard "--" terminator. It calls parseFetchArgs/fetchTargets
// directly (rather than a full Run(), which would need a working network
// fake for every combination) because what is under test here is
// argument parsing, not fetching.
func TestFetchArgOrderingsParseCorrectly(t *testing.T) {
	cases := []struct {
		name        string
		args        []string
		wantTargets []string // nil means fetchOrder (all three, no target named)
		wantUpdates string
		wantProbe   bool
	}{
		{"target, flag+value, target", []string{"esd", "--updates", "none", "openssh"}, []string{"esd", "openssh"}, "none", false},
		{"--updates=value form, then target", []string{"--updates=all", "esd"}, []string{"esd"}, "all", false},
		{"single-dash long flag, no target", []string{"-updates", "all"}, nil, "all", false},
		{"--probe before its target", []string{"--probe", "esd"}, []string{"esd"}, config.DefaultUpdates, true},
		{"-- terminates flag parsing; both sides are targets", []string{"esd", "--", "openssh"}, []string{"esd", "openssh"}, config.DefaultUpdates, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fs := newFlags("fetch")
			updates := fs.String("updates", config.DefaultUpdates, "")
			probe := fs.Bool("probe", false, "")
			e := &Env{Stdout: io.Discard, Stderr: io.Discard}
			targetArgs, err := parseFetchArgs(fs, e, fetchHelp, c.args)
			if err != nil {
				t.Fatalf("parseFetchArgs(%v): %v", c.args, err)
			}
			targets, err := fetchTargets(targetArgs)
			if err != nil {
				t.Fatalf("fetchTargets(%v): %v", targetArgs, err)
			}
			wantTargets := c.wantTargets
			if wantTargets == nil {
				wantTargets = fetchOrder
			}
			if !slices.Equal(targets, wantTargets) {
				t.Errorf("targets = %v, want %v", targets, wantTargets)
			}
			if *updates != c.wantUpdates {
				t.Errorf("updates = %q, want %q", *updates, c.wantUpdates)
			}
			if *probe != c.wantProbe {
				t.Errorf("probe = %v, want %v", *probe, c.wantProbe)
			}
		})
	}
}

// TestFetchArgErrorsExitTwo covers the two ways fetch's arguments can be
// wrong: an unknown flag (the flag package's own error, wrapped as a
// UsageError) and an unknown target (fetchTargets' own check, naming all
// three choices).
func TestFetchArgErrorsExitTwo(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want []string // substrings the message must contain
	}{
		{"unknown flag", []string{"fetch", "--bogus-flag"}, []string{"bogus-flag"}},
		{"unknown target", []string{"fetch", "bogus"}, []string{"esd", "openssh", "updates"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
			e, _, errb := fetchEnv(env)
			code := Run(context.Background(), c.args, e)
			if code != 2 {
				t.Fatalf("code=%d stderr=%s", code, errb.String())
			}
			for _, want := range c.want {
				if !strings.Contains(errb.String(), want) {
					t.Errorf("stderr=%q lacks %q", errb.String(), want)
				}
			}
		})
	}
}

// TestFetchDuplicateTargetsAreDeduped: naming the same target twice is
// redundant, not contradictory, so fetchTargets dedupes rather than
// erroring (the comment on fetchTargets says why).
func TestFetchDuplicateTargetsAreDeduped(t *testing.T) {
	got, err := fetchTargets([]string{"esd", "openssh", "esd"})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, []string{"esd", "openssh"}) {
		t.Fatalf("got %v, want esd and openssh each once, in canonical order", got)
	}
}

func TestFetchHelpBeginsUsage(t *testing.T) {
	e, out, _ := fetchEnv(nil)
	code := Run(context.Background(), []string{"fetch", "--help"}, e)
	if code != 0 || !strings.HasPrefix(out.String(), "usage: vmavs fetch") {
		t.Fatalf("code=%d stdout=%q", code, out.String())
	}
}
