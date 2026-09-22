# Run this on an arm64 Linux host

One experiment, three claims, about 15 minutes of machine time. It decides
whether this project can build identical firmware on Apple Silicon — which
decides whether **P6** (the GitHub Actions runner, goal #4) can build
anything at all, or only run what an x86_64 machine built for it.

Delete this file once the experiment has been run and its result recorded
in `docs/host-profile.md` G30 and G31.

## Why

EDK II compiles x86_64 firmware. On an x86_64 host the native compiler
*is* the cross compiler — Debian's multiarch scheme makes `gcc` and
`x86_64-linux-gnu-gcc` literally the same inode — so the question cannot
be asked here at all. It can only be asked on a machine whose own
architecture differs from the firmware's.

Three claims are tangled together, and this run separates them:

| | Claim | Why it might fail |
|---|---|---|
| **A** | A cross-gcc's code generation does not depend on the architecture it runs on | It should not. This is the basis of reproducible cross-builds. |
| **B** | Debian's `gcc-13-x86-64-linux-gnu` built *for arm64* generates the same code as the one built for amd64 | Same source, same version, but separately built packages |
| **C** | **EDK II's BaseTools produce the same PE images when they are aarch64 binaries** | `GenFw` *post-processes* the compiler's output rather than compiling. Nothing about compiler determinism covers it. This is the claim nobody thought of, and the only silent one. |

## What you need

**Ubuntu 24.04 LTS (noble) on arm64.** Not a preference — the version is
load-bearing. This project's one fully verified compiler is
`gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`, and every checksum in
`docs/decisions/0004` came from it. Noble is where that exact version
lives. A different Ubuntu or a Debian gives a different gcc, and then a
checksum mismatch tells you nothing about A, B or C — only that you used
a different compiler, which we already know changes the bytes.

Check first:

```sh
. /etc/os-release && echo "$PRETTY_NAME $VERSION_CODENAME"   # want: 24.04 / noble
uname -m                                                      # want: aarch64
```

If it is not noble, say so before going further — the experiment can be
adapted but the reference checksums cannot.

## Setup

```sh
sudo apt install gcc-13-x86-64-linux-gnu binutils-x86-64-linux-gnu \
                 nasm iasl uuid-dev python3 git make zip \
                 mtools gdisk dmg2img hfsprogs xxd qemu-system-x86 busybox-static cpio
```

Then confirm you got the same compiler version, not merely a similar one:

```sh
x86_64-linux-gnu-gcc-13 --version | head -1
# want exactly: x86_64-linux-gnu-gcc-13 (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
```

**The version string must match.** If it does not, stop and report what
you got; a build at a different version is a different experiment.

## The two things that must be identical, or the result is noise

1. **The build path.** EDK II writes each module's debug-symbol path into
   the PE image, so `MQG_BUILD_DIR` is an *input to the bytes*. This was
   measured here on 2026-09-21: two builds at different directories
   differed in **seven of eight artifacts** for no other reason.

   The reference was produced at:

   ```
   /home/schmonz/.local/share/mavericks-qemu-guest/build
   ```

   Reproduce that path exactly. If your username differs, create the path
   anyway (`sudo mkdir -p /home/schmonz && sudo chown $USER /home/schmonz`)
   or bind-mount it — but do not skip it.

2. **The UTC day.** `OpenCore.efi` embeds its build date; a rebuild on a
   different day differs in exactly two bytes. Note the UTC date of your
   run; if it differs from the reference's, `OpenCore.efi` is expected to
   differ in two bytes and that is not a finding.

## Run it

```sh
git clone <this repo> mavericks && cd mavericks
export MQG_BUILD_DIR=/home/schmonz/.local/share/mavericks-qemu-guest/build
./boot/prereqs.sh                       # should say all present
./image/build-image.sh --stage opencore
./image/build-image.sh --stage ovmf
date -u +%F                             # record this
```

If `prereqs.sh` reports anything missing, install it and say what was
missing — that is itself a finding about arm64 hosts, and this project has
been bitten five times by a host tool nobody knew was needed.

## What to send back

```sh
cat "$MQG_BUILD_DIR/artifacts/SHA256SUMS"
sha256sum "$MQG_BUILD_DIR"/*/OVMF_CODE.fd 2>/dev/null || \
  find "$MQG_BUILD_DIR" -name 'OVMF_CODE.fd' -exec sha256sum {} +
```

**And the `.dll` files, which is how A and B are told apart from C:**

```sh
find "$MQG_BUILD_DIR" -name 'OpenCore.dll' -o -name 'OpenRuntime.dll' | \
  xargs sha256sum
```

`GenFw` turns `.dll` into `.efi`. So:

- **`.dll` matches, `.efi` matches** → A and B and C all hold. The
  unification is live, one compiler row covers every host, and **P6 can
  build on its own runners.**
- **`.dll` matches, `.efi` differs** → the compiler is fine; **BaseTools
  is not** (claim C). That is the interesting failure, and it is fixable
  in principle, because `GenFw`'s output difference would be a bug or an
  endianness/padding assumption rather than a fact of nature.
- **`.dll` differs** → A or B fails. Report how many of the artifacts
  differ and by how much; a two-byte difference is a date, a wholesale
  difference is code generation.

## Reference checksums, from `pet-power-plant`, gcc 13.3.0, 2026-09-21

```
a6e91a7a995f8792e987da25c2c7061e2dc7907f8c2eef7dec61ebd00ff3669a  OpenCore.efi
eb05c27990e7162011b2ef5229d3e2b8be23a8e0bfd79d77c1891cee175e0094  BOOTx64.efi
d5bece452e5c2180b7f588b40b12c2fe64663548dbbe0de01038c3db45083a5d  OpenRuntime.efi
e0ee5f238725685eff2f423558b933497c5475c257f747aa281e2d88018723ea  OpenPartitionDxe.efi
93f491375fbd4c0541b55d64b8d4e2f01cafde4f66b7f520f943d3351a45040a  OpenHfsPlus.efi
195c4dcff2abf2f5aea08c290f057432704a250eab56b0b887ac0f8503ee58d2  OVMF_CODE.fd
```

`OpenCore.efi` is the one that legitimately differs by two bytes on a
different UTC day. The other five, and `OVMF_CODE.fd`, should not differ
for any reason we know of — which is exactly what makes them a test.

## What a negative result is worth

As much as a positive one. If arm64 cannot produce identical firmware,
then P6's runners must consume an image built elsewhere, `lib/compiler.sh`
grows a per-architecture row, and `docs/decisions/0004`'s reproducibility
claim stays scoped to x86_64 hosts. All three are honest positions, and
knowing which one we are in is the point.

**Do not adjust anything to make the checksums match.** If they differ,
they differ; this project has spent a fortnight learning that a claim
nobody tried to falsify is worth nothing.
