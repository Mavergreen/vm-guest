# mavericks-qemu-guest

Running OS X 10.9 Mavericks as a KVM-accelerated guest on Linux, with a
reproducible and fully unattended install pipeline — and, eventually, as a
GitHub Actions runner under TCG on arm64 macOS runners.

The host is a Mac mini 2018 running Linux Mint, which makes this the case
Apple's license contemplates: virtualizing OS X on Apple hardware.

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
