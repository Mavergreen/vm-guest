// Package version answers `vmavs version`.
package version

import (
	"runtime/debug"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
)

// Full is the release version, YYYYMMDD.N. It is set only when a release
// is built:
//
//	go build -ldflags "-X github.com/Mavergreen/vm-guest/internal/version.Full=$FULL"
//
// with FULL from build/version.sh. It is empty in a development build.
var Full string

// String is the release version. For a development build it is the
// version line with ".0-dev" and the commit it was built from, so it can
// never be mistaken for a release.
func String() string {
	if Full != "" {
		return Full
	}
	s := strings.TrimSpace(vmguest.UpstreamVersion) + ".0-dev"
	if rev, dirty := vcs(); rev != "" {
		if len(rev) > 12 {
			rev = rev[:12]
		}
		s += "+" + rev
		if dirty {
			s += ".dirty"
		}
	}
	return s
}

func vcs() (rev string, dirty bool) {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "", false
	}
	for _, kv := range info.Settings {
		switch kv.Key {
		case "vcs.revision":
			rev = kv.Value
		case "vcs.modified":
			dirty = kv.Value == "true"
		}
	}
	return rev, dirty
}
