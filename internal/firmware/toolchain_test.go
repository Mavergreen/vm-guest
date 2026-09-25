package firmware

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/Mavergreen/vm-guest/internal/proc"
)

// shellLib runs a lib/*.sh function under bash and returns its stdout.
func shellLib(t *testing.T, libs []string, call string) string {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed")
	}
	src := ". lib/common.sh"
	for _, l := range libs {
		src += "; . lib/" + l
	}
	cmd := exec.Command("bash", "-c", src+"; "+call)
	cmd.Dir = repo(t)
	cmd.Env = append(os.Environ(), "MQG_COMPILER=", "MQG_CCACHE=", "MQG_CCACHE_BIN=")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s: %v", call, err)
	}
	return string(out)
}

func TestRangeVerdictMatchesTheLibrary(t *testing.T) {
	cases := [][2]string{
		{"gcc", "12.4.0"}, {"gcc", "13.0.0"}, {"gcc", "13.3.0"}, {"gcc", "15.1.1"},
		{"gcc", "16.2.1"}, {"gcc", "17.0.0"}, {"gcc", "x.y"}, {"clang", "17.0.0"},
		{"clang", ""}, {"unknown", ""},
	}
	for _, c := range cases {
		v, d := RangeVerdict(c[0], c[1])
		want := shellLib(t, []string{"compiler.sh"}, "compiler_range_verdict '"+c[0]+"' '"+c[1]+"'")
		if got := v + "\t" + d + "\n"; got != want {
			t.Errorf("%v:\n go:    %q\n shell: %q", c, got, want)
		}
	}
}

func TestParseCompilerMatchesTheLibrary(t *testing.T) {
	banners := []string{
		"gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0",
		"gcc (GCC) 15.1.1 20250425",
		"cc (GCC) 14.2.0",
		"x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0",
		"Apple clang version 17.0.0 (clang-1700.0.13)",
		"clang version 18.1.3",
		"gcc 13.3.0",
		"tcc version 0.9.27",
		"",
	}
	for _, b := range banners {
		fam, ver := ParseCompiler(b)
		want := shellLib(t, []string{"compiler.sh"}, "compiler_parse '"+b+"'")
		if got := fam + "\t" + ver + "\t" + b + "\n"; got != want {
			t.Errorf("%q:\n go:    %q\n shell: %q", b, got, want)
		}
	}
}

func TestTheDeclaredRangeIsGcc13Through16(t *testing.T) {
	if RangeText() != "gcc 13 through 16, verified at gcc 13.3.0, 14.2.0 and 16.2.1" {
		t.Fatal(RangeText())
	}
	if got := shellLib(t, []string{"compiler.sh"}, "compiler_range_text; echo"); got != RangeText()+"\n" {
		t.Fatalf("shell says %q", got)
	}
}

// gccFake answers `gcc --version` and `gcc -dumpmachine` as banner and
// target, and knows gcc is on PATH unless banner is "".
func gccFake(banner, target string) *proc.Fake {
	f := &proc.Fake{Paths: map[string]string{}}
	if banner != "" {
		f.Paths["gcc"] = "/usr/bin/gcc"
	}
	f.Handle = func(c proc.Cmd) error {
		if c.Name == "gcc" && len(c.Args) == 1 && c.Stdout != nil {
			switch c.Args[0] {
			case "--version":
				c.Stdout.Write([]byte(banner + "\nCopyright (C) 2023\n"))
			case "-dumpmachine":
				c.Stdout.Write([]byte(target + "\n"))
			}
		}
		return nil
	}
	return f
}

func TestStatusNamesWhatItCouldNotRead(t *testing.T) {
	ctx := context.Background()
	v, d := Toolchain{Runner: gccFake("tcc version 0.9.27", "x")}.Status(ctx)
	if v != "UNKNOWN" || !strings.HasSuffix(d, `; it said "tcc version 0.9.27"`) {
		t.Fatalf("%s %s", v, d)
	}
	v, d = Toolchain{Runner: gccFake("", "")}.Status(ctx)
	if v != "UNKNOWN" || !strings.HasSuffix(d, "; gcc is not on PATH or did not answer --version") {
		t.Fatalf("%s %s", v, d)
	}
}

func TestTheOverrideReplacesDetectionAndIsRecorded(t *testing.T) {
	tc := Toolchain{Runner: gccFake("gcc (GCC) 12.1.0", "x"), Override: "gcc 15.1.0"}
	if v, _ := tc.Status(context.Background()); v != "INSIDE" {
		t.Fatalf("verdict %s", v)
	}
	line := tc.RangeLine(context.Background())
	if !strings.HasPrefix(line, "INSIDE -- gcc 15.1.0 is inside") ||
		!strings.HasSuffix(line, " [--compiler override in effect: gcc 15.1.0]") {
		t.Fatal(line)
	}
	// The override moves nothing else: the compiler line is the real one.
	if cl := tc.CompilerLine(context.Background()); !strings.HasPrefix(cl, "gcc (GCC) 12.1.0 (x) -std=gnu17") {
		t.Fatal(cl)
	}
}

func TestCompilerLine(t *testing.T) {
	ctx := context.Background()
	tc := Toolchain{Runner: gccFake("gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0", "x86_64-linux-gnu")}
	if got := tc.CompilerLine(ctx); got != "gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 (x86_64-linux-gnu) -std=gnu17" {
		t.Fatal(got)
	}
	if got := (Toolchain{Runner: gccFake("", "")}).CompilerLine(ctx); got != "gcc not found" {
		t.Fatal(got)
	}
	if got := (Toolchain{Runner: gccFake("", ""), GCCBin: "x86_64-elf-"}).GCC(); got != "x86_64-elf-gcc" {
		t.Fatal(got)
	}
}

func TestCheckRefusesBelowTheFloorAndWarnsAbove(t *testing.T) {
	ctx := context.Background()
	var log bytes.Buffer
	logf := func(f string, a ...any) { log.WriteString(fmt.Sprintf(f, a...) + "\n") }

	err := Toolchain{Runner: gccFake("gcc (GCC) 12.2.0", "x")}.Check(ctx, logf)
	if err == nil || !strings.Contains(err.Error(), "below the floor") {
		t.Fatalf("below: %v", err)
	}
	if !strings.Contains(log.String(), "NOT tested") || !strings.Contains(log.String(), "--compiler") {
		t.Fatalf("below log: %s", log.String())
	}

	log.Reset()
	if err := (Toolchain{Runner: gccFake("gcc (GCC) 17.1.0", "x")}).Check(ctx, logf); err != nil {
		t.Fatalf("above must proceed: %v", err)
	}
	if !strings.Contains(log.String(), "above the ceiling") || !strings.Contains(log.String(), "not proof") {
		t.Fatalf("above log: %s", log.String())
	}

	log.Reset()
	if err := (Toolchain{Runner: gccFake("tcc version 0.9.27", "x")}).Check(ctx, logf); err != nil {
		t.Fatalf("unknown must proceed: %v", err)
	}
	if !strings.Contains(log.String(), "--compiler") {
		t.Fatalf("unknown log: %s", log.String())
	}
}

func TestCcacheIsOffByDefault(t *testing.T) {
	if CcacheDefault {
		t.Fatal("ccache must stay off until someone measures it (lib/ccache.sh)")
	}
	if got := shellLib(t, []string{"ccache.sh"}, `printf '%s\n' "$MQG_CCACHE_DEFAULT"`); got != "0\n" {
		t.Fatalf("shell default %q", got)
	}
}

// The verdicts are the library's, word for word, except where the shell
// names its environment variable and Go names its flag.
func TestCcacheVerdictMatchesTheLibrary(t *testing.T) {
	flagForVar := strings.NewReplacer(
		"MQG_CCACHE=1 but ccache", "--ccache was given but ccache",
		"set MQG_CCACHE=1.", "pass --ccache.",
	)
	for _, c := range []struct {
		wanted bool
		path   string
	}{{true, "/usr/bin/ccache"}, {true, ""}, {false, "/usr/bin/ccache"}, {false, ""}} {
		w := "0"
		if c.wanted {
			w = "1"
		}
		v, d := CcacheVerdict(c.wanted, c.path)
		want := flagForVar.Replace(shellLib(t, []string{"ccache.sh"}, "ccache_verdict "+w+" '"+c.path+"'"))
		if got := v + "\t" + d + "\n"; got != want {
			t.Errorf("%v:\n go:    %q\n shell: %q", c, got, want)
		}
	}
	if CcacheLine("USED", "/usr/bin/ccache") != "used (/usr/bin/ccache)" ||
		CcacheLine("OFF", "ccache is not installed; every file is compiled") != "not used -- ccache is not installed; every file is compiled" {
		t.Fatal("CcacheLine")
	}
}

func TestTheShimWrapsTheRealCompilerByAbsolutePath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip()
	}
	dir := filepath.Join(t.TempDir(), "ccache-bin")
	look := func(n string) (string, error) {
		if n == "gcc" {
			return "/usr/bin/gcc", nil
		}
		return "", exec.ErrNotFound
	}
	if err := writeCcacheShims(dir, "/usr/bin/ccache", look); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "gcc"))
	if err != nil || string(b) != "#!/bin/sh\nexec /usr/bin/ccache /usr/bin/gcc \"$@\"\n" {
		t.Fatalf("%q %v", b, err)
	}
	if fi, _ := os.Stat(filepath.Join(dir, "gcc")); fi.Mode().Perm() != 0o755 {
		t.Fatalf("mode %v", fi.Mode())
	}
	if _, err := os.Stat(filepath.Join(dir, "g++")); err == nil {
		t.Fatal("no g++ on PATH, so no g++ shim")
	}
}
