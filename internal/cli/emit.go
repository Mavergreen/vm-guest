package cli

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/crypto/ssh"

	"github.com/Mavergreen/vm-guest/internal/config"
	"github.com/Mavergreen/vm-guest/internal/emit"
	"github.com/Mavergreen/vm-guest/internal/proc"
)

const emitHelp = `usage: vmavs emit packer [--out FILE] [--check] [machine options]

Write a Packer template (HCL2) that installs the same machine vmavs
installs and boots, for QEMU, with a local-only Vagrant box as its output.
It names local paths as variables and contains no Apple software.

--check runs packer validate on the result, with placeholder variables and
a throwaway key. It needs packer on PATH and the template's plugins
installed first (packer init FILE), which downloads them; vmavs will not.
`

func cmdEmit(ctx context.Context, e *Env, args []string) error {
	if len(args) == 0 || (args[0] != "packer" && args[0] != "-h" && args[0] != "--help") {
		return usagef("usage: vmavs emit packer [options] (the only target today is packer)")
	}
	if args[0] == "packer" {
		args = args[1:]
	}
	fs := newFlags("emit")
	hw := config.DefaultMachine()
	registerMachine(fs, &hw)
	out := fs.String("out", "", "write the template here (default: stdout)")
	check := fs.Bool("check", false, "run packer validate on --out afterwards")
	if err := parse(fs, e, emitHelp, args); err != nil {
		return err
	}
	if *check && *out == "" {
		return usagef("--check needs --out: there is nothing to validate on stdout")
	}
	src, err := emit.Packer(hw, config.DefaultDiskGB)
	if err != nil {
		return usagef("%v", err)
	}
	if *out == "" {
		_, err = e.Stdout.Write(src)
		return err
	}
	if err := os.WriteFile(*out, src, 0o644); err != nil {
		return err
	}
	logf(e, "emit", "wrote %s", *out)
	if !*check {
		return nil
	}
	return packerValidate(ctx, e, runner(e), *out)
}

// packerValidate gives every variable a placeholder and ssh_key a real,
// throwaway key: validate refuses unset variables, and the qemu plugin
// parses ssh_private_key_file (MEASURED, Packer 1.16.1).
func packerValidate(ctx context.Context, e *Env, r proc.Runner, file string) error {
	packer, err := r.LookPath("packer")
	if err != nil {
		return errors.New("packer is not installed or not on PATH; CI validates every push (.github/workflows/ci.yml)")
	}
	dir, err := os.MkdirTemp("", "vmavs-emit-check-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	block, err := ssh.MarshalPrivateKey(priv, "vmavs emit packer --check placeholder")
	if err != nil {
		return err
	}
	key := filepath.Join(dir, "key")
	if err := os.WriteFile(key, pem.EncodeToMemory(block), 0o600); err != nil {
		return err
	}
	args := []string{"validate"}
	for _, v := range emit.Variables {
		val := "/nonexistent/vmavs-check-placeholder/" + v.Name
		if v.Name == "ssh_key" {
			val = key
		}
		args = append(args, "-var", v.Name+"="+val)
	}
	args = append(args, file)
	if err := r.Run(ctx, proc.Cmd{Name: packer, Args: args, Stdout: e.Stderr, Stderr: e.Stderr}); err != nil {
		return fmt.Errorf("%w; if it names a missing plugin, run `packer init %s` first", err, file)
	}
	logf(e, "emit", "packer validate: OK (placeholder variables: the template parses; no build has run)")
	return nil
}
