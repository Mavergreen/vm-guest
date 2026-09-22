# shellcheck shell=bash
# The guest's SMBIOS model: which ones this project has actually run, and
# what each claim rests on. Sourced, never executed; needs lib/common.sh
# first for log/warn/die.
#
# Same shape as lib/cpu.sh, and for the same reason. Read that file's
# header for the argument; this one records only what is different.
#
# WHY THIS IS A PARAMETER NOW
#
# docs/host-profile.md G14 says "SMBIOS must not be MacPro5,1 -- it loads
# AppleTyMCEDriver, which panics on a non-Xeon CPU. Using iMac14,2." The
# first half of that is an OBSERVATION, made once, on one host, in P1, with
# OpenCore 0.6.6 out of a UTM bundle and firmware we no longer use. The
# second half -- "because the driver wants a Xeon" -- was an EXPLANATION,
# and it was WRONG: a real Xeon 5150 panicked too, on 2026-09-21.
#
# The explanation that survived is measured, and it is neither about the
# host CPU nor about the SMBIOS in itself. The panic dump prints RCX =
# 0x280, which is IA32_MC0_CTL2, and KVM injects #GP on that range whenever
# MCG_CMCI_P is clear -- which under QEMU it always is. The control: the
# same image with -accel tcg and nothing else changed boots and answers SSH
# as MacPro5,1. See the table row below and docs/host-profile.md G14.
#
# Keeping the parameter is still right. It is what made all of that
# testable in one command instead of an edit to a tracked file.
#
# An explanation that has never been tested is exactly the kind of thing
# this project has been wrong about four times (the usb-tablet kext, "DNS
# needs configuration", Security Update 2016-001, kvm.ignore_msrs=1). The
# value was hardcoded at boot/config/config.plist:367, so settling it meant
# editing a tracked file and remembering to put it back. That is how an
# experiment goes unrun for three phases. A flag costs nothing and the
# question becomes a command.
#
# WHAT THE STATUSES MEAN
#
#   VERIFIED    a guest was INSTALLED with this SMBIOS, then booted from it
#               and answered SSH. The strongest thing that can be said.
#   BOOTED      a guest installed under a DIFFERENT SMBIOS booted with this
#               one and got as far as a usable screen. A real measurement,
#               and not an install.
#   PANICKED    a guest kernel-panicked with this SMBIOS. Says where, when,
#               and how many times -- because "it panicked once, in 2026,
#               on one machine" and "this does not work" are different
#               claims and only the first one is evidence.
#   NOT-TESTED  nobody has tried. Not "known to fail".
#
# There is no EXPECTED row here on purpose. Reasoning from Apple's model
# identifiers to which kexts a machine loads is precisely the step that put
# an untested explanation in the ledger for three phases.
#
# WHAT CHANGING THIS CHANGES, AND WHAT IT DELIBERATELY LEAVES ALONE
#
# OpenCore's PlatformInfo > Generic block has six fields besides the
# product name: MLB, ROM, SystemSerialNumber, SystemUUID, SpoofVendor and
# SystemMemoryStatus. `--smbios` touches ONE of them, SystemProductName.
# It does not touch the serial, the board serial, the ROM or the UUID.
#
# That is coherent, and the reason is `Automatic = true` in our config:
# OpenCore then looks the product name up in its own built-in Apple model
# database and derives the board id (`Mac-F221BEC8` for MacPro5,1, which is
# the board id P1's panic printed without our ever having typed it), the
# firmware features, the platform feature word and the rest from it. The
# board id we never set is exactly the field that moved when P1 changed the
# product name, which is the observation that says the derivation works.
#
# The serial numbers in our config are placeholders -- `W00000000001`,
# `M0000000000000001`, a zero UUID, an `ESIzRFVm` ROM -- and they are NOT
# valid serials for iMac14,2 or for anything else. They were never meant to
# be: this guest does not talk to Apple's servers, and the project has no
# business minting plausible-looking serials for a machine that does not
# exist. A serial is not consulted by a kext deciding whether the hardware
# is a Xeon, so leaving them alone keeps the experiment a one-variable one.
# See docs/decisions/0010.

MQG_SMBIOS_DEFAULT='iMac14,2'

# The table. "<model>\t<status>\t<evidence>", one row per line.
#
# Tab-separated text and not an associative array: bash 3.2 has none, and
# 10.9 ships bash 3.2 (bin/bash32-check.sh). Same shape as MQG_CPU_MODELS
# in lib/cpu.sh and TRI_FACTS in lib/triangulate.sh.
MQG_SMBIOS_MODELS="\
iMac14,2	VERIFIED	The default since P1. Full unattended installs on three hosts -- pet-power-plant (QEMU 8.2.2), squirrel-zapper (QEMU 11.1.1) and ap-juicer (Mac Pro 1,1, QEMU 11.0.2) -- each of which then booted without installer media and answered SSH. The installed guest reports hw.model=iMac14,2, so the override reaches the installed system and not only the installer (docs/install-log.md). A 2013 Haswell iMac paired with a Penryn guest CPU, which 10.9 evidently tolerates.
MacPro5,1	PANICKED	PANICS UNDER KVM, BOOTS UNDER TCG, AND AS OF 2026-09-22 WE KNOW WHY. Three observations under KVM on pet-power-plant (i7-8700B Coffee Lake, NOT a Xeon): 2026-09-17 P1, the INSTALLER panicked under khronokernel's OpenCore 0.6.6 and UTM firmware; 2026-09-21, an ALREADY-INSTALLED 10.9.5 guest on OUR OpenCore 1.0.7, OUR OVMF and OUR config.plist panicked at 40 s; 2026-09-22, reproduced again on a fresh overlay of the SSH-capable pipeline image as a one-variable control -- panic at 40 s, no SSH in 180 s where the default SMBIOS answers in 20-40 s. Also PANICKED on ap-juicer, which IS a Xeon 5150, so it is not about the host CPU. THE CAUSE IS MEASURED AND IT IS NOT THE SMBIOS AND NOT THE HOST. The panic dump prints the CPU registers and RCX is 0x0000000000000280. RCX is the MSR index register for rdmsr/wrmsr and 0x280 is IA32_MC0_CTL2, the first CMCI control register -- which is what a function called enableInterruptForCorrectableMemoryCoreRegister touches. KVM dispatches 0x280-0x29F to get_msr_mce/set_msr_mce, which return 1 (NOT the KVM_MSR_RET_UNSUPPORTED sentinel) when MCG_CMCI_P is clear, so the #GP is injected without ignore_msrs ever being consulted and without any dmesg line. QEMU never sets MCG_CMCI_P. Since Linux commit 281b5278, first released in v6.0 on 2022-10-02. THE CONTROL THAT PROVES IT: the same overlay, the same OpenCore image, the same -cpu line, ONE variable -- -accel tcg instead of -accel kvm -- booted and answered SSH at 80 s, reporting sw_vers 10.9.5 and hw.model MacPro5,1. TCG emulates the MSR instead of delegating it. So this row is a property of KVM's machine-check emulation, not of Mavericks and not of this hardware. WHAT WOULD FALSIFY THE EXPLANATION: a host kernel older than 6.0 with ignore_msrs=1, where 0x280 still fell through to the ignore path -- MacPro5,1 should boot there and dmesg should name 0x280. No host in the fleet is old enough. See docs/configuration-register.md, docs/host-profile.md G14, docs/decisions/0010.
"

# The default as one phrase, so no caller spells it out by hand.
smbios_default_text() {
    printf '%s (docs/decisions/0010)' "$MQG_SMBIOS_DEFAULT"
}

# The table as it stands, one "<model>\t<status>\t<evidence>" row per line,
# blank rows dropped.
smbios_models() {
    printf '%s\n' "$MQG_SMBIOS_MODELS" | awk -F'\t' 'NF >= 3 { print }'
}

# Just the model names, one per line.
smbios_model_names() {
    smbios_models | cut -f1
}

# smbios_status_text <status> -- what one status word means, as a clause
# that reads after the status word itself. Written once so the warning, the
# manifest and the report cannot drift into two spellings of one claim.
smbios_status_text() {
    case $1 in
        VERIFIED)
            printf 'a guest was installed with this SMBIOS, booted from it and answered SSH' ;;
        BOOTED)
            printf 'a guest installed under a different SMBIOS booted with this one, but nothing has been installed with it' ;;
        PANICKED)
            printf 'a guest kernel-panicked with this SMBIOS, and the row says where and how often' ;;
        NOT-TESTED)
            printf 'nobody here has tried it, which is not the same as knowing it fails' ;;
        UNLISTED)
            printf 'not one of the models this project has an opinion about, which is not a refusal -- the list is guidance and an arbitrary --smbios value still works' ;;
        *)
            printf 'unknown status "%s"' "$1" ;;
    esac
}

# smbios_wellformed <value> -- true if this string can be written into the
# plist as an Apple model identifier.
#
# THIS IS THE ONE THING THAT IS REFUSED, AND IT IS NOT ABOUT EVIDENCE.
#
# An unknown MODEL is allowed through with a warning, exactly like an
# unlisted -cpu line: the table is guidance, and a user on hardware this
# project has never met must not be blocked by our ignorance. But a value
# carrying `<`, `&`, a quote, whitespace or a newline does not produce an
# untested SMBIOS -- it produces a malformed config.plist, and then a boot
# failure that is about OUR EDIT rather than about Apple's driver. That
# would waste the fourteen minutes of firmware AND the experiment, and it
# would waste them in the most expensive way available: by looking like a
# result.
smbios_wellformed() {
    case $1 in
        '') return 1 ;;
        *[!A-Za-z0-9,._-]*) return 1 ;;
    esac
    [ ${#1} -le 64 ]
}

# smbios_verdict <model> -- "<status>\t<detail>".
#
# Pure: reads no file, runs nothing. Judging is separated from gathering
# here for the same reason it is in lib/cpu.sh and lib/preconditions.sh --
# every branch is then testable on one host.
smbios_verdict() {
    local model=$1 row status evidence tab
    tab=$(printf '\t')
    row=$(smbios_models | awk -F'\t' -v want="$model" '$1 == want { print; exit }')
    if [ -z "$row" ]; then
        printf 'UNLISTED\t%s -- "%s" is not in this project'"'"'s tested-options table; the default is %s\n' \
            "$(smbios_status_text UNLISTED)" "$model" "$(smbios_default_text)"
        return 0
    fi
    row=${row#*"$tab"}
    status=${row%%"$tab"*}
    evidence=${row#*"$tab"}
    printf '%s\t%s -- %s\n' "$status" "$(smbios_status_text "$status")" "$evidence"
}

# One line for the image manifest: what the table said about this image's
# SMBIOS, as judged when the image was built.
#
# The same argument as cpu_line_manifest. The manifest's own `smbios` row
# says WHICH model an image was built with; this says whether the project
# had evidence for it at the time, which the model name cannot answer later
# because the table moves as measurements arrive and the image does not.
smbios_manifest() {
    local status tab verdict detail
    tab=$(printf '\t')
    status=$(smbios_verdict "$1")
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}
    printf '%s -- %s\n' "$verdict" "$detail"
}

# The gate the build scripts call. NEVER dies on an unknown model; see
# smbios_wellformed above for the one thing that is refused, and
# lib/cpu.sh's cpu_line_check for why a table like this warns.
smbios_check() {
    local model=${1:-$MQG_SMBIOS_DEFAULT} status tab verdict detail

    tab=$(printf '\t')
    status=$(smbios_verdict "$model")
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}

    case $verdict in
        VERIFIED)
            log "smbios: $model -- $detail"
            ;;
        BOOTED)
            log "smbios: $model -- $detail"
            warn "smbios: this is not the model the default was verified on."
            warn "If a guest INSTALLS with it, say so: that is how the row"
            warn "moves to VERIFIED (lib/smbios.sh, docs/decisions/0010)."
            ;;
        PANICKED)
            warn "smbios: $model -- $detail"
            warn "Proceeding anyway, because that is the point: this row"
            warn "exists to be re-run, and a panic that reproduces is worth"
            warn "as much as one that does not. WHAT TO WATCH FOR: the panic"
            warn "is on the guest's screen, not in QEMU's output -- take a"
            warn "screenshot (vm/screenshot.sh) before killing the VM, and"
            warn "remember that 2 colours is white-on-black TEXT and not a"
            warn "blank screen. Record the result in NOTES.md either way."
            ;;
        NOT-TESTED|UNLISTED)
            warn "smbios: $model -- $detail"
            warn "Proceeding: the table is guidance, not a whitelist."
            warn "WHAT TO WATCH FOR: a SystemProductName 10.9 dislikes does"
            warn "not fail at QEMU start -- it panics in the guest or hangs"
            warn "at a grey screen, both of which look like 'the install is"
            warn "slow'. If it works, report it; if it panics, report the"
            warn "kext named in the panic. Either answer is worth more than"
            warn "the row it replaces."
            warn "Known models: $(smbios_model_names | tr '\n' ' ')"
            ;;
        *)
            die "internal error: unknown smbios verdict '$verdict'"
            ;;
    esac
}

# --- the plist edit --------------------------------------------------------
#
# In this library rather than in boot/build-efi-image.sh so that it is
# testable without building an EFI image, which is the same reason the
# verdict functions are pure.

# smbios_plist_product_name <plist> -- the SystemProductName currently in
# that file, or empty.
#
# Text, not plistlib: this has to run in boot/build-efi-image.sh, which
# requires sgdisk and mtools and has never required python3. The pattern is
# `<key>SystemProductName</key>` followed by a `<string>`, which is what
# OpenCore's sample config and ours both are.
smbios_plist_product_name() {
    awk '
        /<key>SystemProductName<\/key>/ { want = 1; next }
        want && /<string>/ {
            line = $0
            sub(/^[^<]*<string>/, "", line)
            sub(/<\/string>.*$/, "", line)
            print line
            exit
        }
    ' "$1"
}

# smbios_plist_set <plist> <model> -- that plist with SystemProductName set
# to <model>, on stdout. The input is not modified.
#
# A SURGICAL EDIT, NOT A REWRITE. Reading the plist into plistlib and
# writing it back would reformat every line of a file whose checksum is in
# every manifest this project has ever produced, and would silently
# normalize anything OpenCore cares about that python happens to spell
# differently. One value changes; the bytes around it do not.
#
# Refuses rather than guesses if the file does not have exactly one
# SystemProductName key: a half-edited SMBIOS is the failure mode this
# whole parameter exists to avoid.
smbios_plist_set() {
    local src=$1 model=$2 keys

    [ -f "$src" ] || die "smbios: no such plist: $src"
    smbios_wellformed "$model" \
        || die "smbios: '$model' is not a usable SMBIOS model identifier" \
               "(letters, digits, comma, dot, dash, underscore; 64 max)."

    keys=$(grep -c '<key>SystemProductName</key>' "$src" || true)
    [ "$keys" = 1 ] \
        || die "smbios: $src has $keys SystemProductName keys, expected 1;" \
               "refusing to guess which one PlatformInfo reads"

    awk -v model="$model" '
        done_it == 0 && /<key>SystemProductName<\/key>/ { want = 1; print; next }
        want && /<string>/ {
            match($0, /^[^<]*/)
            printf "%s<string>%s</string>\n", substr($0, 1, RLENGTH), model
            want = 0; done_it = 1
            next
        }
        { print }
        END {
            if (done_it != 1) {
                print "smbios: no <string> after <key>SystemProductName</key>" > "/dev/stderr"
                exit 1
            }
        }
    ' "$src"
}
