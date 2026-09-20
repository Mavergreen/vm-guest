# shellcheck shell=bash
# The host C compiler: what it is, and whether it is one this project has a
# reason to believe in. Sourced, never executed; needs lib/common.sh first
# for log/warn/die.
#
# WHY A RANGE AND NOT A PIN
#
# Tier 0 says "built from pinned source" and every input is pinned except
# the one that translates them (docs/decisions/0004, "The compiler is not
# pinned"). Pinning a toolchain -- a container, or a bootstrapped GCC -- is
# the only thing that makes "the same sources produce the same bytes" true,
# and it is the right answer if these images ever have to be independently
# verifiable. It is also a large amount of machinery for a project whose
# other Tier 0 claim is that it needs nothing but a shell and a package
# manager, and P6 has not yet said what CI needs. A declared range is the
# cheapest change that turns a silent break into a clear message. See
# decisions/0004 for the decision and what would reopen it.
#
# WHAT THE RANGE IS, AND WHAT EACH PART OF IT RESTS ON
#
# The range is a claim, so it says which parts are measured and which are
# not. Keeping those apart is the whole point: this project has three times
# caught itself repeating an inherited claim nobody had checked (the
# usb-tablet kext, "DNS needs configuration", security update 2016-001 vs
# 2016-004), and a range that quietly implied a tested compiler would be
# the fourth.
#
#   gcc 13.3.0   VERIFIED. The primary host (docs/host-profile.md §1).
#                Every checksum in decisions/0004 was produced by it,
#                repeatedly, from cold trees.
#   gcc 13, 14   EXPECTED, NOT VERIFIED. Nobody has built with 14. It is
#                inside the range because it is the same compiler series
#                as the verified point, defaults to the same C dialect
#                (gnu17), and the dialect is now stated anyway.
#   gcc 15, 16   NOT VERIFIED, and deliberately ABOVE the ceiling. 15 is
#                the version that motivated this whole piece of work --
#                it defaults to -std=gnu23, under which OpenCorePkg 1.0.7
#                would not compile at all -- and that specific failure is
#                fixed. What has NOT happened is a complete build on any
#                real compiler above 14. The nearest thing is
#                squirrel-zapper, gcc 16.2.1, 2026-09-20: the OpenCore
#                stage built clean in 397 s, which is real evidence that
#                the dialect fix works on a live C23-default compiler,
#                and then the OVMF stage died -- not on anything about
#                gcc 16's code, but on a warning gcc 16 invented
#                (-Werror=unused-but-set-variable=) in MdeModulePkg,
#                under EDK II's -Werror. That is fixed too, by no longer
#                inheriting upstream's -Werror in the firmware builds
#                (boot/build-opencore.sh, boot/patches/0003). Neither fix
#                has been TESTED up here: nobody has yet produced a
#                firmware image on a gcc above 14, and the failure mode
#                that remains -- different code generation, a green build
#                with different bytes -- is the silent one. WHEN A
#                COMPLETE RUN ARRIVES: if it builds and the artifact
#                checksums match, raise MQG_CC_CEILING below, fill in the
#                row in decisions/0004, and update INGREDIENTS.md and
#                host-profile G22 -- all four, or the next reader gets a
#                number with no evidence behind it. (tests/compiler.bats
#                asserts these constants, so the suite will remind you
#                that you are changing a claim.) If it does not build, the
#                ceiling stays and the reason gets written down in the
#                same row.
#   below 13     NOT TESTED. Not "known to fail" -- never tried. A version
#                this project has never seen is not a version to guess
#                about, so it is a refusal rather than a warning.
#
# Majors, not full versions: distro compilers move by major, and the thing
# that bit us (the default C dialect) changes by major. 13.3.0 is the exact
# point that was measured; 13.x as a whole is what is declared.
#
# THE FOUR OUTCOMES, AND WHY THEY DIFFER
#
#   INSIDE   proceed quietly.
#   BELOW    fail. Say what was found, what is required, and that this
#            project has not tested it -- not that it is broken.
#   ABOVE    warn and proceed. Refusing would make this project refuse to
#            build on every new distribution, which is a worse failure than
#            the one it would prevent. But the warning has to say what kind
#            of trouble this is, because up here the failure mode is not an
#            error: OvmfPkg compiled CLEAN under C23 and emitted different
#            firmware bytes. A green build above the ceiling is not proof.
#   UNKNOWN  warn and proceed, naming what could not be parsed. "I cannot
#            tell" is its own answer; reporting it as a pass would be a
#            claim, and as a failure would block a host that is probably
#            fine.
#
# THE OVERRIDE
#
# MQG_COMPILER replaces detection, in the shape MQG_PKG_MANAGER established
# in boot/prereqs.sh and for the same reason: a check whose input comes
# from the environment cannot be tested without a seam, and installing a
# second compiler to test a version comparison is not a reasonable price.
# It takes "<name> <version>", e.g. MQG_COMPILER='gcc 15.1.0'. It is also
# the way out for someone who knows better than this file does -- and it
# moves NOTHING else: boot/build-opencore.sh --compiler still reports the
# real compiler, so an image built with the check talked out of the way has
# a manifest whose two compiler lines disagree, where anyone can see it.

MQG_CC_FAMILY=gcc
MQG_CC_FLOOR=13
MQG_CC_CEILING=14
MQG_CC_VERIFIED=13.3.0

# The declared range as one phrase, so no caller spells it out by hand.
compiler_range_text() {
    printf '%s %s through %s, verified only at %s %s' \
        "$MQG_CC_FAMILY" "$MQG_CC_FLOOR" "$MQG_CC_CEILING" \
        "$MQG_CC_FAMILY" "$MQG_CC_VERIFIED"
}

# The first line of <cc> --version, or nothing at all.
#
# The compiler asked about is the one EDK II will actually run:
# DEF(GCC_X64_PREFIX)gcc, where GCC_X64_PREFIX is ENV(GCC_BIN) -- empty on
# a normal host, so plain `gcc` off PATH. Asking `gcc` rather than reading
# a variable is also what makes a wrapper visible: a shim that prepends a
# flag still answers --version as whatever it wraps, which is exactly how
# the C23 failure was reproduced here.
compiler_banner() {
    local cc=${1:-${GCC_BIN:-}gcc} line
    command -v "$cc" >/dev/null 2>&1 || return 1
    line=$("$cc" --version 2>/dev/null | head -1) || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

# The first field that is a bare dotted number.
#
# Every banner shape this has to survive puts the packaging junk in a field
# that is not a bare number, so "first bare number wins" gets the right
# answer without a per-vendor pattern:
#
#   gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0   -> 13.3.0
#   gcc (GCC) 15.1.1 20250425                     -> 15.1.1
#   Apple clang version 17.0.0 (clang-1700.0.13)  -> 17.0.0
#   gcc 13.3.0                                    -> 13.3.0  (the override)
compiler_version_token() {
    printf '%s\n' "$1" | awk '{
        for (i = 1; i <= NF; i++)
            if ($i ~ /^[0-9]+(\.[0-9]+)*$/) { print $i; exit }
    }'
}

# compiler_parse <banner> -- "<family>\t<version>\t<banner>".
#
# family is gcc, clang or unknown; version is empty when it could not be
# read. clang is checked first and on purpose: on macOS `gcc` IS clang, and
# a banner reading "Apple clang version ..." parsed as GCC would compare a
# clang version number against a GCC range and produce a confident wrong
# answer. clang is a real answer here, just not one the range covers --
# this project builds with TOOLCHAINS=GCC and has never built with clang.
compiler_parse() {
    local banner=$1 first version
    first=${banner%% *}
    case $banner in
        *clang*|*LLVM*)
            version=$(compiler_version_token "$banner")
            printf 'clang\t%s\t%s\n' "$version" "$banner"
            return 0
            ;;
    esac
    case $first in
        gcc|cc|c99|g++|*-gcc|*-g++)
            version=$(compiler_version_token "$banner")
            if [ -n "$version" ]; then
                printf 'gcc\t%s\t%s\n' "$version" "$banner"
                return 0
            fi
            ;;
    esac
    printf 'unknown\t\t%s\n' "$banner"
}

# What to believe this host's compiler is: the override if set, otherwise
# whatever the compiler says about itself. Same three fields as
# compiler_parse; an absent compiler yields unknown with an empty banner,
# which is UNKNOWN and not a failure -- boot/prereqs.sh is what reports a
# missing gcc, and it reports it as one missing tool among twelve.
compiler_identity() {
    local banner
    if [ -n "${MQG_COMPILER:-}" ]; then
        compiler_parse "$MQG_COMPILER"
        return 0
    fi
    banner=$(compiler_banner "$@") || banner=""
    compiler_parse "$banner"
}

# compiler_range_verdict <family> <version> -- "<verdict>\t<detail>".
#
# Pure: no compiler is run and no environment is read, so every branch is
# testable on a host that has exactly one compiler. Judging is separated
# from gathering here for the same reason it is in lib/preconditions.sh.
compiler_range_verdict() {
    local family=$1 version=$2 major
    case $family in
        "$MQG_CC_FAMILY") ;;
        clang)
            printf 'UNKNOWN\tclang %s: this project builds with TOOLCHAINS=GCC and has never built with clang, so the declared range (%s) does not cover it\n' \
                "${version:-(no version)}" "$(compiler_range_text)"
            return 0
            ;;
        *)
            printf 'UNKNOWN\tnot a recognised %s: the range (%s) has nothing to say about it\n' \
                "$MQG_CC_FAMILY" "$(compiler_range_text)"
            return 0
            ;;
    esac
    major=${version%%.*}
    case $major in
        ''|*[!0-9]*)
            printf 'UNKNOWN\tcannot read a major version out of "%s"\n' "$version"
            return 0
            ;;
    esac
    if [ "$major" -lt "$MQG_CC_FLOOR" ]; then
        printf 'BELOW\t%s %s is below the floor of this project'"'"'s supported range, %s\n' \
            "$family" "$version" "$(compiler_range_text)"
    elif [ "$major" -gt "$MQG_CC_CEILING" ]; then
        printf 'ABOVE\t%s %s is above the ceiling of this project'"'"'s supported range, %s\n' \
            "$family" "$version" "$(compiler_range_text)"
    else
        printf 'INSIDE\t%s %s is inside this project'"'"'s supported range, %s\n' \
            "$family" "$version" "$(compiler_range_text)"
    fi
}

# What this host's compiler is and what the range says about it, as one
# "<verdict>\t<detail>" line. Both consumers below go through here, so the
# three-field split from compiler_parse happens in exactly one place.
#
# NOT `IFS=$'\t' read -r family version raw`, which is what this said
# first and which is wrong in a way that takes a test to see: tab is an
# IFS *whitespace* character, so a run of tabs collapses into one
# delimiter. An unparseable compiler yields an empty version field, the two
# adjacent tabs then count as one, and the banner slides left into
# $version -- so the one case this function exists to report is the one
# case it mis-reports. Explicit ${var%%...} / ${var#...} has no such rule.
compiler_range_status() {
    local id tab rest family version raw verdict detail
    tab=$(printf '\t')
    id=$(compiler_identity "$@")
    family=${id%%"$tab"*}
    rest=${id#*"$tab"}
    version=${rest%%"$tab"*}
    raw=${rest#*"$tab"}

    id=$(compiler_range_verdict "$family" "$version")
    verdict=${id%%"$tab"*}
    detail=${id#*"$tab"}

    # An UNKNOWN verdict has to name what it could not read, or it is just
    # a shrug. The two ways of not knowing are different problems: a
    # compiler that said something we cannot parse, and no compiler at all.
    if [ "$verdict" = UNKNOWN ]; then
        if [ -n "$raw" ]; then
            detail="$detail; it said \"$raw\""
        else
            detail="$detail; ${GCC_BIN:-}gcc is not on PATH or did not answer --version"
        fi
    fi

    printf '%s\t%s\n' "$verdict" "$detail"
}

# One line for the image manifest: the verdict this host got at build time.
#
# The manifest already records WHICH compiler built the boot stack. This
# records whether that compiler was one the project claimed to support when
# the image was made -- which the `compiler` line cannot answer later,
# because the range moves as evidence arrives and the image does not. An
# image built above the ceiling should still say so in a year, and an image
# built with the check overridden should say that too.
compiler_range_line() {
    local status tab verdict detail
    tab=$(printf '\t')
    status=$(compiler_range_status "$@")
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}
    if [ -n "${MQG_COMPILER:-}" ]; then
        printf '%s -- %s [MQG_COMPILER override in effect: %s]\n' \
            "$verdict" "$detail" "$MQG_COMPILER"
    else
        printf '%s -- %s\n' "$verdict" "$detail"
    fi
}

# The gate the build scripts call. Dies only below the floor.
compiler_range_check() {
    local status tab verdict detail

    tab=$(printf '\t')
    status=$(compiler_range_status "$@")
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}

    [ -z "${MQG_COMPILER:-}" ] \
        || warn "MQG_COMPILER is set: treating this host's compiler as '$MQG_COMPILER'"

    case $verdict in
        INSIDE)
            log "compiler: $detail"
            ;;
        ABOVE)
            warn "compiler: $detail"
            warn "this is untested territory, not known-bad: building anyway."
            warn "A new compiler's new warnings will no longer stop the firmware build"
            warn "(upstream's -Werror is not inherited -- decisions/0004). They are"
            warn "still printed, and up here they are worth reading."
            warn "WHAT TO WATCH FOR -- up here the failure mode is usually not an error."
            warn "OvmfPkg compiled clean under C23 and produced DIFFERENT firmware bytes"
            warn "(OVMF_CODE.fd 3373692a..., where docs/decisions/0004 records 195c4dcf...)."
            warn "So a green build is not proof you got the artifacts that document"
            warn "describes: compare its checksums against what you built."
            warn "Either answer is worth reporting -- that is how the ceiling moves."
            ;;
        UNKNOWN)
            warn "compiler: $detail"
            warn "proceeding with the range unchecked. If you know what this compiler is,"
            warn "say so: MQG_COMPILER='<name> <version>'."
            ;;
        BELOW)
            warn "compiler: $detail"
            warn "This project has NOT tested it. That is not the same as knowing it fails:"
            warn "nobody has ever tried. The firmware builds no longer inherit"
            warn "upstream's -Werror, so a diagnostic this compiler spells differently"
            warn "is no longer fatal -- but its code generation is still a different"
            warn "artifact than the checksums in docs/decisions/0004 describe."
            warn "To build anyway, say what to believe: MQG_COMPILER='$MQG_CC_FAMILY $MQG_CC_VERIFIED'."
            warn "The image manifest still records the real compiler, so the two lines"
            warn "will disagree where anyone can see them."
            die "unsupported compiler -- $detail"
            ;;
        *)
            die "internal error: unknown compiler verdict '$verdict'"
            ;;
    esac
}
