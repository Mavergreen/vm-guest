package media

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/lock"
	"github.com/Mavergreen/vm-guest/internal/privops"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

const (
	// ReferencePartitionBytes is the Mac-made reference's HFS+ partition,
	// measured (7z l InstallMavericks.iso: Physical Size of its "disk
	// image.hfs"), not guessed. HFS+ must fill its partition exactly and
	// mkfs works in whole MiB, so the partition rounds it up.
	ReferencePartitionBytes = 6550020096
	// MarginMiB is added because a Linux-built copy of the same files
	// needs a larger catalog: about 153 MB of metadata here against 105
	// on the Mac, and the reference had 30 MB free. It was raised from
	// 128 to 512 on a theory about corruption that turned out false, and
	// stays because it costs nothing in a sparse image: do not cite it as
	// a fix for anything (build-installer-img.sh has the history).
	MarginMiB = 512
	// VolumeName is the media's volume, as Apple names it.
	VolumeName = "OS X Base System"
)

// BasePartMiB is the partition's size with nothing extra carried: the
// reference rounded up to whole MiB, plus the margin. --extra-space-mib 0
// must reproduce it exactly, because later builds are measured against
// media of exactly this geometry.
func BasePartMiB() int { return (ReferencePartitionBytes+1<<20-1)>>20 + MarginMiB }

// UpdatesExtraMiB is the room the update packages need on the media: the
// margin is not spare room -- it leaves about 484 MiB free, and
// --updates all is 685 MiB -- so extra cargo brings its own. It is their
// size rounded up to whole MiB, plus 64, or 0 for none
// (image/build-image.sh's updates_extra_mib).
func UpdatesExtraMiB(pkgs []string) (int, error) {
	if len(pkgs) == 0 {
		return 0, nil
	}
	var total int64
	for _, p := range pkgs {
		fi, err := os.Stat(p)
		if err != nil {
			return 0, err
		}
		total += fi.Size()
	}
	return int((total+1<<20-1)>>20) + 64, nil
}

// MicroVM runs a payload as uid 0 with target and disks attached, and
// returns its console. privops.Backend is one; tests fake it.
type MicroVM interface {
	Run(ctx context.Context, target string, payload []byte, disks []privops.Disk) ([]byte, error)
	Missing() []string
}

var _ MicroVM = privops.Backend{}

// Options is one media build's choices.
type Options struct {
	Injectables
	ExtraSpaceMiB int  // enlarges the partition beyond BasePartMiB
	Force         bool // replaces existing media
	KeepWork      bool // keeps the multi-gigabyte raw conversions
}

// Builder builds installer media from InstallESD.dmg. Every program runs
// through Runner, and every read or write of an HFS+ volume's contents
// happens inside VM: NOTHING HERE MOUNTS ANYTHING, because a host mount
// needs a desktop seat (udisks2's polkit refuses loop-setup over SSH), so
// a headless host -- every CI runner -- could not build media at all.
type Builder struct {
	Paths  config.Paths
	Runner proc.Runner
	VM     MicroVM
	PID    int // the lock's holder; 0 is os.Getpid()
	Log    func(string, ...any)

	baseMiB int // tests only: the partition before ExtraSpaceMiB, when not BasePartMiB
	// afterMediaRename, tests only, runs once the media is in place.
	afterMediaRename func()
}

func (b *Builder) logf(f string, a ...any) {
	if b.Log != nil {
		b.Log(f, a...)
	}
}

func (b *Builder) partMiB(o Options) int {
	base := b.baseMiB
	if base == 0 {
		base = BasePartMiB()
	}
	return base + o.ExtraSpaceMiB
}

// The media build's scratch, in Paths.MediaWork(). Ours alone: they are
// removed before a build and, unless KeepWork, after it.
const (
	workESD     = "esd.img"
	workBSDmg   = "basesystem.dmg" // the raw disk BaseSystem.dmg comes out on
	workBSImg   = "basesystem.img"
	workTar     = "inject.tar" // the raw disk the injectables go in on
	workConsole = "console.txt"
)

var workFiles = []string{workESD, workBSDmg, workBSImg, workTar, workConsole}

// Describe prints the layout Build would create. It touches nothing, and
// refuses what Build would refuse before it, as the shell validates
// --extra-space-mib before --describe.
func (b *Builder) Describe(w io.Writer, esd string, o Options) error {
	if err := checkSpace(o); err != nil {
		return err
	}
	part := b.partMiB(o)
	fmt.Fprintf(w, `installer media layout
  output              %s
  source              %s
  work area           %s

  partition table     GPT, one partition
  partition 1 type    AF00 (Apple HFS+)
  partition 1 start   sector 2048 (1 MiB)
  partition 1 size    %d MiB = %d bytes
                      (the reference's is %d bytes,
                      rounded up to whole MiB -- HFS+ must fill its
                      partition exactly -- plus a %d MiB margin
                      for the larger catalog a Linux-built copy needs,
                      plus %d MiB of --extra-space-mib)
  disk size           %d MiB = %d bytes
  volume name         %s

  contents
    everything in the ESD's BaseSystem.dmg, then
    System/Installation/Packages/     <- the ESD's real Packages directory,
                                        replacing a symlink that dangles
                                        once the ESD volume is gone
    System/Installation/BaseSystem.dmg
    System/Installation/BaseSystem.chunklist
`, b.Paths.InstallerMedia(), esd, b.Paths.MediaWork(),
		part, int64(part)<<20, ReferencePartitionBytes, MarginMiB, o.ExtraSpaceMiB,
		part+2, int64(part+2)<<20, VolumeName)
	if !o.Enabled() {
		return nil
	}
	fmt.Fprint(w, "\n  unattended-install hooks (--autoinstall)\n")
	for _, f := range AutoinstallFiles {
		fmt.Fprintf(w, "    %-46s mode %o\n", f.Dest, f.Mode)
		fmt.Fprintf(w, "      from image/autoinstall/%s\n", f.Source)
	}
	fmt.Fprint(w, `
    All three are read by Apple's own /etc/rc.install, which is already on
    this media. They land root-owned like everything else, via the privops
    microVM -- launchd and the installer both refuse what they do not
    trust.
`)
	if o.FirstbootPkg != "" {
		fmt.Fprintf(w, `
  first-boot payload (--firstboot-pkg)
    System/Installation/Packages/%s
      from %s
    ...and one more entry in OSInstall.collection naming it, so Apple's
    installer installs the payload during the install rather than anything
    being injected into a finished volume afterwards. See image/payload/.
`, FirstbootPkgName, o.FirstbootPkg)
	}
	if len(o.ExtraPkgs) > 0 {
		fmt.Fprint(w, "\n  extra packages (--extra-pkg), carried but NOT in OSInstall.collection\n")
		for _, e := range o.ExtraPkgs {
			fmt.Fprintf(w, "    System/Installation/Packages/%s\n      from %s\n", filepath.Base(e), e)
		}
		fmt.Fprint(w, `    The first-boot payload's postinstall copies these to the target volume;
    firstboot.sh installs them with "installer -pkg ... -target /" on the
    installed system, where a product archive's version checks and scripts
    run against a real booted OS.
`)
	}
	return nil
}

func checkSpace(o Options) error {
	if o.ExtraSpaceMiB < 0 {
		return fmt.Errorf("--extra-space-mib wants a whole number of MiB, not %d", o.ExtraSpaceMiB)
	}
	return nil
}

// sidecarTempPrefix is the name, within build/, of a sidecar this
// package stages before renaming it into place: any file with it is one
// a killed build left.
func sidecarTempPrefix(out string) string { return "." + filepath.Base(out) + ".sha256.tmp-" }

// Build makes the installer media from esd and returns its path,
// Paths.InstallerMedia(), with a .sha256 sidecar beside it:
//
//  1. dmg2img the ESD.
//  2. Create a GPT image with one AF00 partition holding an "OS X Base
//     System" volume, sized from the reference.
//  3. microVM pass 1: copy the ESD's BaseSystem.dmg onto a raw disk,
//     since dmg2img runs here and cannot read an HFS+ volume; dmg2img it.
//  4. Pass 2: copy BaseSystem onto the media, replace its dangling
//     Packages symlink with the ESD's real Packages, add BaseSystem.dmg
//     and its chunklist, and untar the injectables.
//  5. Pass 3: restore root ownership.
//  6. Pass 4, in a microVM of its own: read the Packages back and check
//     them against Apple's pinned checksums.
//
// Four boots rather than one, at about four seconds each: the price of a
// host that needs no desktop seat. The image is built as
// InstallerMedia()+".building" and renamed into place only once it is
// verified, so a killed build never leaves media that looks finished.
func (b *Builder) Build(ctx context.Context, esd string, o Options) (_ string, err error) {
	started := time.Now()
	out := b.Paths.InstallerMedia()
	if err := checkSpace(o); err != nil {
		return "", err
	}
	// Asked before five gigabytes of dmg2img, not when the microVM is
	// first needed: a host that cannot boot it should find out in a
	// second and by name, not after twenty minutes of wasted work.
	if m := b.VM.Missing(); len(m) > 0 {
		for _, l := range m {
			b.logf("  missing: %s", l)
		}
		return "", fmt.Errorf("the privops microVM is not available on this host, and it is how the media is built at all -- nothing here installs anything; see vmavs doctor. Missing: %s", strings.Join(m, "; "))
	}
	for _, tool := range []string{"dmg2img", "mkfs.hfsplus"} {
		if _, err := b.Runner.LookPath(tool); err != nil {
			return "", fmt.Errorf("the media build needs %s (not on PATH)", tool)
		}
	}
	if !regularFile(esd) {
		return "", fmt.Errorf("no InstallESD.dmg at %s -- run vmavs fetch esd", esd)
	}
	// Packages are checked now, not when they are copied: a missing one
	// should cost a second, not twenty minutes.
	if o.FirstbootPkg != "" {
		if !regularFile(o.FirstbootPkg) {
			return "", fmt.Errorf("no first-boot package at %s -- build one with image/payload/build-firstboot-pkg.sh", o.FirstbootPkg)
		}
		if err := xarMagic(o.FirstbootPkg); err != nil {
			return "", err
		}
	}
	for _, e := range o.ExtraPkgs {
		if !regularFile(e) {
			return "", fmt.Errorf("no such --extra-pkg: %s", e)
		}
		if err := xarMagic(e); err != nil {
			return "", err
		}
	}
	if _, err := o.packages(); err != nil {
		return "", err
	}

	// ONE BUILDER PER IMAGE FILE. Two builders writing one image each
	// read back their own page cache and see nothing wrong, while the
	// file on disk is a mix of both: the one mechanism of media
	// corruption ever caught in the act.
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return "", err
	}
	pid := b.PID
	if pid == 0 {
		pid = os.Getpid() // a lock naming pid 0 names nobody, and is stale to everyone
	}
	l, err := lock.Acquire(out+".lock", pid)
	if err != nil {
		return "", err
	}
	switch {
	case l.TookOver > 0:
		b.logf("taking over a stale lock left by pid %d", l.TookOver)
	case l.TookOver < 0:
		b.logf("taking over a stale lock left by an unknown pid")
	}
	defer func() {
		if rerr := l.Release(); err == nil && rerr != nil {
			err = rerr
		}
	}()

	if _, serr := os.Lstat(out); serr == nil {
		if !o.Force {
			return "", fmt.Errorf("%s exists; pass --force to replace it", out)
		}
		// Kept until the new media is verified, and then replaced by one
		// rename: a forced build that fails leaves what was there.
		b.logf("--force: %s will be replaced once the new media is verified", out)
	}

	work := b.Paths.MediaWork()
	if err := os.MkdirAll(work, 0o755); err != nil {
		return "", err
	}
	// Regenerated every run, never reused: they cost seconds, next to a
	// stale or half-written one silently becoming media that then costs
	// an hour of booting. The .building file is only ever a killed build.
	building := out + ".building"
	stale, err := filepath.Glob(filepath.Join(filepath.Dir(out), sidecarTempPrefix(out)+"*"))
	if err != nil {
		return "", err
	}
	for _, p := range append(append(wp(work, workFiles...), building, building+".hfs-tmp"), stale...) {
		if rerr := os.Remove(p); rerr != nil && !errors.Is(rerr, fs.ErrNotExist) {
			return "", rerr
		}
	}
	defer func() {
		if err != nil {
			os.Remove(building)
		}
	}()

	sum, err := b.build(ctx, esd, o, work, building)
	if err != nil {
		return "", err
	}

	// The sidecar carries its expiry: mounting HFS+ read-write rewrites
	// the volume header, so the first mount after this -- a microVM, a
	// guest booting the media -- changes the file. That is the media, not
	// corruption. (sha256sum -c ignores the # lines.)
	side, err := os.CreateTemp(filepath.Dir(out), sidecarTempPrefix(out)+"*")
	if err != nil {
		return "", err
	}
	defer os.Remove(side.Name())
	_, err = fmt.Fprintf(side, "# sha256 of %s as built at %s\n"+
		"# Mounting the image invalidates this: HFS+ records the mount\n"+
		"# in its volume header, and a read-write mount rewrites it.\n"+
		"%s  %s\n", filepath.Base(out), time.Now().UTC().Format("2006-01-02T15:04:05Z"), sum, filepath.Base(out))
	if err == nil {
		err = side.Sync()
	}
	if cerr := side.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(side.Name(), 0o644)
	}
	if err != nil {
		return "", err
	}
	// The old sidecar goes first, so that no sidecar ever describes an
	// image it was not written for; the rename then replaces any old
	// media in one step.
	if err := os.Remove(out + ".sha256"); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	if err := os.Rename(building, out); err != nil {
		return "", err
	}
	if b.afterMediaRename != nil {
		b.afterMediaRename()
	}
	if err := os.Rename(side.Name(), out+".sha256"); err != nil {
		return out, fmt.Errorf("%s is in place, but its sidecar is missing: %w -- its sha256 is %s", out, err, sum)
	}

	// The media is built and in place: nothing after this can fail the
	// build, only warn.
	if !o.KeepWork {
		b.logf("removing the raw conversions (--keep-work keeps them)")
		for _, p := range wp(work, workFiles...) {
			if rerr := os.Remove(p); rerr != nil && !errors.Is(rerr, fs.ErrNotExist) {
				b.logf("warning: cannot remove %s: %v", p, rerr)
			}
		}
		os.Remove(work) // only if empty: what else is there is not ours
	}
	b.logf("built %s in %s", out, time.Since(started).Round(time.Second))
	if fi, serr := os.Stat(out); serr != nil {
		b.logf("warning: cannot read %s back: %v", out, serr)
	} else {
		b.logf("size %d bytes, sha256 %s", fi.Size(), sum)
	}
	return out, nil
}

// build is the build proper, into building, and returns its sha256.
func (b *Builder) build(ctx context.Context, esd string, o Options, work, building string) (string, error) {
	esdImg, bsDmg, bsImg, tarPath := filepath.Join(work, workESD), filepath.Join(work, workBSDmg),
		filepath.Join(work, workBSImg), filepath.Join(work, workTar)

	b.logf("converting InstallESD.dmg to raw (about 5 GB)")
	if err := b.dmg2img(ctx, esd, esdImg); err != nil {
		return "", fmt.Errorf("dmg2img failed on %s: %w", esd, err)
	}
	esdSize, err := fileSize(esdImg)
	if err != nil {
		return "", err
	}
	b.logf("ESD raw image: %d bytes", esdSize)

	// Created before anything is copied: pass 1 needs a target, since the
	// backend always mounts its first disk, and an empty volume will do.
	part := b.partMiB(o)
	b.logf("creating %s: GPT, one AF00 partition, %d MiB, %q", building, part, VolumeName)
	if err := CreateHFSGPT(ctx, b.Runner, building, part, VolumeName); err != nil {
		return "", err
	}

	// Pass 1. BaseSystem.dmg is inside the ESD volume, UDIF-compressed:
	// only dmg2img decodes it, and dmg2img runs here, which cannot read
	// the ESD. So the guest writes it to a raw disk -- a plain file here,
	// sparse and as large as the ESD image, which costs nothing unwritten.
	b.logf("bringing BaseSystem.dmg out of the ESD (microVM pass 1 of 4)")
	if err := truncateNew(bsDmg, esdSize); err != nil {
		return "", err
	}
	console, err := b.pass(ctx, 1, "extract-basesystem", building, work,
		privops.Disk{Role: "ro", Path: esdImg}, privops.Disk{Role: "raw", Path: bsDmg})
	if err != nil {
		return "", err
	}
	n, ok := count(one(console, "MQG-BASESYSTEM-BYTES"))
	if !ok {
		return "", errors.New("the microVM did not report a BaseSystem.dmg size")
	}
	if err := os.Truncate(bsDmg, n); err != nil {
		return "", err
	}
	// The host's own read, against the digest the guest sent: a short or
	// torn write through the raw disk would otherwise surface as a
	// dmg2img failure that says nothing about where the bytes went.
	want := one(console, "MQG-BASESYSTEM-SHA256")
	got, err := fetch.SHA256File(bsDmg)
	if err != nil {
		return "", err
	}
	if got != want {
		return "", fmt.Errorf("BaseSystem.dmg did not survive the trip out of the microVM: the guest read %s and this host reads %s", want, got)
	}
	b.logf("BaseSystem.dmg: %d bytes, sha256 %s", n, got)

	b.logf("converting BaseSystem.dmg to raw")
	if err := b.dmg2img(ctx, bsDmg, bsImg); err != nil {
		return "", fmt.Errorf("dmg2img failed on BaseSystem.dmg: %w", err)
	}
	if n, err := fileSize(bsImg); err == nil {
		b.logf("BaseSystem raw image: %d bytes", n)
	}

	// Pass 2. The injectables go in as a tar on a raw disk -- the channel
	// BaseSystem.dmg came out on, run the other way -- and are untarred
	// BEFORE the ownership pass: anything injected after the chown would
	// be the one uid-1000 file on root-owned media, which launchd skips as
	// "Dubious ownership".
	disks := []privops.Disk{{Role: "ro", Path: bsImg}, {Role: "ro", Path: esdImg}}
	if o.Enabled() {
		if err := b.stageInjectables(o.Injectables, tarPath); err != nil {
			return "", err
		}
		disks = append(disks, privops.Disk{Role: "raw", Path: tarPath})
	}
	b.logf("assembling the media inside the microVM (pass 2 of 4)")
	if console, err = b.pass(ctx, 2, "assemble", building, work, disks...); err != nil {
		return "", err
	}
	// Checked against a constant, not against the source: a bad byte out
	// of dmg2img would be copied faithfully and verified as correct.
	if err := b.checkSums(console, "MQG-SUM-ESD", "the ESD's Packages, as converted and read",
		"the ESD does not contain what Apple shipped. The suspects are dmg2img and the Linux hfsplus read of its output, in that order -- not the media, whose copy of them has not been checked yet, and not media/apple-packages.sha256, whose values were read from two images that share no code"); err != nil {
		return "", err
	}

	if err := syncFile(building); err != nil {
		return "", err
	}
	b.logf("restoring root ownership (microVM pass 3 of 4)")
	if _, err := b.pass(ctx, 3, "fix-ownership", building, work); err != nil {
		return "", err
	}

	// Pass 4, in a microVM of its own, booted after the writing one
	// exited: a fresh kernel with no page cache, pulling every byte off
	// this host's file. A check through the cache that did the writing
	// once passed media that was corrupt.
	b.logf("reading the finished media back in a microVM of its own (pass 4 of 4)")
	if console, err = b.pass(ctx, 4, "verify-packages", building, work); err != nil {
		return "", err
	}
	if err := b.checkSums(console, "MQG-SUM-MEDIA", "the finished media, read by a fresh guest",
		"the media does not contain what Apple shipped. This is the fault that a finished copy, and a read-back through the same cache, both fail to report. Re-run with --force"); err != nil {
		return "", err
	}

	// After the ownership pass, not before: the microVM mounts the image,
	// and mounting HFS+ rewrites its header.
	b.logf("checksumming %s", building)
	return fetch.SHA256File(building)
}

// pass runs one embedded payload in the microVM, keeping its console in
// the work area for whoever has to find out what went wrong.
func (b *Builder) pass(ctx context.Context, n int, name, target, work string, disks ...privops.Disk) ([]byte, error) {
	payload, err := fs.ReadFile(vmguest.Files, "media/privops/"+name+".sh")
	if err != nil {
		return nil, err
	}
	console, err := b.VM.Run(ctx, target, payload, disks)
	if console != nil {
		if werr := os.WriteFile(filepath.Join(work, workConsole), console, 0o644); werr != nil && err == nil {
			err = werr
		}
	}
	if err != nil {
		return console, fmt.Errorf("pass %d (%s): %w", n, name, err)
	}
	return console, nil
}

// checkSums holds a pass's checksum markers against Apple's pinned
// values, logging each package that is missing or wrong.
func (b *Builder) checkSums(console []byte, marker, what, fault string) error {
	b.logf("checking %s against Apple's pinned checksums", what)
	sums := strings.Join(privops.Markers(console, marker), "\n")
	problems, err := CheckAppleSums([]byte(sums))
	if err == nil {
		return nil
	}
	for _, p := range problems {
		b.logf("    %s", p)
	}
	return fmt.Errorf("%s (%w)", fault, err)
}

func (b *Builder) dmg2img(ctx context.Context, in, out string) error {
	var stderr bytes.Buffer
	if err := b.Runner.Run(ctx, proc.Cmd{Name: "dmg2img", Args: []string{"-s", "-i", in, "-o", out}, Stderr: &stderr}); err != nil {
		return fmt.Errorf("%w%s", err, detail(stderr.String()))
	}
	return nil
}

// stageInjectables writes the injectables' tar where pass 2 gets it.
func (b *Builder) stageInjectables(in Injectables, path string) error {
	b.logf("injecting the unattended-install hooks")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	err = in.WriteTar(f, b.Log)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return fmt.Errorf("cannot build %s: %w", path, err)
	}
	if n, err := fileSize(path); err == nil {
		b.logf("staged %d bytes of files to inject", n)
	}
	return nil
}

// one is a marker's value when the console printed it exactly once, as
// the shell's $(console_marker ...) reads it: two values are not a number
// or a checksum.
func one(console []byte, name string) string {
	if v := privops.Markers(console, name); len(v) == 1 {
		return v[0]
	}
	return ""
}

// count is a non-negative decimal, as the shell's case pattern accepts
// one: not empty, and all digits -- no sign, no space.
func count(s string) (int64, bool) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

// xarMagic refuses a file that does not begin "xar!": a flat package is
// a xar archive, and anything else fails the install much later.
func xarMagic(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var magic [4]byte
	if _, err := io.ReadFull(f, magic[:]); err != nil || string(magic[:]) != "xar!" {
		return fmt.Errorf("%s is not a flat package (no xar magic)", path)
	}
	return nil
}

// regularFile is the shell's [ -f "$path" ].
func regularFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func fileSize(p string) (int64, error) {
	fi, err := os.Stat(p)
	if err != nil {
		return 0, err
	}
	return fi.Size(), nil
}

// truncateNew creates path as a sparse file of size bytes.
func truncateNew(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	err = f.Truncate(size)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// syncFile is the shell's sync between the passes, for the one file that
// matters: what pass 2 wrote is on the disk before pass 3 boots.
func syncFile(p string) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	err = f.Sync()
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// wp is names, in dir.
func wp(dir string, names ...string) []string {
	var p []string
	for _, n := range names {
		p = append(p, filepath.Join(dir, n))
	}
	return p
}
