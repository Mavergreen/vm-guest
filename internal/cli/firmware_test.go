package cli

import (
	"archive/zip"
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

	"github.com/Mavergreen/vm-guest/internal/diskimg"
	"github.com/Mavergreen/vm-guest/internal/firmware"
	"github.com/Mavergreen/vm-guest/internal/pins"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// recordingFirmwareBuilder is a firmwareBuilder that notes every call
// instead of building anything, and returns "<name>-path" for each: a
// seam for the tests that only care what cmdFirmware asked the builder
// to do, in what order and with what Inputs.
type recordingFirmwareBuilder struct {
	calls      []string
	opencoreIn firmware.Inputs
	kextsIn    firmware.Inputs
	model      string
	captured   *firmware.Builder
}

func (r *recordingFirmwareBuilder) OpenCore(_ context.Context, in firmware.Inputs) ([]string, error) {
	r.calls = append(r.calls, "OpenCore")
	r.opencoreIn = in
	return []string{"opencore-path"}, nil
}

func (r *recordingFirmwareBuilder) OVMF(_ context.Context) ([]string, error) {
	r.calls = append(r.calls, "OVMF")
	return []string{"ovmf-path"}, nil
}

func (r *recordingFirmwareBuilder) Kexts(_ context.Context, in firmware.Inputs) ([]string, error) {
	r.calls = append(r.calls, "Kexts")
	r.kextsIn = in
	return []string{"kexts-path"}, nil
}

func (r *recordingFirmwareBuilder) EFIImage(_ context.Context, model string) (string, error) {
	r.calls = append(r.calls, "EFIImage")
	r.model = model
	return "efiimage-path", nil
}

// stubFirmwareBuilder makes cmdFirmware's newFirmwareBuilder hand back
// rec, capturing the real *firmware.Builder cmdFirmware built (so a test
// can inspect its fields), and restores the real one when the test ends.
func stubFirmwareBuilder(t *testing.T, rec *recordingFirmwareBuilder) {
	t.Helper()
	orig := newFirmwareBuilder
	newFirmwareBuilder = func(b *firmware.Builder) firmwareBuilder {
		rec.captured = b
		return rec
	}
	t.Cleanup(func() { newFirmwareBuilder = orig })
}

// trackRequests wraps srv's handler to record every request path it
// sees, without changing what it answers.
func trackRequests(srv *httptest.Server) *[]string {
	var paths []string
	orig := srv.Config.Handler
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		orig.ServeHTTP(w, r)
	})
	return &paths
}

func firmwareRegistry(t *testing.T, rows []string) *pins.Registry {
	t.Helper()
	reg, err := pins.Parse(strings.NewReader(strings.Join(rows, "\n") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	return reg
}

func TestFirmwareRunsEveryTargetInOrderByDefault(t *testing.T) {
	_, _, rows := fakeFirmwareServer(t, false)
	rec := &recordingFirmwareBuilder{}
	stubFirmwareBuilder(t, rec)
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	e.Registry = firmwareRegistry(t, rows)
	code := Run(context.Background(), []string{"firmware"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if want := []string{"OpenCore", "OVMF", "Kexts", "EFIImage"}; !slices.Equal(rec.calls, want) {
		t.Fatalf("calls = %v, want %v", rec.calls, want)
	}
	gotLines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if want := []string{"opencore-path", "ovmf-path", "kexts-path", "efiimage-path"}; !slices.Equal(gotLines, want) {
		t.Fatalf("stdout lines = %v, want %v", gotLines, want)
	}
	for _, n := range firmware.OpenCoreSources() {
		if _, ok := rec.opencoreIn[n]; !ok {
			t.Errorf("OpenCore's Inputs lack %s", n)
		}
	}
	for _, n := range firmware.KextSources() {
		if _, ok := rec.kextsIn[n]; !ok {
			t.Errorf("Kexts' Inputs lack %s", n)
		}
	}
}

func TestFirmwareRunsOnlyTheNamedTargetsInTheirOrder(t *testing.T) {
	srv, _, rows := fakeFirmwareServer(t, false)
	seen := trackRequests(srv)
	rec := &recordingFirmwareBuilder{}
	stubFirmwareBuilder(t, rec)
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, _, errb := fetchEnv(env)
	e.Registry = firmwareRegistry(t, rows)
	code := Run(context.Background(), []string{"firmware", "efi", "opencore"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if want := []string{"OpenCore", "Kexts", "EFIImage"}; !slices.Equal(rec.calls, want) {
		t.Fatalf("calls = %v, want %v", rec.calls, want)
	}
	want := map[string]bool{}
	for _, n := range append(append([]string{}, firmware.OpenCoreSources()...), firmware.KextSources()...) {
		want["/"+n+".tar.gz"] = true
	}
	for _, p := range *seen {
		if !want[p] {
			t.Errorf("fetched %s, which neither opencore nor efi reads", p)
		}
	}
}

// TestFirmwarePassesItsFlags runs with the target once before its flags
// and once after: cmdFirmware's flags and targets may appear in either
// order (fix round 1), and both orderings must reach the Builder the
// same way.
func TestFirmwarePassesItsFlags(t *testing.T) {
	orderings := []struct {
		name string
		args []string
	}{
		{"flags then target", []string{"firmware", "--smbios", "MacPro5,1", "--ccache", "--compiler", "gcc 15.1.0", "efi"}},
		{"target then flags", []string{"firmware", "efi", "--smbios", "MacPro5,1", "--ccache", "--compiler", "gcc 15.1.0"}},
	}
	for _, o := range orderings {
		t.Run(o.name, func(t *testing.T) {
			_, _, rows := fakeFirmwareServer(t, false)
			rec := &recordingFirmwareBuilder{}
			stubFirmwareBuilder(t, rec)
			env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir(), "GCC_BIN": "x86_64-elf-"}
			e, _, errb := fetchEnv(env)
			e.Registry = firmwareRegistry(t, rows)
			e.Environ = func() []string { return []string{"PATH=/usr/bin", "HOME=/x"} }
			code := Run(context.Background(), o.args, e)
			if code != 0 {
				t.Fatalf("code=%d stderr=%s", code, errb.String())
			}
			if !slices.Equal(rec.calls, []string{"Kexts", "EFIImage"}) {
				t.Fatalf("calls = %v, want just the efi target (Kexts, EFIImage)", rec.calls)
			}
			if rec.model != "MacPro5,1" {
				t.Fatalf("EFIImage model = %q, want MacPro5,1", rec.model)
			}
			if rec.captured == nil {
				t.Fatal("newFirmwareBuilder was never called")
			}
			if !rec.captured.Ccache {
				t.Fatalf("Builder.Ccache = false, want true")
			}
			if rec.captured.Toolchain.Override != "gcc 15.1.0" {
				t.Fatalf("Toolchain.Override = %q, want %q", rec.captured.Toolchain.Override, "gcc 15.1.0")
			}
			if rec.captured.Toolchain.GCCBin != "x86_64-elf-" {
				t.Fatalf("Toolchain.GCCBin = %q, want x86_64-elf-", rec.captured.Toolchain.GCCBin)
			}
			if want := e.Environ(); !slices.Equal(rec.captured.Env, want) {
				t.Fatalf("Builder.Env = %v, want %v", rec.captured.Env, want)
			}
		})
	}
}

// TestFirmwareArgOrderingsParseCorrectly covers the orderings fix round
// 1 asked for: a target before its flags, a target between two flags,
// and "--" ending flag parsing for good so a flag-shaped word after it
// is an unknown target, not a flag -- exactly as vmavs fetch's own
// parseInterleaved-based parsing behaves.
func TestFirmwareArgOrderingsParseCorrectly(t *testing.T) {
	cases := []struct {
		name        string
		args        []string
		wantTargets []string // in the order they ran; nil means an error
		wantCode    int
		wantErr     string
	}{
		{"target, then a flag+value", []string{"efi", "--smbios", "MacPro5,1"}, []string{"efi"}, 0, ""},
		{"flag+value, then target", []string{"--smbios", "MacPro5,1", "efi"}, []string{"efi"}, 0, ""},
		{"target, flag, target", []string{"opencore", "--ccache", "ovmf"}, []string{"opencore", "ovmf"}, 0, ""},
		{"target, then a flag with a quoted value", []string{"efi", "--compiler", "gcc 15.1.0"}, []string{"efi"}, 0, ""},
		{"-- then a flag-shaped target", []string{"--", "efi", "--probe"}, nil, 2, `unknown firmware target "--probe"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, _, rows := fakeFirmwareServer(t, false)
			rec := &recordingFirmwareBuilder{}
			stubFirmwareBuilder(t, rec)
			env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
			e, _, errb := fetchEnv(env)
			e.Registry = firmwareRegistry(t, rows)
			code := Run(context.Background(), append([]string{"firmware"}, c.args...), e)
			if code != c.wantCode {
				t.Fatalf("code=%d, want %d; stderr=%s", code, c.wantCode, errb.String())
			}
			if c.wantErr != "" && !strings.Contains(errb.String(), c.wantErr) {
				t.Fatalf("stderr=%q, want it to contain %q", errb.String(), c.wantErr)
			}
			if c.wantCode != 0 {
				return
			}
			var ran []string
			for _, call := range rec.calls {
				switch call {
				case "OpenCore":
					ran = append(ran, "opencore")
				case "OVMF":
					ran = append(ran, "ovmf")
				case "EFIImage":
					ran = append(ran, "efi")
				}
			}
			if !slices.Equal(ran, c.wantTargets) {
				t.Fatalf("targets ran = %v, want %v (raw calls: %v)", ran, c.wantTargets, rec.calls)
			}
		})
	}
}

func TestFirmwareRefusesBadArguments(t *testing.T) {
	cases := []struct {
		name string
		args []string
	}{
		{"unknown target", []string{"firmware", "bogus"}},
		{"bad smbios", []string{"firmware", "--smbios", "a<b"}},
		{"empty compiler", []string{"firmware", "--compiler", ""}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
			e, _, errb := fetchEnv(env)
			code := Run(context.Background(), c.args, e)
			if code != 2 {
				t.Fatalf("code=%d stderr=%s", code, errb.String())
			}
			if errb.Len() == 0 {
				t.Fatalf("no message on stderr")
			}
		})
	}
}

func TestFirmwareHelp(t *testing.T) {
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	code := Run(context.Background(), []string{"firmware", "--help"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	for _, want := range []string{"opencore", "ovmf", "efi", "--smbios", "--ccache", "--compiler", "vmavs fetch firmware"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("help lacks %q:\n%s", want, out.String())
		}
	}
}

// makeKextZip is a release zip holding just enough of <name>.kext for
// extractKext and checkKext to accept it.
func makeKextZip(t *testing.T, name string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	files := map[string]string{
		name + ".kext/Contents/Info.plist":    "plist " + name,
		name + ".kext/Contents/MacOS/" + name: "macho " + name,
	}
	for _, p := range []string{name + ".kext/Contents/Info.plist", name + ".kext/Contents/MacOS/" + name} {
		w, err := zw.Create(p)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(w, files[p]); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// TestFirmwareEFIForReal runs the real Builder (no firmwareBuilder stub)
// end to end for the "efi" target: build/artifacts is already shipped
// (as OpenCore leaves it), the kext releases come from httptest, and the
// Runner has no tools at all -- neither Kexts nor EFIImage (with the
// default SMBIOS, which config.plist already has) needs one.
func TestFirmwareEFIForReal(t *testing.T) {
	home := t.TempDir()
	art := filepath.Join(home, "build", "artifacts")
	if err := os.MkdirAll(art, 0o755); err != nil {
		t.Fatal(err)
	}
	var sums strings.Builder
	for _, n := range firmware.ShipNames() {
		body := []byte("fake artifact " + n)
		if err := os.WriteFile(filepath.Join(art, n), body, 0o644); err != nil {
			t.Fatal(err)
		}
		s := sha256.Sum256(body)
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(s[:]), n)
	}
	if err := os.WriteFile(filepath.Join(art, "SHA256SUMS"), []byte(sums.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	bodies := map[string][]byte{}
	for _, k := range firmware.Kexts {
		bodies[k.Source] = makeKextZip(t, k.Name)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/"), ".zip")
		if b, ok := bodies[name]; ok {
			w.Write(b)
			return
		}
		w.WriteHeader(404)
	}))
	t.Cleanup(srv.Close)
	var rows []string
	for _, k := range firmware.Kexts {
		rows = append(rows, fmt.Sprintf("%s\t%s/%s.zip\t%s", k.Source, srv.URL, k.Source, sum(bodies[k.Source])))
	}

	env := map[string]string{"VMAVS_HOME": home, "HOME": t.TempDir()}
	e, out, errb := fetchEnv(env)
	e.Registry = firmwareRegistry(t, rows)
	e.Runner = &proc.Fake{}
	code := Run(context.Background(), []string{"firmware", "efi"}, e)
	if code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	want := filepath.Join(home, "build", "opencore.img")
	if !strings.Contains(out.String(), want) {
		t.Fatalf("stdout=%q, want it to contain %s", out.String(), want)
	}

	fh, err := os.Open(want)
	if err != nil {
		t.Fatal(err)
	}
	defer fh.Close()
	fi, err := fh.Stat()
	if err != nil {
		t.Fatal(err)
	}
	_, parts, err := diskimg.ReadGPT(fh, uint64(fi.Size())/diskimg.SectorSize)
	if err != nil {
		t.Fatal(err)
	}
	esps := 0
	for _, p := range parts {
		if p.Type == diskimg.TypeEFISystem {
			esps++
		}
	}
	if esps != 1 {
		t.Fatalf("%d ESPs, want 1: %+v", esps, parts)
	}
}

// TestFirmwareOVMFWithoutATreeSaysWhatToRun: OVMF alone, on an empty
// home, with a fake gcc banner inside the declared range so the compiler
// check itself does not stop it first.
func TestFirmwareOVMFWithoutATreeSaysWhatToRun(t *testing.T) {
	env := map[string]string{"VMAVS_HOME": t.TempDir(), "HOME": t.TempDir()}
	e, _, errb := fetchEnv(env)
	e.Runner = &proc.Fake{Paths: map[string]string{"gcc": "/usr/bin/gcc"}, Handle: func(c proc.Cmd) error {
		if c.Name == "gcc" && len(c.Args) == 1 && c.Args[0] == "--version" {
			io.WriteString(c.Stdout, "gcc (GCC) 13.3.0\n")
		}
		return nil
	}}
	code := Run(context.Background(), []string{"firmware", "ovmf"}, e)
	if code != 1 {
		t.Fatalf("code=%d stderr=%s", code, errb.String())
	}
	if !strings.Contains(errb.String(), "run 'vmavs firmware opencore' first") {
		t.Fatalf("stderr=%q, want it to say what to run first", errb.String())
	}
}
