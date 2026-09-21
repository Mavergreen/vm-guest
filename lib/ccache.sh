# shellcheck shell=bash
# ccache for the firmware builds: detected, optional, off until somebody
# proves it changes nothing. Sourced, never executed; needs lib/common.sh
# first for log/warn/die.
#
# WHY THIS EXISTS
#
# The OpenCore and OVMF builds are about fourteen minutes of `gcc`, and
# bin/triangulate.sh's entire purpose is repeated runs. EDK II shells out
# to the compiler through generated makefiles and finds it on PATH -- the
# toolchain definition runs DEF(GCC_X64_PREFIX)gcc, and GCC_X64_PREFIX is
# ENV(GCC_BIN), empty on a normal host -- so a `gcc` on PATH that happens
# to be `ccache gcc` is all it takes. That seam is already ours: it is
# where the C dialect and -Wno-error are injected.
#
# WHY IT IS OFF BY DEFAULT, WHICH IS THE PART TO READ
#
# docs/decisions/0004's central claim is that this boot stack is
# reproducible: the same pinned sources, translated by the same compiler,
# produce the same eight checksums. A build-speed tool that altered the
# output would be a much bigger finding than a slow build, and the way this
# project has settled every other question of that shape -- the compiler
# range in lib/compiler.sh, the CPU table in lib/cpu.sh -- is to declare
# what has been measured and refuse to imply the rest.
#
# Nobody has measured this one. ccache is not installed on the primary
# host, so the comparison the change deserves -- a cache hit against a cold
# compile -- could not be run when this was written.
#
# What WAS run is the SEAM, which is the part of the risk this code
# introduces: two cold boot-stack builds, same host, same compiler, same
# UTC day and the same build directory, one straight and one with a
# stand-in `ccache` that does nothing but exec what it was handed. All
# eight checksums matched. (The build directory has to be held constant:
# EDK II writes each module's debug-symbol path into the PE image, so
# MQG_BUILD_DIR is an input -- found by getting eight differences out of
# the first attempt at this comparison. NOTES.md, 2026-09-21.)
#
# So the mechanism is here and complete, and the switch is off:
#
#   MQG_CCACHE=1   use ccache if it is installed
#   MQG_CCACHE=0   do not, which is also what happens when it is unset
#
# WHEN A COMPLETE RUN ARRIVES: build the boot stack cold twice on a host
# that has ccache, once each way, compare all eight checksums (remembering
# that OpenCore.efi embeds its build date, so the two builds must be on the
# same UTC day -- that wrinkle is two bytes and is expected, not evidence),
# and if they match, change MQG_CCACHE_DEFAULT below to 1, fill in the row
# in NOTES.md and update INGREDIENTS.md. All three, or the next reader gets
# a default with no evidence behind it. tests/ccache.bats asserts the
# default, so the suite will remind you that you are changing a claim.
#
# WHERE THE CACHE GOES
#
# Under $MQG_BUILD_DIR, never the repository. A ccache directory is
# thousands of small files and the repo is NFS at 9-15 ms per file create,
# which would make caching slower than not caching. Putting it in the build
# tree also means one decision covers it: `bin/triangulate.sh --keep-build`
# keeps the build tree, and keeps the cache with it.

# The default, as a constant, so the test that asserts it fails loudly when
# someone changes a claim rather than a line.
MQG_CCACHE_DEFAULT=0

# ccache_wanted -- what the environment asked for: 1, 0, or the default.
#
# Anything unrecognised is a 0 with a warning rather than a failure:
# a misspelled build-speed knob must not stop a build.
ccache_wanted() {
    case ${MQG_CCACHE:-} in
        "")        printf '%s\n' "$MQG_CCACHE_DEFAULT" ;;
        1|on|yes)  printf '1\n' ;;
        0|off|no)  printf '0\n' ;;
        *)
            warn "MQG_CCACHE='$MQG_CCACHE' is not 1 or 0; not using ccache"
            printf '0\n' ;;
    esac
}

# ccache_path -- where ccache is, or nothing.
#
# MQG_CCACHE_BIN replaces the lookup, in the shape MQG_COMPILER and
# MQG_PKG_MANAGER established and for the same reason: a code path whose
# input is "is this program installed" cannot be tested on a host that
# answers one way, and installing a program to test a detection is not a
# reasonable price.
ccache_path() {
    if [ -n "${MQG_CCACHE_BIN:-}" ]; then
        [ -x "$MQG_CCACHE_BIN" ] || return 0
        printf '%s\n' "$MQG_CCACHE_BIN"
        return 0
    fi
    command -v ccache 2>/dev/null || true
}

# ccache_verdict <wanted> <path> -- "<verdict>\t<detail>".
#
# Pure: nothing is run and no environment is read, so every branch is
# testable on a host that has ccache and on one that does not. Same split
# between gathering and judging as lib/compiler.sh and lib/preconditions.sh.
#
#   USED     asked for, and present.
#   MISSING  asked for, and not installed. Warn and build anyway: an
#            absent build-speed tool must never fail a build.
#   OFF      not asked for. The detail says whether it is even here,
#            because "you could turn this on" and "install it first" are
#            different pieces of advice.
ccache_verdict() {
    local wanted=$1 path=$2
    if [ "$wanted" = 1 ]; then
        if [ -n "$path" ]; then
            printf 'USED\t%s\n' "$path"
        else
            printf 'MISSING\tMQG_CCACHE=1 but ccache is not installed; compiling everything\n'
        fi
        return 0
    fi
    if [ -n "$path" ]; then
        printf 'OFF\tccache is installed at %s but not used: set MQG_CCACHE=1. The default is off because nobody has yet shown that a ccache build produces the same eight checksums as a cold one -- see lib/ccache.sh\n' \
            "$path"
    else
        printf 'OFF\tccache is not installed; every file is compiled\n'
    fi
}

# ccache_status -- the verdict for this host and this environment.
ccache_status() { ccache_verdict "$(ccache_wanted)" "$(ccache_path)"; }

# One line for the image manifest, and for a build script's log.
#
# Recorded even though the claim is that it changes nothing, for the same
# reason `compiler` is recorded even though it is not pinned: if a ccache
# build ever does produce different bytes, the manifests are what say which
# images were built that way. An unverified claim that leaves no trace is
# an unverifiable one.
ccache_line() {
    local status tab verdict detail
    tab=$(printf '\t')
    status=$(ccache_status)
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}
    case $verdict in
        USED) printf 'used (%s)\n' "$detail" ;;
        *)    printf 'not used -- %s\n' "$detail" ;;
    esac
}

# ccache_shim_dir <dir> <ccache> -- write `gcc` and `g++` wrappers into
# <dir> and print it.
#
# A PATH shim rather than GCC_BIN, which is the other seam EDK II offers:
# GCC_X64_PREFIX is glued in front of `ld`, `objcopy` and `ar` as well as
# the compilers, so pointing it at a directory holding two wrappers would
# hide the rest of binutils. A shim that only shadows `gcc` and `g++`
# leaves everything else exactly where the build already found it.
#
# The real compiler is resolved HERE, before the shim directory is on PATH,
# and written into the wrapper as an absolute path. A wrapper that said
# `exec ccache gcc` would find itself.
ccache_shim_dir() {
    local dir=$1 ccache=$2 tool real
    mkdir -p "$dir" || die "cannot create the ccache shim directory $dir"
    for tool in gcc g++; do
        real=$(command -v "$tool" 2>/dev/null) || real=
        # No such compiler: leave the name unshadowed rather than writing a
        # wrapper around nothing. The build will fail on the missing tool
        # itself, which is a better error than one about our wrapper.
        [ -n "$real" ] || continue
        case $real in
            "$dir"/*) continue ;;
        esac
        printf '#!/bin/sh\nexec %s %s "$@"\n' "$ccache" "$real" > "$dir/$tool"
        chmod 755 "$dir/$tool"
    done
    printf '%s\n' "$dir"
}

# ccache_setup -- report, and if it is on, put the shims on PATH.
#
# Called by both firmware builds. Exports PATH and CCACHE_DIR into the
# caller's environment on purpose: the compiler is run by a makefile three
# processes down, and the environment is the only thing that reaches it.
ccache_setup() {
    local status tab verdict detail path dir
    tab=$(printf '\t')
    status=$(ccache_status)
    verdict=${status%%"$tab"*}
    detail=${status#*"$tab"}

    case $verdict in
        USED) ;;
        MISSING)
            warn "ccache: $detail"
            return 0 ;;
        *)
            log "ccache: $detail"
            return 0 ;;
    esac

    path=$detail
    dir=${MQG_CCACHE_SHIM_DIR:-${MQG_BUILD_DIR:?MQG_BUILD_DIR must be set}/ccache-bin}
    CCACHE_DIR=${MQG_CCACHE_DIR:-${MQG_BUILD_DIR}/ccache}
    export CCACHE_DIR
    mkdir -p "$CCACHE_DIR" || die "cannot create the ccache directory $CCACHE_DIR"
    dir=$(ccache_shim_dir "$dir" "$path")
    PATH="$dir:$PATH"
    export PATH
    log "ccache: $path, cache in $CCACHE_DIR, shims in $dir"
    log "ccache: the compiler recorded in the manifest is still the real one --" \
        "a shim answers --version as whatever it wraps"
}

# What the cache did, after a build. Version-independent: ccache's -s
# output has been reorganised more than once, so this prints its first
# lines rather than parsing them into a number that might be the wrong one.
ccache_stats() {
    local path
    path=$(ccache_path)
    [ -n "$path" ] || return 0
    [ "$(ccache_wanted)" = 1 ] || return 0
    "$path" -s 2>/dev/null | sed -n '1,8p' | sed 's/^/ccache: /' >&2 || true
}
