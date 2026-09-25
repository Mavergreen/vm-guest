package cli

import (
	"context"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const fetchHelp = `usage: vmavs fetch [esd|openssh|updates ...] [--updates none|security|all] [--probe]

Fetch and verify vmavs's pinned inputs: Apple's InstallESD.dmg (esd), the
guest's OpenSSH release (openssh), and Apple's post-10.9.5 updates
(updates). With no target, all three. Each fetched file's path is printed
on stdout, one per line, in the order esd, openssh (its base package,
then System-Replace), updates (install order); progress and adoption go
to stderr as "vmavs fetch: ...".

It first tries to adopt the shell tree's own downloads: inside VMAVS_HOME
(which may itself be the shell tree's home, phase 1's documented way of
booting a shell-built image) and, when it differs, the shell tree's own
legacy home too -- media/InstallESD.dmg, openssh/<tag>/ and updates/.
Adoption is verified the same as everything else here, and never moves or
deletes anything in the old home.

Apple's installer is served over plain HTTP, by Apple's own design (the
osrecovery handshake's token is a cookie, and the download itself is
unencrypted): its checksum is what is checked, and it is checked before
the download has a name of its own.

--probe performs the osrecovery handshake and asks for InstallESD.dmg's
size, without downloading it (esd only).
`

// Endpoints is where cmdFetch reaches Apple's osrecovery service and the
// guest's OpenSSH releases.
type Endpoints struct{ Recovery, OpenSSHReleases string }

// fetchOrder is the order cmdFetch runs and prints targets in, regardless
// of the order they were named in.
var fetchOrder = []string{"esd", "openssh", "updates"}

func cmdFetch(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("fetch")
	updates := fs.String("updates", config.DefaultUpdates,
		fmt.Sprintf("which post-10.9.5 updates to fetch (%s)", strings.Join(config.UpdateChoices, "|")))
	probe := fs.Bool("probe", false, "esd only: print the asset URL and size from the osrecovery handshake; download nothing")
	// flag.FlagSet stops parsing at the first non-flag argument, but the
	// usage this command was given puts targets before flags (vmavs fetch
	// updates --updates none). Splitting them out first lets both orders
	// work.
	flagArgs, targetArgs := splitFetchArgs(args)
	if err := parse(fs, e, fetchHelp, flagArgs); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return usagef("unexpected argument %q", fs.Arg(0))
	}
	targets, err := fetchTargets(targetArgs)
	if err != nil {
		return err
	}
	if !slices.Contains(config.UpdateChoices, *updates) {
		return usagef("--updates %q: choose one of %s", *updates, strings.Join(config.UpdateChoices, ", "))
	}
	if *probe && !(len(targets) == 1 && targets[0] == "esd") {
		return usagef("--probe works with esd only")
	}

	p, err := paths(e)
	if err != nil {
		return err
	}
	reg := e.Registry
	if reg == nil {
		reg, err = pins.Embedded()
		if err != nil {
			return err
		}
	}
	ep := endpoints(e)
	// legacyBase is "" unless the shell tree's own home is a different
	// place than VMAVS_HOME -- when VMAVS_HOME already IS the shell tree's
	// home (phase 1's documented way of booting a shell-built image),
	// there is nothing more to adopt from.
	legacyBase := ""
	if legacy := config.LegacyHome(e.Getenv); legacy != "" && legacy != p.Home {
		legacyBase = legacy
	}

	if *probe {
		rc := fetch.Recovery{Base: ep.Recovery, Client: e.HTTP}
		url, size, err := rc.Probe(ctx, reg, e.HTTP)
		if err != nil {
			return err
		}
		fmt.Fprintf(e.Stdout, "%s\t%d\n", url, size)
		return nil
	}

	g := &fetch.Getter{Paths: p, Client: e.HTTP, Log: func(format string, a ...any) { logf(e, "fetch", format, a...) }}

	for _, t := range targets {
		switch t {
		case "esd":
			adopt := []string{filepath.Join(p.Home, "media", "InstallESD.dmg")}
			if legacyBase != "" {
				adopt = append(adopt, filepath.Join(legacyBase, "media", "InstallESD.dmg"))
			}
			rc := fetch.Recovery{Base: ep.Recovery, Client: e.HTTP}
			path, err := g.InstallESD(ctx, reg, rc, adopt)
			if err != nil {
				return err
			}
			fmt.Fprintln(e.Stdout, path)

		case "openssh":
			tag, err := fetch.OpenSSHTag()
			if err != nil {
				return err
			}
			home := filepath.Join(p.Home, "openssh", tag)
			dir := home
			if legacyBase != "" {
				dir = adoptDir(home, filepath.Join(legacyBase, "openssh", tag))
			}
			pkgs, err := g.OpenSSH(ctx, ep.OpenSSHReleases, tag, dir)
			if err != nil {
				return err
			}
			fmt.Fprintln(e.Stdout, pkgs.Base)
			fmt.Fprintln(e.Stdout, pkgs.Replace)

		case "updates":
			home := filepath.Join(p.Home, "updates")
			dir := home
			if legacyBase != "" {
				dir = adoptDir(home, filepath.Join(legacyBase, "updates"))
			}
			ups, err := g.Updates(ctx, reg, *updates, dir)
			if err != nil {
				return err
			}
			for _, u := range ups {
				fmt.Fprintln(e.Stdout, u.Path)
			}
		}
	}
	return nil
}

// splitFetchArgs separates args into flag tokens (with any value token
// that belongs to them) and positional target names, so flags and
// targets can appear in either order -- flag.FlagSet.Parse itself stops
// at the first non-flag argument and never looks past it.
func splitFetchArgs(args []string) (flagArgs, targets []string) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-" || !strings.HasPrefix(a, "-") {
			targets = append(targets, a)
			continue
		}
		flagArgs = append(flagArgs, a)
		if fetchFlagTakesValue(a) && i+1 < len(args) {
			i++
			flagArgs = append(flagArgs, args[i])
		}
	}
	return flagArgs, targets
}

// fetchFlagTakesValue reports whether a flag token (as typed, dashes and
// all) consumes the next argument as its value: --updates X does,
// --updates=X carries its own, and every other fetch flag is boolean.
func fetchFlagTakesValue(token string) bool {
	if strings.Contains(token, "=") {
		return false
	}
	return strings.TrimLeft(token, "-") == "updates"
}

// fetchTargets validates args against fetchOrder and returns the
// requested targets in canonical order (esd, openssh, updates),
// regardless of the order or repetition they were named in. No args
// means all three.
func fetchTargets(args []string) ([]string, error) {
	if len(args) == 0 {
		return fetchOrder, nil
	}
	want := map[string]bool{}
	for _, a := range args {
		if !slices.Contains(fetchOrder, a) {
			return nil, usagef("unknown fetch target %q: choose from esd, openssh, updates", a)
		}
		want[a] = true
	}
	var out []string
	for _, t := range fetchOrder {
		if want[t] {
			out = append(out, t)
		}
	}
	return out, nil
}

// endpoints is e.Endpoints, or the real ones.
func endpoints(e *Env) Endpoints {
	if e.Endpoints != nil {
		return *e.Endpoints
	}
	return Endpoints{Recovery: fetch.DefaultRecovery, OpenSSHReleases: fetch.DefaultOpenSSHReleases}
}

// adoptDir picks between VMAVS_HOME's own copy of the shell tree's layout
// (home) and the shell tree's own legacy home's copy (legacy), preferring
// home -- VMAVS_HOME may itself be the shell tree's home -- unless only
// legacy exists. Neither existing is not an error: OpenSSH and Updates
// simply find nothing to adopt there.
func adoptDir(home, legacy string) string {
	if !config.Exists(home) && config.Exists(legacy) {
		return legacy
	}
	return home
}
