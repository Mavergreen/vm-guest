package firmware

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	vmguest "github.com/Mavergreen/vm-guest"
	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/fetch"
	"github.com/Mavergreen/vm-guest/internal/pins"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

// Builder builds the firmware under one VMAVS_HOME. Every external
// program goes through Runner; Env is what those programs inherit
// (vmavs's own environment), to which each build adds its settings.
type Builder struct {
	Paths     config.Paths
	Registry  *pins.Registry
	Runner    proc.Runner
	Toolchain Toolchain
	Ccache    bool
	Env       []string
	Log       func(format string, a ...any)
}

// Inputs is each registry source a build reads, by name, at the path
// fetch verified it to (vmavs fetch firmware, or firmware itself).
type Inputs map[string]string

// The files and directories firmware names under build/ -- the shell
// tree's layout, so either tree can build on what the other left.
func (b *Builder) src() string          { return filepath.Join(b.Paths.Build(), "OpenCorePkg-"+OCVersion) }
func (b *Builder) udk() string          { return filepath.Join(b.src(), "UDK") }
func (b *Builder) artifactsDir() string { return filepath.Join(b.Paths.Build(), "artifacts") }
func (b *Builder) buildLog() string     { return filepath.Join(b.Paths.Build(), "opencore-build.log") }
func (b *Builder) ocvalidate() string {
	return filepath.Join(b.src(), "Utilities", "ocvalidate", "ocvalidate")
}

func (b *Builder) logf(format string, a ...any) {
	if b.Log != nil {
		b.Log(format, a...)
	}
}

// input is source name's file, re-hashed against the registry: the
// cache is read-only and was verified when filled, but a build that is
// about to spend fifteen minutes checks what it builds from, as
// build-opencore.sh's pinned_file does.
func (b *Builder) input(in Inputs, name string) (string, error) {
	p := in[name]
	if p == "" {
		return "", fmt.Errorf("no %s -- run 'vmavs fetch firmware'", name)
	}
	s, err := b.Registry.Lookup(name)
	if err != nil {
		return "", err
	}
	got, err := fetch.SHA256File(p)
	if err != nil {
		return "", err
	}
	if got != s.SHA256 {
		return "", fmt.Errorf("checksum mismatch for %s at %s: want %s, got %s", name, p, s.SHA256, got)
	}
	return p, nil
}

// requireEnv refuses a nil Env. The builds call it before anything else:
// a nil Env would hand the build tools no environment at all (not
// vmavs's own, which a nil proc.Cmd.Env would mean): no PATH, no HOME.
func (b *Builder) requireEnv() error {
	if b.Env == nil {
		return fmt.Errorf("Builder.Env is nil: pass the environment the build tools inherit")
	}
	return nil
}

// requireTools names, in one error, every tool that is not on PATH.
func (b *Builder) requireTools(names ...string) error {
	var missing []string
	for _, n := range names {
		if _, err := b.Runner.LookPath(n); err != nil {
			missing = append(missing, n)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing build tools: %s -- run 'vmavs doctor'", strings.Join(missing, ", "))
	}
	return nil
}

// buildEnv is the environment a firmware build runs in: Env, plus, when
// ccache is asked for and present, the shim directory first on PATH and
// CCACHE_DIR under build/ (never the repository: thousands of small
// files). Whether ccache was used is logged either way. The PATH it adds
// comes after Env's, and a child takes the last of a repeated variable.
func (b *Builder) buildEnv(_ context.Context) ([]string, bool, error) {
	if err := b.requireEnv(); err != nil {
		return nil, false, err
	}
	env := append([]string(nil), b.Env...)
	path, _ := b.Runner.LookPath("ccache")
	verdict, detail := CcacheVerdict(b.Ccache, path)
	switch verdict {
	case "MISSING":
		b.logf("warning: ccache: %s", detail)
		return env, false, nil
	case "OFF":
		b.logf("ccache: %s", detail)
		return env, false, nil
	}
	shims := filepath.Join(b.Paths.Build(), "ccache-bin")
	cache := filepath.Join(b.Paths.Build(), "ccache")
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return nil, false, err
	}
	if err := writeCcacheShims(shims, path, b.Runner.LookPath); err != nil {
		return nil, false, err
	}
	// No empty element: an empty PATH entry means the current directory.
	shimPath := shims
	if base := lookupEnv(b.Env, "PATH"); base != "" {
		shimPath += string(os.PathListSeparator) + base
	}
	env = append(env, "PATH="+shimPath, "CCACHE_DIR="+cache)
	b.logf("ccache: %s, cache in %s, shims in %s", path, cache, shims)
	b.logf("ccache: the build log records the real compiler (and, from phase 5, the manifest) -- a shim answers --version as what it wraps")
	return env, true, nil
}

// lookupEnv is key's value in env, the last one if it is there twice.
func lookupEnv(env []string, key string) string {
	v := ""
	for _, kv := range env {
		if k, val, ok := strings.Cut(kv, "="); ok && k == key {
			v = val
		}
	}
	return v
}

// ccacheStats logs the first lines of `ccache -s` after a build that used
// it; ccache has reorganised that output more than once, so it is shown,
// not parsed.
func (b *Builder) ccacheStats(ctx context.Context) {
	var out bytes.Buffer
	if err := b.Runner.Run(ctx, proc.Cmd{Name: "ccache", Args: []string{"-s"}, Stdout: &out}); err != nil {
		return
	}
	sc := bufio.NewScanner(&out)
	for i := 0; i < 8 && sc.Scan(); i++ {
		b.logf("ccache: %s", sc.Text())
	}
}

// runLogged runs c with its output in logPath (spec §2: stdout carries a
// command's own output, and a firmware build's is not that). On failure
// it logs the last 20 lines of the log and returns an error naming it.
func (b *Builder) runLogged(ctx context.Context, c proc.Cmd, logPath string) error {
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		return err
	}
	if fi, err := os.Lstat(logPath); err == nil && fi.Mode()&fs.ModeSymlink != 0 {
		return fmt.Errorf("%s is a symlink; refusing to write the build log through it", logPath)
	}
	lf, err := os.Create(logPath)
	if err != nil {
		return err
	}
	c.Stdout, c.Stderr = lf, lf
	runErr := b.Runner.Run(ctx, c)
	if err := lf.Close(); err != nil && runErr == nil {
		runErr = err
	}
	if runErr == nil {
		return nil
	}
	if data, err := os.ReadFile(logPath); err == nil {
		lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
		if len(lines) > 20 {
			lines = lines[len(lines)-20:]
		}
		b.logf("the last lines of %s:", logPath)
		for _, l := range lines {
			b.logf("  %s", l)
		}
	}
	return fmt.Errorf("%w (log: %s)", runErr, logPath)
}

// applyPatch applies one of the patches the binary carries (boot/patches/
// in the repository) in dir with `git apply -p1`, reading it from stdin.
func (b *Builder) applyPatch(ctx context.Context, dir, name string) error {
	patch, err := fs.ReadFile(vmguest.Files, "boot/patches/"+name)
	if err != nil {
		return err
	}
	return b.Runner.Run(ctx, proc.Cmd{Name: "git", Args: []string{"-C", dir, "apply", "-p1", "-"},
		Stdin: bytes.NewReader(patch), Stderr: logWriter{b}})
}

// logWriter sends a tool's stderr to the log, line by line.
type logWriter struct{ b *Builder }

func (w logWriter) Write(p []byte) (int, error) {
	for _, l := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		w.b.logf("  %s", l)
	}
	return len(p), nil
}

// copyAtomic copies src to dst through a temp file beside dst, synced and
// renamed, so dst is never half-written.
func copyAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	return writeAtomic(dst, 0o644, func(w io.Writer) error { _, err := io.Copy(w, in); return err })
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	return writeAtomic(path, perm, func(w io.Writer) error { _, err := w.Write(data); return err })
}

func writeAtomic(path string, perm os.FileMode, fill func(io.Writer) error) error {
	return writeAtomicFile(path, perm, func(f *os.File) error { return fill(f) })
}

// writeAtomicFile fills a temp file beside path, makes it perm, syncs,
// closes and renames it to path; on any error the temp file is removed
// and path is untouched. fill gets the file itself, for a caller that
// needs to Truncate it, write at offsets and read it back.
func writeAtomicFile(path string, perm os.FileMode, fill func(*os.File) error) error {
	tmp, err := stageFile(path, perm, fill)
	if err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// stageFile is writeAtomicFile up to the rename: the name of a temp file
// beside path, filled, made perm, synced and closed, for a caller that
// renames it into place itself (or removes it). On error nothing is left.
func stageFile(path string, perm os.FileMode, fill func(*os.File) error) (name string, err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return "", err
	}
	defer func() {
		if err != nil {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	if err = fill(tmp); err != nil {
		return "", err
	}
	if err = tmp.Chmod(perm); err != nil {
		return "", err
	}
	if err = tmp.Sync(); err != nil {
		return "", err
	}
	if err = tmp.Close(); err != nil {
		return "", err
	}
	return tmp.Name(), nil
}

// writeSums writes dir/SHA256SUMS for names, in order, as sha256sum
// prints it: "<hex>  <name>".
func writeSums(dir string, names []string) error {
	var b strings.Builder
	for _, n := range names {
		sum, err := fetch.SHA256File(filepath.Join(dir, n))
		if err != nil {
			return err
		}
		b.WriteString(sum + "  " + n + "\n")
	}
	return writeFileAtomic(filepath.Join(dir, "SHA256SUMS"), []byte(b.String()), 0o644)
}
