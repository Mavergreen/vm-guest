package cli

import (
	"bytes"
	"context"
	"regexp"
	"strings"
	"testing"
)

// vmavs runs the CLI in-process and returns what a shell would see.
func vmavs(t *testing.T, env map[string]string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	e := &Env{
		Stdin:  strings.NewReader(""),
		Stdout: &out,
		Stderr: &errb,
		Getenv: func(k string) string { return env[k] },
	}
	code := Run(context.Background(), args, e)
	return code, out.String(), errb.String()
}

func TestNoArgumentsIsAUsageError(t *testing.T) {
	code, _, stderr := vmavs(t, nil)
	if code != 2 || !strings.Contains(stderr, "usage: vmavs") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestHelpListsEverySubcommandAndGoesToStdout(t *testing.T) {
	code, stdout, _ := vmavs(t, nil, "help")
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	for _, c := range commandTable() {
		if !strings.Contains(stdout, "  "+c.name) {
			t.Errorf("help omits %q", c.name)
		}
	}
}

func TestUnknownSubcommandNamesItself(t *testing.T) {
	code, _, stderr := vmavs(t, nil, "instal")
	if code != 2 || !strings.Contains(stderr, `"instal"`) {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

func TestVersionPrintsOneLine(t *testing.T) {
	for _, arg := range []string{"version", "--version"} {
		code, stdout, stderr := vmavs(t, nil, arg)
		if code != 0 || stderr != "" {
			t.Fatalf("%s: code=%d stderr=%q", arg, code, stderr)
		}
		if !regexp.MustCompile(`^[0-9]{8}\.[0-9]+[^\n]*\n$`).MatchString(stdout) {
			t.Fatalf("%s: stdout=%q", arg, stdout)
		}
	}
}

func TestEverySubcommandTakesHelp(t *testing.T) {
	for _, c := range commandTable() {
		code, stdout, _ := vmavs(t, nil, c.name, "--help")
		if code != 0 || !strings.HasPrefix(stdout, "usage: vmavs "+c.name) {
			t.Errorf("%s --help: code=%d stdout=%q", c.name, code, stdout)
		}
	}
}

func TestVersionRefusesArguments(t *testing.T) {
	code, _, stderr := vmavs(t, nil, "version", "extra")
	if code != 2 || !strings.Contains(stderr, "vmavs version:") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}

// logf is part of this package's interface for later tasks (Task 3
// onward log subcommand progress with it); nothing in Task 1 calls it
// yet, so this test is what keeps it from looking like dead code.
func TestLogfFormatsOneLineToStderr(t *testing.T) {
	var errb bytes.Buffer
	e := &Env{Stderr: &errb}
	logf(e, "test", "message %d", 1)
	if got := errb.String(); got != "vmavs test: message 1\n" {
		t.Fatalf("logf output = %q", got)
	}
}
