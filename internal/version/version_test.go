package version

import (
	"regexp"
	"testing"
)

func TestDevBuildSaysItIsADevBuild(t *testing.T) {
	// A development build must never print something that looks like a
	// release: YYYYMMDD.N is what a release tag looks like.
	Full = ""
	got := String()
	re := regexp.MustCompile(`^[0-9]{8}\.0-dev(\+[0-9a-f]{1,12}(\.dirty)?)?$`)
	if !re.MatchString(got) {
		t.Fatalf("String() = %q, want YYYYMMDD.0-dev[+rev[.dirty]]", got)
	}
}

func TestReleaseBuildPrintsTheReleaseVersion(t *testing.T) {
	Full = "20260922.3"
	defer func() { Full = "" }()
	if got := String(); got != "20260922.3" {
		t.Fatalf("String() = %q, want 20260922.3", got)
	}
}
