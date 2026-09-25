package cli

import (
	"context"
	"flag"
	"fmt"
	"slices"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/firmware"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const fetchHelp = `usage: vmavs fetch [esd|openssh|updates|firmware ...] [--updates none|security|all] [--probe]

Fetch and verify vmavs's pinned inputs: Apple's InstallESD.dmg
(esd), the guest's OpenSSH release (openssh), Apple's post-10.9.5
updates (updates), and the firmware's pinned sources -- OpenCorePkg,
ocbuild's efibuild.sh, EDK II (audk) and its submodules, and the
Lilu and VirtualSMC kext releases (firmware). With no target, all
four. Each fetched file's path is printed on stdout, one per line, in
the order esd, openssh (its base package, then System-Replace), updates
(install order), firmware (each pinned source, in build order); progress
and adoption go to stderr as "vmavs fetch: ...".

It first tries to adopt the shell tree's own downloads: inside VMAVS_HOME
(which may itself be the shell tree's home, phase 1's documented way of
booting a shell-built image) and, when it differs, the shell tree's own
legacy home too -- media/InstallESD.dmg, openssh/<tag>/, updates/ and
build/ (the firmware's own downloads).
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
// of the order they were named in. Spec §2 says fetch with no argument
// gets "all of" the pinned inputs, so firmware -- added in phase 3 -- is
// included here too.
var fetchOrder = []string{"esd", "openssh", "updates", "firmware"}

func cmdFetch(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("fetch")
	updates := fs.String("updates", config.DefaultUpdates,
		fmt.Sprintf("which post-10.9.5 updates to fetch (%s)", strings.Join(config.UpdateChoices, "|")))
	probe := fs.Bool("probe", false, "esd only: print the asset URL and size from the osrecovery handshake; download nothing")
	targetArgs, err := parseFetchArgs(fs, e, fetchHelp, args)
	if err != nil {
		return err
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
	// Before anything can fail: the user whose images are in the shell
	// tree's home should hear where they are whether this fetch works or
	// not.
	if hint := fetchLegacyHint(e); hint != "" {
		logf(e, "fetch", "%s", hint)
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

	client := httpClient(e)
	logFetch := func(format string, a ...any) { logf(e, "fetch", format, a...) }
	rc := fetch.Recovery{Base: ep.Recovery, Client: client, Log: logFetch}
	if *probe {
		url, size, err := rc.Probe(ctx, reg)
		if err != nil {
			return err
		}
		fmt.Fprintf(e.Stdout, "%s\t%d\n", url, size)
		return nil
	}

	g := &fetch.Getter{Paths: p, Client: client, Log: logFetch}

	for _, t := range targets {
		switch t {
		case "esd":
			path, err := g.InstallESD(ctx, reg, rc, adoptCandidates(p, legacyBase, config.Paths.ShellESD))
			if err != nil {
				return err
			}
			fmt.Fprintln(e.Stdout, path)

		case "openssh":
			tag, err := fetch.OpenSSHTag()
			if err != nil {
				return err
			}
			pkgs, err := g.OpenSSH(ctx, ep.OpenSSHReleases, tag, adoptCandidates(p, legacyBase, func(q config.Paths) string { return q.ShellOpenSSH(tag) }))
			if err != nil {
				return err
			}
			fmt.Fprintln(e.Stdout, pkgs.Base)
			fmt.Fprintln(e.Stdout, pkgs.Replace)

		case "updates":
			ups, err := g.Updates(ctx, reg, *updates, adoptCandidates(p, legacyBase, config.Paths.ShellUpdates))
			if err != nil {
				return err
			}
			for _, u := range ups {
				fmt.Fprintln(e.Stdout, u.Path)
			}

		case "firmware":
			for _, n := range firmware.SourceNames() {
				path, err := g.Pinned(ctx, reg, n, adoptCandidates(p, legacyBase, config.Paths.ShellBuild))
				if err != nil {
					return err
				}
				fmt.Fprintln(e.Stdout, path)
			}
		}
	}
	return nil
}

// adoptCandidates is where to look for the shell tree's own download,
// in order: VMAVS_HOME's copy (at, applied to it), and, when legacyBase
// is set (the shell tree's own home, when it differs from VMAVS_HOME),
// that home's copy too -- both tried by Getter's own adoption loop, which
// verifies each candidate itself. Listing both here, rather than picking
// one by mere existence, is what stops a partial or stale copy in one
// directory from shadowing a good copy in the other. The paths
// themselves are config's (Paths.ShellESD and friends).
func adoptCandidates(p config.Paths, legacyBase string, at func(config.Paths) string) []string {
	dirs := []string{at(p)}
	if legacyBase != "" {
		dirs = append(dirs, at(config.Paths{Home: legacyBase}))
	}
	return dirs
}

// parseFetchArgs lets targets and flags appear in either order (the usage
// this command was given puts a target first: "vmavs fetch updates
// --updates none"), which flag.FlagSet.Parse does not support on its own
// -- it stops permanently at the first non-flag argument. Instead this
// parses repeatedly: fs.Parse consumes a run of flags (deciding for
// itself, the standard way, which take a value -- including "--updates
// X", "--updates=X" and "-updates X"), then the first remaining argument
// is taken as one target and parsing resumes on the rest.
//
// "--" ends flag parsing for good: fs.Parse consumes it and stops, and
// every argument after it is a plain target, never looked at as a flag
// again even if it starts with "-" (so `-- esd --probe` names an unknown
// target, "--probe"). fs.Parse stopped at a "--" when that is the last
// argument it consumed. The one look-alike is "--" given as a flag's
// value ("--updates --"), and --updates refuses that value anyway.
func parseFetchArgs(fs *flag.FlagSet, e *Env, help string, args []string) ([]string, error) {
	var targets []string
	remaining := args
	for {
		if err := parse(fs, e, help, remaining); err != nil {
			return nil, err
		}
		consumed := len(remaining) - fs.NArg()
		if consumed > 0 && remaining[consumed-1] == "--" {
			return append(targets, fs.Args()...), nil
		}
		if fs.NArg() == 0 {
			return targets, nil
		}
		targets = append(targets, fs.Arg(0))
		remaining = fs.Args()[1:]
	}
}

// fetchTargets validates args against fetchOrder and returns the
// requested targets in canonical order (esd, openssh, updates),
// regardless of the order they were named in. No args means all three.
//
// A repeated target (e.g. "esd esd") is deduplicated, not an error:
// naming the same target twice is redundant, not contradictory (unlike,
// say, two different --updates values would be), and each target already
// runs at most once regardless of how many times it appears -- there is
// nothing here worth stopping the user over.
func fetchTargets(args []string) ([]string, error) {
	if len(args) == 0 {
		return fetchOrder, nil
	}
	want := map[string]bool{}
	for _, a := range args {
		if !slices.Contains(fetchOrder, a) {
			return nil, usagef("unknown fetch target %q: choose from %s", a, strings.Join(fetchOrder, ", "))
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

// endpoints is e.Endpoints with every empty field filled with the real
// one, field by field: an Endpoints that sets only Recovery still names
// GitHub for OpenSSH explicitly, rather than leaving "" for some fetch
// type's zero value to mean the real thing (or, for the releases, to
// mean a URL with no host at all).
func endpoints(e *Env) Endpoints {
	var ep Endpoints
	if e.Endpoints != nil {
		ep = *e.Endpoints
	}
	if ep.Recovery == "" {
		ep.Recovery = fetch.DefaultRecovery
	}
	if ep.OpenSSHReleases == "" {
		ep.OpenSSHReleases = fetch.DefaultOpenSSHReleases
	}
	return ep
}
