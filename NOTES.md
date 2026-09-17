# Lab log

Append-only. Newest entries at the bottom. Every command tried, what happened,
any panic text, and what fixed it. **Failures are as valuable as successes** —
a dead end that isn't written down gets walked into twice.

Format per entry: date, phase, what was attempted, the exact command, the
outcome, and the conclusion drawn.

---

## 2026-09-17 — P0 — host probe

Probed the host before designing. Full results in `docs/host-profile.md`.

```
lscpu; ls -l /dev/kvm; id; qemu-system-x86_64 --version
ls /usr/share/OVMF/; cat /etc/os-release; free -g; df -h /home/schmonz
cat /sys/class/dmi/id/{sys_vendor,product_name,board_name}
uname -a; ls /sys/kernel/iommu_groups | wc -l; lspci -nn | grep -iE 'vga|3d|display'
```

Outcome: `Macmini8,1`, i7-8700B (Coffee Lake, 6C/12T), 62 GB RAM, 1.7 TB free,
T2 chip, Mint 22.3 on kernel `7.2.6-1-t2-noble`, VT-x present, `/dev/kvm`
usable by the user via group `kvm`, IOMMU on with 14 groups, QEMU 8.2.2,
OVMF 4M-split only, Intel UHD 630 as the sole display device.

Conclusions:

- The AMD hard-stop does not trigger. Intel with VT-x, KVM usable without
  further permission work.
- The host is Apple hardware, so virtualizing OS X here is licensed.
- No PCIe slots and one iGPU, so GPU passthrough is off the table. Recorded
  as `docs/decisions/0001-no-gpu-passthrough.md`.
- OVMF is 4M split CODE/VARS only, with no combined image. Flagged as a risk
  for P3, since the UTM bundle's firmware is most likely a combined older
  image.
- The `t2` kernel is unusual and worth remembering whenever something behaves
  oddly.

Not yet done: `kvm.ignore_msrs=1`, which needs `sudo` and therefore an ask.

---

## 2026-09-17 — P0 — preconditions

Built `lib/preconditions.sh` (fact-judging verdict functions), `bin/preconditions.sh`
(fact-gathering executable), and `tests/preconditions.bats`. Ran the check
against this host:

```
STATUS  CHECK                     DETAIL
------  -----                     ------
PASS    cpu-vendor                Intel: the documented KVM path
PASS    vmx                       VT-x present
PASS    kvm-device                /dev/kvm is writable by this user
WARN    ignore-msrs               kvm.ignore_msrs is 'N'; required by prior art. Needs sudo: ask before running 'echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs'
PASS    ovmf                      4M split CODE/VARS found in /usr/share/OVMF
PASS    tool:qemu-system-x86_64   /usr/bin/qemu-system-x86_64
PASS    tool:qemu-img             /usr/bin/qemu-img
PASS    tool:dmg2img              /usr/bin/dmg2img
PASS    tool:kpartx               /usr/sbin/kpartx
PASS    tool:sgdisk               /usr/sbin/sgdisk
PASS    tool:rsync                /usr/bin/rsync
PASS    tool:xxd                  /usr/bin/xxd
PASS    tool:openssl              /usr/bin/openssl
PASS    tool:curl                 /usr/bin/curl
PASS    tool:unzip                /usr/bin/unzip
PASS    tool:python3              /usr/bin/python3
PASS    tool:mkfs.hfsplus         /usr/sbin/mkfs.hfsplus
PASS    tool:bats                 /usr/bin/bats

mqg: preconditions: GO
```

Conclusion: this host is a GO. Everything passes except `ignore-msrs`, which
warns rather than fails because setting it needs a `sudo` ask that hasn't
happened yet -- not a blocker for further P0/P1 work, but must be done before
first boot.

## 2026-09-17 — P0 — ignore_msrs enabled

The user applied `kvm.ignore_msrs=1` for this boot only:

```
echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs
```

`./bin/preconditions.sh` now reports 18/18 PASS and GO, with no warnings.

Deliberately **not** persistent. Prior art (Somlo, OSX-KVM) says macOS reads
MSRs that KVM does not emulate and the guest fails early without this, but
nobody has confirmed that on a T2-patched kernel. Making it survive reboots
before we have seen it matter would be committing to a global KVM setting on
faith. If P1 shows it is genuinely required, make it persistent then and
record why here.

**It resets on reboot.** If a previously-working guest suddenly fails early,
check this first.

## 2026-09-17 — P1 — installer media imported and verified

The user ran Mavericks Forever's `get.sh` unmodified on an Intel Mac
(installer Approach C, the path Kostarelas proved). Apple's SHA-256 check
passed with no errors. They also produced an ISO, because the UTM bundle's
own notes show Kostarelas booted a CD image rather than a raw disk:

```
hdiutil convert InstallMacOSXMavericks.dmg -format UDTO -o InstallMavericks
```

Both files were copied to `~/.local/share/mavericks-qemu-guest/media/`, on
local btrfs rather than the NFS-mounted repo — QEMU reads the installer on
every boot attempt, and the performance phase will boot dozens of times.

| File | Bytes | SHA-256 |
|---|---|---|
| `InstallMavericks.iso` | 6,550,052,864 | `e3d624946082e81812b180551c15a36737d1acf75b09f01b1bf926198e637189` |
| `InstallMacOSXMavericks.dmg` | 5,844,415,233 | `dfcae16050a3bad50344db29b20aa0b20172993f1ef8b15fe6a698debd8c11ef` |

Also written to `media/SHA256SUMS`, so `sha256sum -c` can re-check them.

### The media was verified before booting anything

A finished copy proves nothing, so the ISO was inspected structurally rather
than assumed good:

- **Apple Partition Map**, not GPT or MBR — `fdisk` reads nothing, which is
  expected and not a problem. Three entries: the map itself, a 6.55 GB
  `Apple_HFS` partition named "disk image", and 3 blocks of `Apple_Free`.
- **HFS+ volume header** (`H+`) at byte 33792. Volume is `OS X Base System`.
- **`System/Library/CoreServices/boot.efi`** present, dated 2014-09-09.
- **The merge worked.** `System/Installation/` holds `BaseSystem.chunklist`,
  a 493 MB `BaseSystem.dmg`, and a `Packages` directory — the first two dated
  today, which is `get.sh` having assembled them, against 2014 dates on the
  original Apple files.
- **All 16 packages present**, including `OSInstall.mpkg`, `OSInstall.pkg`,
  `BaseSystemBinaries.pkg`, and the 3.2 GB `Essentials.pkg`.

This matters beyond a sanity check: it is the reference P4's Linux-native
media build gets diffed against. When that build produces something that will
not boot, this is how we tell whether the media or the configuration is at
fault.

### Storage note

The files initially landed in the repo, which is the NFS mount, and were
moved to local disk — 12.4 GB in 1m46s. Copy directly to
`~/.local/share/mavericks-qemu-guest/media/` next time.
