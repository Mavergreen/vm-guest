package cli

import (
	"context"
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
	targetArgs, err := parseInterleaved(fs, e, fetchHelp, args)
	if err != nil {
		return err
	}
	targets, err := orderedTargets("fetch", targetArgs, fetchOrder)
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
	reg, err := registry(e)
	if err != nil {
		return err
	}
	ep := endpoints(e)
	legacy := legacyBase(e, p)

	client := httpClient(e)
	logFetch := func(format string, a ...any) { logf(e, "fetch", format, a...) }
	if *probe {
		rc := fetch.Recovery{Base: ep.Recovery, Client: client, Log: logFetch}
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
			path, err := installESD(ctx, e, "fetch", p, reg)
			if err != nil {
				return err
			}
			fmt.Fprintln(e.Stdout, path)

		case "openssh":
			tag, err := fetch.OpenSSHTag()
			if err != nil {
				return err
			}
			pkgs, err := g.OpenSSH(ctx, ep.OpenSSHReleases, tag, adoptCandidates(p, legacy, func(q config.Paths) string { return q.ShellOpenSSH(tag) }))
			if err != nil {
				return err
			}
			fmt.Fprintln(e.Stdout, pkgs.Base)
			fmt.Fprintln(e.Stdout, pkgs.Replace)

		case "updates":
			ups, err := g.Updates(ctx, reg, *updates, adoptCandidates(p, legacy, config.Paths.ShellUpdates))
			if err != nil {
				return err
			}
			for _, u := range ups {
				fmt.Fprintln(e.Stdout, u.Path)
			}

		case "firmware":
			for _, n := range firmware.SourceNames() {
				path, err := g.Pinned(ctx, reg, n, adoptCandidates(p, legacy, config.Paths.ShellBuild))
				if err != nil {
					return err
				}
				fmt.Fprintln(e.Stdout, path)
			}
		}
	}
	return nil
}

// installESD fetches and verifies InstallESD.dmg as cmd, adopting the
// shell tree's download where it can, and returns its path: vmavs fetch
// esd, and every command that needs the ESD (vmavs media).
func installESD(ctx context.Context, e *Env, cmd string, p config.Paths, reg *pins.Registry) (string, error) {
	client := httpClient(e)
	log := func(format string, a ...any) { logf(e, cmd, format, a...) }
	g := &fetch.Getter{Paths: p, Client: client, Log: log}
	rc := fetch.Recovery{Base: endpoints(e).Recovery, Client: client, Log: log}
	return g.InstallESD(ctx, reg, rc, adoptCandidates(p, legacyBase(e, p), config.Paths.ShellESD))
}

// adoptCandidates is where to look for the shell tree's own download,
// in order: VMAVS_HOME's copy (at, applied to it), and, when legacy
// is set (the shell tree's own home, when it differs from VMAVS_HOME),
// that home's copy too -- both tried by Getter's own adoption loop, which
// verifies each candidate itself. Listing both here, rather than picking
// one by mere existence, is what stops a partial or stale copy in one
// directory from shadowing a good copy in the other. The paths
// themselves are config's (Paths.ShellESD and friends).
func adoptCandidates(p config.Paths, legacy string, at func(config.Paths) string) []string {
	dirs := []string{at(p)}
	if legacy != "" {
		dirs = append(dirs, at(config.Paths{Home: legacy}))
	}
	return dirs
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
