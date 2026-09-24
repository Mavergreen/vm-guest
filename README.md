# mavericks-qemu-guest

Running OS X 10.9 Mavericks as a KVM-accelerated guest on Linux, with a
reproducible and fully unattended install pipeline — and, eventually, as a
GitHub Actions runner under TCG on arm64 macOS runners.

The host is a Mac mini 2018 running Linux Mint, which makes this the case
Apple's license contemplates: virtualizing OS X on Apple hardware.

## Building an image

One command, from a clean checkout to a bootable, SSH-reachable image, with
nobody watching:

```sh
vmavs image
```

It fetches Apple's `InstallESD.dmg`, builds OpenCore and the guest firmware
from pinned source, builds installer media on Linux without root, boots it,
lets Apple's own installer install unattended, and lets a first-boot payload
create the account and authorize your SSH key. It takes about half an hour
on this host, is resumable stage by stage, and writes a manifest recording
every input. `--describe` prints the plan without doing anything.

The key it authorizes is yours: `--ssh-key PATH`, defaulting to the first of
`~/.ssh/id_*.pub`. No key is generated into an image, and none is committed.

`vmavs compare A B` says in what sense two images are the same;
`docs/decisions/0006-image-pipeline-reproducibility.md` says what that
claim is.

## Where things are

| Path | What |
|---|---|
| `docs/superpowers/specs/` | Design documents. Start with the umbrella design. |
| `docs/superpowers/plans/` | Implementation plans. |
| `docs/prior-art.md` | Every source worth reading, and what each one gives us. |
| `docs/host-profile.md` | What this host is, and every host-specific assumption we've made. |
| `docs/decisions/` | Decision records: what we chose, the evidence, what we rejected. |
| `NOTES.md` | The lab log. Every attempt, including the ones that failed. |

## Ground rules

- **The OS comes from Apple only.** Firmware and bootloaders may be
  third-party; macOS disk images may not.
- **Never publish the guest image.**
- **No unreproducible blobs in the shipped boot path.** Everything is Tier 0
  (built from pinned source) or Tier 1 (vanilla upstream, pinned and
  checksummed). Tier 2 blobs live under `$MQG_VENDOR_DIR` (local disk, not
  the repo — see `docs/decisions/0003-vm-images-on-local-btrfs.md`) and are
  de-risking scaffolding only.
- **Write down the failures.** `NOTES.md` is append-only.
