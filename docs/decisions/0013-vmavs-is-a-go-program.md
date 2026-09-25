# 0013 — `vmavs` is one Go program, not a shell dispatcher

Date: 2026-09-24
Status: accepted

`decisions/0007` said *"Shell is the right language: the work is
orchestrating `qemu`, `hdiutil`, `mkfs`, `xar` — process-spawning glue —
and it is already written."* This ADR reverses that sentence and nothing
else in 0007. The subcommands, the 10.9 target and the never-publish rule
all stand.

## What changed

Two things, both after 0007 was written.

**First, the shape of the product.** The shipping plan built `vmavs` as a
dispatcher over the existing scripts, deliberately, to keep the scripts
where they were. That produced a working command whose seams show:

- the usage lines name other scripts;
- flags differ from subcommand to subcommand;
- `run` boots development profiles instead of the image `vmavs image`
  built.

The user asked for one integrated, consistent tool instead. That makes
this a rewrite of the structure either way, and at that point the language
is a choice again, not a sunk cost.

**Second, evidence about shell in this codebase.** In a single session:

- the release gate (`bin/no-apple-bytes.sh`) was found to ignore its ref
  argument;
- its magic-byte check skipped any file over about 64 KiB, because of
  `pipefail` and SIGPIPE;
- its file-name checks missed any name git C-quotes;
- `emit packer` exited 0 with a silently wrong template, because a `die`
  inside process substitution never reached the caller.

These are not one-off typos. They are the hazards the language invites, in
exactly the code whose job is to fail closed.

## Decision

**`vmavs` is a single Go binary**, built from `cmd/vmavs` and `internal/`,
with its data and guest-side scripts embedded. The design is in
`docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`.

**Go, and not C,** because this app's work is:

- HTTPS with checksum pinning;
- archives: zip, tar, cpio, xar;
- SSH;
- GPT and FAT images;
- process supervision with timeouts;
- a great deal of string handling.

Go's standard library, plus `x/crypto`, covers all of it with its own TLS
stack. C would need libcurl or OpenSSL (10.9's system TLS is dated),
libarchive and libssh2 on three operating systems, and would parse
downloaded bytes without memory safety.

## What it costs

- **A port of about 15,000 lines of shell and 700 bats tests.** It is done
  in phases, with the shell tree kept as the reference until a Go test
  proves each behavior.
- **Every MEASURED claim about the pipeline is a claim about the shell
  code.** Nothing carries over until the Go binary has built, booted and
  answered SSH on a KVM host.
- **Development needs a Go toolchain.** Users do not: they get one binary.

## Why 0007's reasons no longer decide it

- **"It is already written."** True, and it stays as the reference. But a
  restructure was coming regardless, so the sunk cost is no longer an
  argument for the language.
- **"Process-spawning glue."** Much of what was glue — `curl`, `openssl`,
  `xxd`, `unzip`, `zip`, `sgdisk`, mtools, `ssh`, the Python `.pkg` writer
  — becomes library calls. What remains glue (QEMU, the EDK II build) is
  handled as well by `os/exec` with `context` as by shell, and with errors
  that cannot vanish.
- **The 10.9 target.** It is still met: the family's Go toolchain
  (`Mavergreen/golang`) builds for 10.9, and Tailscale and the Docker tools
  already ship through it. The bash 3.2 floor retires with the shell
  tree.
