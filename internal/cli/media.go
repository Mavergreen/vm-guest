package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/media"
	"github.com/Mavergreen/vm-guest/internal/privops"
)

const mediaHelp = `usage: vmavs media [--autoinstall] [--firstboot-pkg PATH] [--extra-pkg PATH]...
                  [--extra-space-mib N] [--force] [--keep-work] [--describe]
                  [--privops-timeout DURATION]
       vmavs media digest [--list] IMAGE

Build the installer media: a GPT disk image with one HFS+ volume, "OS X
Base System", holding what a Mac's own installer USB stick holds --
BaseSystem, with Apple's real Packages directory, BaseSystem.dmg and its
chunklist in System/Installation -- made from Apple's InstallESD.dmg, with
no Mac and no root. It is written to $VMAVS_HOME/build/installer-media.img,
with a .sha256 sidecar beside it, and its path is printed on stdout;
progress goes to stderr. The scratch, several gigabytes of raw
conversions, goes in $VMAVS_HOME/work/media/.

The ESD is fetched and verified first, as 'vmavs fetch esd' does,
adopting the shell tree's download (media/InstallESD.dmg) where it can.
dmg2img converts it here, mkfs.hfsplus makes the empty volume, and every
read and write of an HFS+ volume happens in the privops microVM -- the
host's own kernel and a static busybox, booted under QEMU with the images
as its disks, where the build is root and the host is not -- in four
passes:

  1. copy the ESD's BaseSystem.dmg out onto a raw disk, for dmg2img;
  2. assemble the media: BaseSystem, the ESD's Packages, BaseSystem.dmg
     and its chunklist, and whatever the flags below add;
  3. restore root ownership, and the setuid and setgid bits;
  4. in a microVM of its own, read the Packages back and check them
     against Apple's pinned checksums (media/apple-packages.sha256).

NOTHING MOUNTS ON THE HOST, so no desktop seat, sudo, sgdisk or cpio is
needed: the build runs over SSH and on headless CI. The media is built as
installer-media.img.building and renamed into place only once it has
been verified, so a killed build never leaves media that looks finished.
A second build while one is running is refused, not queued.

--autoinstall adds Apple's unattended-install hooks (image/autoinstall/),
so booting the media installs without anyone watching. --firstboot-pkg
also carries that package, listed in OSInstall.collection, so the OS
installer installs it. --extra-pkg carries a package beside it WITHOUT
listing it: the first-boot payload's postinstall copies these onto the
target volume and firstboot.sh runs "installer -pkg" on them. A package
listed in the collection is installed by the OS installer itself, and
that is proven only for the payload-free script package this project
builds; the OpenSSH packages are real product archives whose
Distribution declares <allowed-os-versions min="10.9.5"/> -- a check
whose answer mid-install is not something to guess at. Either package
flag implies --autoinstall.

--describe prints the layout the build would create, and fetches, builds
and writes nothing.

vmavs media digest IMAGE prints what is ON an image as one checksum --
the sha256 of a sorted "<sha256>  <path>" list, one line per file -- which
two builds of the same ESD agree on though their images' own checksums
never will. The image is read, read-only, in the microVM. --list prints
the per-file list first.
`

// mediaBuilder is what cmdMedia needs of *media.Builder: the one seam a
// test replaces, to record what cmdMedia asked for without building.
type mediaBuilder interface {
	Build(ctx context.Context, esd string, o media.Options) (string, error)
	Describe(w io.Writer, esd string, o media.Options) error
	ContentDigest(ctx context.Context, img string, listing io.Writer) (media.Digest, error)
}

var newMediaBuilder = func(b *media.Builder) mediaBuilder { return b }

// pathList is a repeatable flag's values, in the order given.
type pathList []string

func (l *pathList) String() string { return strings.Join(*l, " ") }

func (l *pathList) Set(s string) error {
	if s == "" {
		return fmt.Errorf("wants a path")
	}
	*l = append(*l, s)
	return nil
}

// mibFlag is a whole number of MiB, in decimal digits only, as the shell
// takes it: flag.Int would read "070" as octal, and take "+5" and "0x10".
type mibFlag int

func (m *mibFlag) String() string { return strconv.Itoa(int(*m)) }

func (m *mibFlag) Set(s string) error {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return fmt.Errorf("wants a whole number of MiB, not %q", s)
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return fmt.Errorf("wants a whole number of MiB, not %q", s)
	}
	*m = mibFlag(n)
	return nil
}

func cmdMedia(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("media")
	autoinstall := fs.Bool("autoinstall", false, "add the unattended-install hooks (image/autoinstall/)")
	firstboot := fs.String("firstboot-pkg", "", "carry this package and list it in OSInstall.collection (implies --autoinstall)")
	var extras pathList
	fs.Var(&extras, "extra-pkg", "carry this package too, NOT listed in OSInstall.collection; repeatable (implies --autoinstall)")
	var space mibFlag
	fs.Var(&space, "extra-space-mib", "enlarge the HFS+ partition by N MiB beyond the reference plus margin, for extra packages (default 0)")
	force := fs.Bool("force", false, "replace existing media, once the new media is verified")
	keepWork := fs.Bool("keep-work", false, "keep the multi-gigabyte raw conversions in work/media/")
	describe := fs.Bool("describe", false, "print the layout the build would create; fetch, build and write nothing")
	timeout := fs.Duration("privops-timeout", privops.DefaultTimeout, "the bound on one microVM pass (a slow host may need more)")
	list := fs.Bool("list", false, "digest only: print the per-file list before the digest")
	targets, err := parseInterleaved(fs, e, mediaHelp, args)
	if err != nil {
		return err
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })

	if len(targets) > 0 {
		if targets[0] != "digest" {
			return usagef("unknown media action %q: the one action is digest", targets[0])
		}
		for _, n := range []string{"autoinstall", "firstboot-pkg", "extra-pkg", "extra-space-mib", "force", "keep-work", "describe", "privops-timeout"} {
			if set[n] {
				return usagef("--%s does not go with digest, which takes only --list", n)
			}
		}
		if len(targets) != 2 {
			return usagef("digest takes one IMAGE")
		}
		return mediaDigest(ctx, e, targets[1], *list)
	}
	if *list {
		return usagef("--list goes with digest only")
	}
	if set["firstboot-pkg"] && *firstboot == "" {
		return usagef("--firstboot-pkg wants a path")
	}
	if *timeout <= 0 {
		return usagef("--privops-timeout wants a positive duration, such as 30m, not %v", *timeout)
	}

	p, err := paths(e)
	if err != nil {
		return err
	}
	reg, err := registry(e)
	if err != nil {
		return err
	}
	// Autoinstall is only what was asked for: a package enabling the
	// injectables is media.Injectables.Enabled's to say.
	o := media.Options{
		Injectables:   media.Injectables{Autoinstall: *autoinstall, FirstbootPkg: *firstboot, ExtraPkgs: []string(extras)},
		ExtraSpaceMiB: int(space),
		Force:         *force,
		KeepWork:      *keepWork,
	}
	b := &media.Builder{Paths: p, Runner: runner(e), PID: pid(e), Log: func(f string, a ...any) { logf(e, "media", f, a...) }}

	if *describe {
		// Where the ESD will be, not where it is: describe fetches nothing.
		src, err := reg.Lookup(fetch.ESDSource)
		if err != nil {
			return err
		}
		fn, err := fetch.Filename(src.URL)
		if err != nil {
			return err
		}
		if err := newMediaBuilder(b).Describe(e.Stdout, p.CacheFile(src.SHA256, fn), o); err != nil {
			// Describe refuses only the options it was given.
			return usagef("%v", err)
		}
		return nil
	}

	// Before anything can fail, as fetch gives it: this command fetches.
	if hint := fetchLegacyHint(e); hint != "" {
		logf(e, "media", "%s", hint)
	}
	if b.VM, err = mediaBackend(e, *timeout); err != nil {
		return err
	}
	esd, err := installESD(ctx, e, "media", p, reg)
	if err != nil {
		return err
	}
	out, err := newMediaBuilder(b).Build(ctx, esd, o)
	// A path with an error is media in place without its sidecar: the
	// output exists, so it is printed, and the error still fails this.
	if out != "" {
		fmt.Fprintln(e.Stdout, out)
	}
	return err
}

// mediaBackend is the privops microVM on this host, bounded per pass by
// timeout.
func mediaBackend(e *Env, timeout time.Duration) (privops.Backend, error) {
	be, err := privops.NewBackend(runner(e), config.QEMU(e.Getenv), func(f string, a ...any) { logf(e, "media", f, a...) })
	if err != nil {
		return be, err
	}
	be.Timeout = timeout
	return be, nil
}

func mediaDigest(ctx context.Context, e *Env, img string, list bool) error {
	p, err := paths(e)
	if err != nil {
		return err
	}
	be, err := mediaBackend(e, privops.DefaultTimeout)
	if err != nil {
		return err
	}
	b := &media.Builder{Paths: p, Runner: runner(e), VM: be, PID: pid(e), Log: func(f string, a ...any) { logf(e, "media", f, a...) }}
	// The listing is written only once the digest is verified, so it can
	// go straight to stdout, ahead of the digest line.
	var listing io.Writer
	if list {
		listing = e.Stdout
	}
	d, err := newMediaBuilder(b).ContentDigest(ctx, img, listing)
	if err != nil {
		return err
	}
	fmt.Fprintln(e.Stdout, d.String())
	return nil
}
