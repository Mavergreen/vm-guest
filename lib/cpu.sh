# shellcheck shell=bash
# The guest's CPU model: which ones this project has actually run, and what
# each claim rests on. Sourced, never executed; needs lib/common.sh first
# for log/warn/die.
#
# WHY A LIST AND NOT A PIN, AND WHY NOT A WHITELIST EITHER
#
# `-cpu` is the one line that decides whether this project runs on a host
# at all. It is also the line nobody here had measured: until 2026-09-21
# the default was `Penryn,+ssse3,+sse4.1,+sse4.2` because P1 copied it out
# of a UTM bundle that booted, and every host it ran on afterwards was
# newer than the model it asked for -- so the question "does Mavericks
# NEED any of this" had never come up.
#
# A pin would make the project refuse hosts it has never seen. A free-form
# string with no guidance makes every user rediscover the same three
# answers. So: a table of models with the evidence for each, a default, and
# a check that WARNS. `--cpu` still takes any string QEMU takes. Someone on
# hardware this project has never met must not be blocked by our ignorance
# -- that is the whole reason the Mac Pro 1,1 in docs/test-hosts.md was
# written off for a year on a prediction that turned out to be irrelevant.
#
# WHAT THE STATUSES MEAN, AND WHY THERE ARE FOUR
#
#   VERIFIED    a guest was INSTALLED on this line and then booted from it
#               and answered SSH. The strongest thing that can be said.
#   BOOTED      a guest installed on a DIFFERENT line booted on this one,
#               reached SSH, and reported its own feature set. That is a
#               real measurement and it is not an install.
#   EXPECTED    reasoned from what the measured rows show, not run.
#   NOT-TESTED  nobody has tried. Not "known to fail".
#
# VERIFIED and BOOTED are kept apart on purpose, and the reason is
# `docs/decisions/0008`: a NIC turned out to be build-time state in 10.9,
# so "it booted with X" and "it installs with X" are demonstrably different
# claims in this guest. Nothing yet says the CPU model has the same
# property -- but nothing says it does not, and collapsing the two statuses
# would be asserting that it does not.
#
# AND WHY NOT-TESTED IS MOST OF THE TABLE
#
# This project has caught four inherited, undated claims wrong (the
# usb-tablet kext, "DNS needs configuration", Security Update 2016-001, and
# `kvm.ignore_msrs=1`) and one right (no virtio-net in stock 10.9). A table
# that implied coverage it does not have would be the fifth wrong one, and
# unlike the other four it would be ours. Every row below that nobody has
# booted says so.
#
# WHAT WAS MEASURED, 2026-09-21
#
# Primary host (`pet-power-plant`, i7-8700B Coffee Lake, QEMU 8.2.2,
# `-accel kvm`), one changed `-cpu` line, a qcow2 overlay on the
# SSH-capable image, the verify stage's own checks, three boots:
#
#   -cpu line                       SSH    guest's machdep.cpu.features
#   Penryn,+ssse3,+sse4.1,+sse4.2   20 s   ... SSSE3 CX16 SSE4.1 SSE4.2
#   Penryn                          20 s   ... SSSE3 CX16 SSE4.1
#   Conroe                          20 s   ... SSSE3
#
# All three computed the same correct SHA-256 over 64 MiB of zeros, so all
# three did real work and got it right, not merely reached a login window.
#
# TWO THINGS FELL OUT OF THAT, AND BOTH CHANGE SOMETHING
#
# 1. **10.9 does not require SSE4.1.** The floor generally cited for
#    Mavericks is SSSE3, and this is the first time anyone here checked.
#    Conroe/Merom is SSSE3 without SSE4.1 -- the feature set of the Mac Pro
#    1,1's 2006 Woodcrest Xeon -- and the guest booted on it, reached SSH
#    in the same 20 seconds, and reported exactly the features asked for.
#    `docs/host-profile.md` G3 and the Mac Pro entry in
#    `docs/test-hosts.md` both said that host could not run this project.
#    They were wrong, and about the only host that can settle G14.
#
# 2. **Two of the three flags are redundant and the third is not.** Bare
#    `Penryn` already carries SSSE3 and SSE4.1, so `+ssse3` and `+sse4.1`
#    ask QEMU for what the model gives anyway. `+sse4.2` does NOT: QEMU's
#    Penryn-v1 has no SSE4.2, and it should not -- real Penryn had none,
#    SSE4.2 arrived with Nehalem in 2008. So the default line asks for a
#    feature the CPU it names never had. It has been VERIFIED that way
#    through two full installs on two hosts, which is why it is still the
#    default; see `docs/decisions/0009` for why "it is over-specified" did
#    not by itself outrank "it is the only line measured end to end".
#
# THE DEFAULT
#
# `Penryn,+ssse3,+sse4.1,+sse4.2`, unchanged. It is the only row with a
# completed install behind it, twice, on two QEMUs three major versions
# apart. Conroe is the row to move to when something installs on it.

MQG_CPU_DEFAULT='Penryn,+ssse3,+sse4.1,+sse4.2'

# The table. "<cpu line>\t<status>\t<evidence>", one row per line.
#
# Tab-separated text and not an associative array: bash 3.2 has none, and
# 10.9 ships bash 3.2 (bin/bash32-check.sh). Same shape as TRI_FACTS in
# lib/triangulate.sh.
#
# Order is oldest feature set first, so the table reads as a ladder and the
# floor is at the top where the interesting question is.
MQG_CPU_MODELS="\
Conroe	BOOTED	2026-09-21, pet-power-plant, QEMU 8.2.2, -accel kvm: an image installed under the default line booted on this one, answered SSH in 20 s, passed the verify stage's checks, and reported SSSE3 with no SSE4.1 and no SSE4.2. This is the row that says 10.9's floor is SSSE3 and not SSE4.1. No guest has been INSTALLED on it.
Penryn	BOOTED	2026-09-21, same run, same evidence: SSH in 20 s, and the guest reported SSSE3 and SSE4.1 but no SSE4.2 -- which is what QEMU's Penryn-v1 is and what real Penryn was. No guest has been INSTALLED on it.
Penryn,+ssse3,+sse4.1,+sse4.2	VERIFIED	The default. Full unattended install and SSH on pet-power-plant (QEMU 8.2.2) and on squirrel-zapper (QEMU 11.1.1). +ssse3 and +sse4.1 are redundant with the model; +sse4.2 is not -- see docs/decisions/0009.
Nehalem	NOT-TESTED	Never booted here. It is the first model with SSE4.2, so it is the model the default line is really approximating, and it is also the first with EPT -- docs/host-profile.md G18 and decisions/0005 both wait on that.
Westmere	NOT-TESTED	Never booted here.
SandyBridge	NOT-TESTED	Never booted here.
IvyBridge	NOT-TESTED	Never booted here.
Haswell-noTSX	NOT-TESTED	Never booted here. P5 is the phase that measures it, against Penryn and with +invtsc -- see docs/decisions/0009. P5 fills in THIS row; it does not start a second record of the same question.
host	NOT-TESTED	Never booted here, and the one row where that is a warning rather than a shrug: -cpu host hands the guest every feature the host has, which on anything since 2013 includes instruction sets 10.9 has never seen. docs/host-profile.md G3 is the entry about masking down, and this is the line that does not mask.
qemu64	NOT-TESTED	Never booted here. Worth naming because it is QEMU's own default and it has no SSSE3 at all, which is below the floor the Conroe row establishes. The obvious next experiment, and the one most likely to fail.
"

# The default as one phrase, so no caller spells it out by hand.
cpu_default_text() {
    printf '%s (docs/decisions/0009)' "$MQG_CPU_DEFAULT"
}

# The table as it stands, one "<line>\t<status>\t<evidence>" row per line,
# blank rows dropped.
cpu_models() {
    printf '%s\n' "$MQG_CPU_MODELS" | awk -F'\t' 'NF >= 3 { print }'
}

# Just the -cpu lines, one per line. This is what a host probe iterates.
cpu_model_lines() {
    cpu_models | cut -f1
}

# cpu_model_base <cpu line> -- the model name with its flags stripped.
# "Penryn,+ssse3,+sse4.1" -> "Penryn". QEMU's `-cpu help` lists models, not
# lines, so a probe that wants to ask "does this QEMU know the model" has
# to take the line apart first.
cpu_model_base() {
    printf '%s\n' "${1%%,*}"
}

# cpu_status_text <status> -- what one status word means, as a clause that
# reads after the status word itself, so the phrase is written once and
# every message and the manifest agree. The
# compiler range does the same thing with compiler_range_text, and for the
# same reason: two spellings of one status is how a reader ends up
# believing a claim the table did not make.
cpu_status_text() {
    case $1 in
        VERIFIED)
            printf 'a guest was installed on this line, booted from it and answered SSH' ;;
        BOOTED)
            printf 'a guest installed on a different line booted on this one and answered SSH, but nothing has been installed on it' ;;
        EXPECTED)
            printf 'reasoned from the rows that were measured, never run' ;;
        NOT-TESTED)
            printf 'nobody here has tried it, which is not the same as knowing it fails' ;;
        UNLISTED)
            printf 'not one of the lines this project has an opinion about, which is not a refusal -- the list is guidance and an arbitrary --cpu string still works' ;;
        *)
            printf 'unknown status "%s"' "$1" ;;
    esac
}

# cpu_line_verdict <cpu line> -- "<status>\t<detail>".
#
# Pure: no QEMU is run, no environment is read. Judging is separated from
# gathering here for the same reason it is in lib/compiler.sh and
# lib/preconditions.sh -- every branch is then testable on one host.
#
# An exact string match against the table, deliberately. "Penryn" and
# "Penryn,+sse4.2" are different CPUs and a fuzzy match would report the
# evidence for one of them as evidence for the other. That is precisely the
# mistake this file exists to stop.
cpu_line_verdict() {
    local line=$1 row status evidence tab
    tab=$(printf '\t')
    row=$(cpu_models | awk -F'\t' -v want="$line" '$1 == want { print; exit }')
    if [ -z "$row" ]; then
        printf 'UNLISTED\t%s -- "%s" is not in this project'"'"'s tested-options table; the default is %s\n' \
            "$(cpu_status_text UNLISTED)" "$line" "$(cpu_default_text)"
        return 0
    fi
    row=${row#*"$tab"}
    status=${row%%"$tab"*}
    evidence=${row#*"$tab"}
    printf '%s\t%s -- %s\n' "$status" "$(cpu_status_text "$status")" "$evidence"
}

# One line for the image manifest: what the table said about this image's
# -cpu line, as judged when the image was built.
#
# The manifest already records WHICH -cpu line an image was built with, in
# its `accel` row. This records whether that line was one the project had
# evidence for at the time -- which the `accel` row cannot answer later,
# because the table moves as measurements arrive and the image does not.
# An image built on an untested model should still say so in a year, and
# one built on a model that is VERIFIED only because this image verified it
# should not read as though it had evidence behind it beforehand.
cpu_line_manifest() {
    local status tab verdict detail
    tab=$(printf '\t')
    status=$(cpu_line_verdict "$1")
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}
    printf '%s -- %s\n' "$verdict" "$detail"
}

# The gate the build scripts call. NEVER dies.
#
# The compiler range refuses below its floor, because a compiler this
# project has never seen produces artifacts whose checksums it cannot
# vouch for. This does not, and the difference is the point: a -cpu line is
# not an input to anything reproducible, it is a description of hardware
# the user has and we do not. Refusing here would mean refusing to run on
# every machine nobody here owns -- which is how the Mac Pro 1,1 spent a
# year written off in docs/test-hosts.md on a prediction nobody tested.
cpu_line_check() {
    local line=${1:-$MQG_CPU_DEFAULT} status tab verdict detail

    tab=$(printf '\t')
    status=$(cpu_line_verdict "$line")
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}

    case $verdict in
        VERIFIED)
            log "cpu: $line -- $detail"
            ;;
        BOOTED|EXPECTED)
            log "cpu: $line -- $detail"
            warn "cpu: this is not the line the default was verified on."
            warn "If a guest installs on it, say so: that is how the row moves"
            warn "to VERIFIED (lib/cpu.sh, docs/decisions/0009)."
            ;;
        NOT-TESTED|UNLISTED)
            warn "cpu: $line -- $detail"
            warn "Proceeding: the table is guidance, not a whitelist, and a host"
            warn "this project has never seen must not be blocked by our ignorance."
            warn "WHAT TO WATCH FOR: a -cpu line 10.9 cannot use does not usually"
            warn "fail at QEMU start -- it panics in the guest, or hangs at a grey"
            warn "screen, both of which look like 'the install is slow'. If this"
            warn "one works, report it; if it panics, report how. Either answer is"
            warn "worth more than the row it replaces."
            warn "Known-good lines: $(cpu_model_lines | tr '\n' ' ')"
            ;;
        *)
            die "internal error: unknown cpu verdict '$verdict'"
            ;;
    esac
}
