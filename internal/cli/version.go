package cli

import (
	"context"
	"fmt"

	"github.com/Mavergreen/vm-guest/internal/version"
)

const versionHelp = `usage: vmavs version

Print this vmavs's version: YYYYMMDD.N for a release, or
YYYYMMDD.0-dev+<commit> for a development build.
`

func cmdVersion(_ context.Context, e *Env, args []string) error {
	fs := newFlags("version")
	if err := parse(fs, e, versionHelp, args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usagef("version takes no arguments")
	}
	fmt.Fprintln(e.Stdout, version.String())
	return nil
}
