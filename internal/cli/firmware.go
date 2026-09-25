package cli

import (
	"context"
	"flag"
	"fmt"
	"strings"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/firmware"
	"github.com/Mavergreen/vm-guest/internal/pins"
)

const firmwareHelp = `usage: vmavs firmware [opencore|ovmf|efi ...] [--smbios MODEL] [--ccache] [--compiler 'NAME VERSION']

Build what the guest boots before its kernel, from pinned source, under
$VMAVS_HOME/build:

  opencore  OpenCore 1.0.7, built with upstream's build_oc.tool against
            acidanthera's EDK II (audk) at its pinned commit
            -> build/artifacts/*.efi
  ovmf      the guest's UEFI firmware, from the same EDK II tree
            -> build/firmware/OVMF_CODE.fd, OVMF_VARS.fd, OVMF.fd
  efi       the OpenCore EFI image: the artifacts, the Lilu and
            VirtualSMC kexts and config.plist on a FAT32 EFI System
            Partition -> build/opencore.img

With no target, all three, in that order. Each output's path is printed
on stdout; progress goes to stderr, and each build's own output to a log
file under build/ named when it starts.

The sources are fetched and verified first, as 'vmavs fetch firmware'
does, adopting the shell tree's downloads where it can; the builds
themselves reach no network. A build tree the shell tree made is built
on, not replaced.

The firmware is reproducible per compiler, not across compilers
(docs/decisions/0004). The host's gcc is judged against the range this
project has evidence for: below it the build stops, above it or unknown
it warns and carries on.
`

// firmwareOrder is the order the targets build in.
var firmwareOrder = []string{"opencore", "ovmf", "efi"}

// firmwareBuilder is what cmdFirmware needs of *firmware.Builder: the one
// seam a test replaces, to record what cmdFirmware asked for without
// running a real build.
type firmwareBuilder interface {
	OpenCore(ctx context.Context, in firmware.Inputs) ([]string, error)
	OVMF(ctx context.Context) ([]string, error)
	Kexts(ctx context.Context, in firmware.Inputs) ([]string, error)
	EFIImage(ctx context.Context, model string) (string, error)
}

var newFirmwareBuilder = func(b *firmware.Builder) firmwareBuilder { return b }

func cmdFirmware(ctx context.Context, e *Env, args []string) error {
	fs := newFlags("firmware")
	smbios := fs.String("smbios", firmware.DefaultSMBIOS, "the guest's SMBIOS model (SystemProductName); see lib/smbios.sh for what each has been measured to do")
	ccache := fs.Bool("ccache", firmware.CcacheDefault, "compile through ccache, if it is installed (off by default: not yet shown to give the same bytes)")
	compiler := fs.String("compiler", "", "treat the host compiler as 'NAME VERSION' for the range check (the build log records the real one, and, from phase 5, the manifest)")
	targetArgs, err := parseInterleaved(fs, e, firmwareHelp, args)
	if err != nil {
		return err
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if set["compiler"] && strings.TrimSpace(*compiler) == "" {
		return usagef("--compiler needs a value, e.g. --compiler 'gcc 15.1.0'")
	}
	if !firmware.SMBIOSWellformed(*smbios) {
		return usagef("--smbios %q is not a usable SMBIOS model identifier (letters, digits, comma, dot, dash, underscore; 64 at most)", *smbios)
	}
	targets, err := orderedTargets("firmware", targetArgs, firmwareOrder)
	if err != nil {
		return err
	}

	p, err := paths(e)
	if err != nil {
		return err
	}
	// Before anything can fail, as fetch gives it: this command fetches
	// too, so the user whose images are in the shell tree's home hears
	// where they are whether the build works or not.
	if hint := fetchLegacyHint(e); hint != "" {
		logf(e, "firmware", "%s", hint)
	}
	reg := e.Registry
	if reg == nil {
		if reg, err = pins.Embedded(); err != nil {
			return err
		}
	}
	logFW := func(format string, a ...any) { logf(e, "firmware", format, a...) }
	b := &firmware.Builder{
		Paths:     p,
		Registry:  reg,
		Runner:    runner(e),
		Toolchain: firmware.Toolchain{Runner: runner(e), GCCBin: e.Getenv("GCC_BIN"), Override: *compiler},
		Ccache:    *ccache,
		Env:       environ(e),
		Log:       logFW,
	}
	fb := newFirmwareBuilder(b)

	// Fetch what the named targets read, before building anything.
	var names []string
	for _, t := range targets {
		switch t {
		case "opencore":
			names = append(names, firmware.OpenCoreSources()...)
		case "efi":
			names = append(names, firmware.KextSources()...)
		}
	}
	in := firmware.Inputs{}
	if len(names) > 0 {
		g := &fetch.Getter{Paths: p, Client: httpClient(e), Log: func(f string, a ...any) { logf(e, "firmware", f, a...) }}
		legacyBase := ""
		if legacy := config.LegacyHome(e.Getenv); legacy != "" && legacy != p.Home {
			legacyBase = legacy
		}
		for _, n := range names {
			path, err := g.Pinned(ctx, reg, n, adoptCandidates(p, legacyBase, config.Paths.ShellBuild))
			if err != nil {
				return err
			}
			in[n] = path
		}
	}

	for _, t := range targets {
		var out []string
		switch t {
		case "opencore":
			out, err = fb.OpenCore(ctx, in)
		case "ovmf":
			out, err = fb.OVMF(ctx)
		case "efi":
			if out, err = fb.Kexts(ctx, in); err == nil {
				var img string
				img, err = fb.EFIImage(ctx, *smbios)
				out = append(out, img)
			}
		}
		if err != nil {
			return err
		}
		for _, o := range out {
			fmt.Fprintln(e.Stdout, o)
		}
	}
	return nil
}
