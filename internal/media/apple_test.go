package media

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	vmguest "github.com/Mavergreen/vm-guest"
)

func TestRequiredFilesMatchTheScript(t *testing.T) {
	need(t, "bash")
	cmd := exec.Command("bash", "media/verify-installer-img.sh", "--required")
	cmd.Dir = repo(t)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("verify-installer-img.sh --required: %v", err)
	}
	got := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	want := RequiredFiles()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("the script requires\n%s\nGo requires\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if len(want) != 19 {
		t.Fatalf("%d required files, want 19", len(want))
	}
}

// pinned is the embedded apple-packages.sha256's non-comment lines.
func pinned(t *testing.T) []string {
	t.Helper()
	b, err := fs.ReadFile(vmguest.Files, "media/apple-packages.sha256")
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if !strings.HasPrefix(l, "#") {
			lines = append(lines, l)
		}
	}
	return lines
}

func TestApplesPinnedSumsCoverThePackages(t *testing.T) {
	line := regexp.MustCompile(`^[0-9a-f]{64}  \./([^/]+)$`)
	names := map[string]bool{}
	for _, l := range pinned(t) {
		m := line.FindStringSubmatch(l)
		if m == nil {
			t.Fatalf("not a sha256sum line: %q", l)
		}
		names[m[1]] = true
	}
	want := map[string]bool{}
	for _, f := range RequiredFiles() {
		if name, ok := strings.CutPrefix(f, "System/Installation/Packages/"); ok {
			want[name] = true
		}
	}
	if len(want) != 16 || len(names) != len(want) {
		t.Fatalf("%d pinned names, %d packages required (want 16 of each)", len(names), len(want))
	}
	for n := range want {
		if !names[n] {
			t.Errorf("%s is required but has no pinned sum", n)
		}
	}
}

const badSum = "0000000000000000000000000000000000000000000000000000000000000000"

// sumFixtures are the pinned sums without ./, as the microVM prints
// them, and the same with BSD.pkg's value changed and X11redirect.pkg's
// line removed. The two problem names differ at their first character,
// so the shell's locale-aware sort and Go's bytewise one agree.
func sumFixtures(t *testing.T) (good, bad []byte, wantBad []string) {
	t.Helper()
	var g, b strings.Builder
	var want string
	for _, l := range pinned(t) {
		sum, name, _ := strings.Cut(l, "  ./")
		g.WriteString(sum + "  " + name + "\n")
		switch name {
		case "BSD.pkg":
			want = sum
			b.WriteString(badSum + "  " + name + "\n")
		case "X11redirect.pkg":
		default:
			b.WriteString(sum + "  " + name + "\n")
		}
	}
	return []byte(g.String()), []byte(b.String()), []string{
		"BSD.pkg: FAILED -- " + badSum + " is not what Apple shipped (" + want + ")",
		"X11redirect.pkg: MISSING -- the media does not have it",
	}
}

func TestCheckAppleSums(t *testing.T) {
	good, bad, wantBad := sumFixtures(t)
	problems, err := CheckAppleSums(good)
	if err != nil || len(problems) != 0 {
		t.Fatalf("the pinned values: %q, %v", problems, err)
	}
	problems, err = CheckAppleSums(bad)
	if err == nil {
		t.Fatal("a changed value and a missing line gave no error")
	}
	if strings.Join(problems, "\n") != strings.Join(wantBad, "\n") {
		t.Fatalf("problems\n%s\nwant\n%s", strings.Join(problems, "\n"), strings.Join(wantBad, "\n"))
	}
}

func TestCheckAppleSumsMatchesTheShell(t *testing.T) {
	need(t, "bash", "awk", "sort")
	good, bad, _ := sumFixtures(t)
	dir := t.TempDir()
	for name, sums := range map[string][]byte{"good": good, "bad": bad} {
		t.Run(name, func(t *testing.T) {
			file := filepath.Join(dir, name+".sums")
			if err := os.WriteFile(file, sums, 0o644); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("bash", "media/verify-installer-img.sh", "--check-sums", file)
			cmd.Dir = repo(t)
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			err := cmd.Run()
			code := 0
			var ee *exec.ExitError
			if errors.As(err, &ee) {
				code = ee.ExitCode()
			} else if err != nil {
				t.Fatal(err)
			}
			var shell []string
			for _, l := range strings.Split(stderr.String(), "\n") {
				if p, ok := strings.CutPrefix(l, "    "); ok {
					shell = append(shell, p)
				}
			}
			problems, gerr := CheckAppleSums(sums)
			if strings.Join(shell, "\n") != strings.Join(problems, "\n") {
				t.Errorf("the shell reports\n%s\nGo reports\n%s", strings.Join(shell, "\n"), strings.Join(problems, "\n"))
			}
			if want := map[bool]int{false: 0, true: 1}[gerr != nil]; code != want {
				t.Errorf("the shell exits %d, Go's error %v\n%s", code, gerr, stderr.String())
			}
		})
	}
}
