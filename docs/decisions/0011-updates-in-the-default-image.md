# 0011 — Apple's post-10.9.5 updates, and why the default changed

Date: 2026-09-22
Status: accepted

## Context

`docs/open-questions.md` Q1 asked whether an image should carry Apple's
post-10.9.5 updates. It was answered by the user on 2026-09-22, on the
evidence a live 10.9.5 guest produced the day before: **two images.**

| `--updates` | installs | for |
|---|---|---|
| `none` | nothing | **P5's baseline.** Every performance measurement compares against it |
| `security` | Security Update 2016-004 | **the new default** |
| `all` | + Safari 9.1.3, iTunes 12.6.2 | opt-in; these are applications, not the OS |

This ADR records what that cost, what it must not have cost, and the three
findings that came out of building it.

## Decision

**`--updates security` is the default. `--updates none` is unchanged.**

Changing a default is the part that needs a decision rather than an
implementation, because it changes what someone gets when they ask for
nothing. The reasoning is short: a dev VM that anyone actually runs should
have the last security update its operating system ever received, and the
one reason not to install it — that an update might silently disable a
service and make a performance number unattributable — is a reason about
**the baseline**, not about every image. So the baseline keeps it and
everything else does not.

`none` remains reachable, remains the value P5 measures against, and
remains what it always was.

## What this is not

**It is not `softwareupdate`.** Nothing in this project runs it to fetch
anything, at build time or at first boot. It would reach Apple's servers
during the build, make the build non-reproducible (whatever Apple serves
that day) and network-dependent at the wrong moment, and a 2013 OS
negotiating with 2026 servers may simply hang. Every package is a
standalone `.pkg` pinned in `vendor/sources.tsv` by checksum, exactly like
every other ingredient. `tests/updates.bats` enforces the rule and has to
distinguish the verbs from the word, because firstboot.sh legitimately runs
`softwareupdate --schedule off` in the guest — the opposite act.

**It is not a second mechanism.** P4 built the switch, the manifest field
and the `OSInstall.collection` arrangement so that answering Q1 later would
be configuration. The update packages ride exactly as the OpenSSH packages
do: onto the media as `--extra-pkg`, absent from `OSInstall.collection`,
copied to the target volume by the payload's `postinstall`, installed by
`firstboot.sh` with `installer -pkg ... -target /` on the booted system.

**It is not Apple's bytes in this repository.** They are fetched at
runtime, from Apple's own CDN, on the user's machine, and never
republished. `bin/no-apple-bytes.sh` is the gate.

## Three things the packages themselves settled

Each of these was read out of the package rather than assumed, and each
changed the implementation.

### 1. The updates install BEFORE the family's OpenSSH

Security Update 2016-004's own Payload contains `./usr/bin/ssh` and
`./usr/sbin/sshd`. The OpenSSH System-Replace package puts symlinks at
those paths. Installed in the other order, the update would overwrite them
and the guest would quietly fall back to OpenSSH 6.2 — the exact defect
that cost a full install to find in P4, reintroduced by an ordering nobody
had reason to think about. So: updates first, OpenSSH second, and
`firstboot.sh`'s existing `openssh_usable` check then judges the state the
guest is actually left in. `/usr/libexec/sshd-keygen-wrapper` is **not** in
the payload, so the wrapper this project writes survives.

### 2. `sw_vers` is not the witness. The build number and the receipt are

`sw_vers -productVersion` still says **10.9.5** after 2016-004, because
`ProductVersion` *is* 10.9.5 — it is a security update, not a point
release. A zero exit from `installer` is not evidence either. This project
has been fooled by a green result that meant nothing more than once.

Two things do move, and both are recorded by `firstboot.sh` before and
after:

- **a receipt**: `pkgutil --pkgs` gains
  `com.apple.pkg.update.security.2016-004Mavericks.13F1911`
- **a build number**: the update carries `SystemVersion.plist`, so
  `sw_vers -buildVersion` goes **13F34 → 13F1911**

### 3. The media's 512 MiB margin is not spare room

It was measured against a media that carries no updates, and it leaves
**483.8 MiB free** — read out of the HFS+ volume header of the media on
disk, not estimated. 2016-004 alone is 353.8 MiB and `--updates all` is
685 MiB. Carrying updates inside the existing margin would mean eating it
whole and then, for `all`, overflowing into exactly the class of failure
`NOTES.md`'s Task 34 entry is about.

So `media/build-installer-img.sh` grew `--extra-space-mib`, which defaults
to **0** and therefore reproduces today's geometry exactly, and
`image/build-image.sh` passes the size of the update packages plus 64 MiB
for the catalog entries they bring with them.

## What `--updates none` must not have lost, and how that is established

P5 measures against it and ADR 0006's reproducibility claim is scoped to
it, so "unchanged" is a claim that has to be checkable rather than assumed.
Three mechanisms, each testable:

1. **The media geometry is bit-identical.** `--extra-space-mib` defaults to
   0 and the partition is still 6759 MiB = 7,087,325,184 bytes, which is
   what the media on disk measures. `tests/updates.bats` asserts the
   number.
2. **The guest's conf file is byte-identical.** `build-firstboot-pkg.sh`
   writes `MQG_FB_UPDATES` and `MQG_FB_UPDATE_PKGS` **only when there are
   packages**; `firstboot.sh` defaults the first to `none`. So a
   `--updates none` payload's generated conf has exactly the lines it had
   before this existed.
3. **No stage stamp gains a line.** `updates_stamp` emits nothing at all
   for `none`. An image built before this switch had a second value does
   not reinstall itself because a feature it does not use was added — and
   every transition is still caught, because `none` has no lines,
   `security` has one and `all` has seven.

What is *not* claimed: the payload package is not byte-identical, because
`firstboot.sh` gained the block that installs updates. That block is inert
at `none` — it logs "none requested" and does nothing else — but the file
is bigger, so its checksum moved and the payload and media stages rerun
once. That is the honest cost of the change and it is a one-time rebuild,
not a behavioural difference.

## The one ingredient that is a written reason rather than a pin

`iBooksDelta-1.0.1` and `RemoteDesktopClient-3.8.4` were offered to a live
10.9.5 guest by Apple and are in **no catalogue anyone has found** — not in
`index-10.9.merged-1.sucatalog`'s package URLs, and not in any of its 333
distribution files. There is no URL to pin, so there is nothing for a
checksum to be the identity of.

They are recorded in `INGREDIENTS.md` anyway, with that as the reason,
because an ingredient with neither a tracker nor a written reason is
exactly the silent staleness hole that file exists to prevent. "We could
not find it" is a reason. "We did not mention it" is not.

## Renovate

**No datasource, and none is needed.** These are frozen artifacts from a
discontinued product line: Apple shipped 10.9's last security update in
2016 and is not going to ship another. There is no newer version for a
tracker to find and no feed to read if there were, and a `regex` manager
scraping a CDN path for a date would be a fragile tracker invented to fill
a cell — which `INGREDIENTS.md`'s own rule says is worse than an honest
blank.

What could actually go stale here is not the bytes but the *claim* that
2016-004 is the last one. That claim was already wrong once — the briefs
said 2016-001, the fourth undated inherited claim this project has caught —
and it was corrected by asking a live guest, not by reading a write-up.
`docs/open-questions.md` Q1 records how, so the next person re-checks
rather than inherits.

## Built and measured, 2026-09-22

Both values were built end to end on `pet-power-plant` and the guest was
asked what happened. `NOTES.md` carries the detail; the summary:

- `--updates security`: `BuildVersion 13F1911`, one receipt
  (`com.apple.pkg.update.security.2016-004Mavericks.13F1911`),
  `ProductVersion` still 10.9.5, `/usr/bin/ssh` still the symlink the
  OpenSSH replacement left, installed unattended and answered SSH with no
  installer media attached.
- `--updates none`: `BuildVersion 13F34`, zero receipts, and a media whose
  39,415 files are byte-identical to the pre-change media except the
  first-boot payload.
- Cost: **+144 s** on the install stage (819 -> 963 s), **+11 s** on the
  media stage, **+1.61 GiB** of qcow2, and a one-time 354 MB download. The
  `installer` run itself took 92 s; the rest is first boot replacing 6,891
  files and rebuilding its caches.

## Consequences

- Every default build now fetches and installs 354 MB more than it did.
  The added time is recorded in `NOTES.md`.
- Two images are distinguishable without booting them: the manifest's
  `updates` field names the selection *and* the packages, and each package
  appears as its own `ingredient.` line.
- Existing goldens now report the new pins as ingredients they do not have.
  That is `bin/image-staleness.sh` doing its job — the repository genuinely
  gained ingredients — and not a defect.
- `--updates all` is implemented and **has never been built**. See
  `NOTES.md` for what was and was not exercised.
