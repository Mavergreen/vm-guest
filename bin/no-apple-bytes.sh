#!/usr/bin/env bash
# The one conformance check that is ours alone: A RELEASE MUST CONTAIN NO
# APPLE-DERIVED BYTES.
#
# WHY THIS IS A GATE AND NOT A HABIT
#
# "Never publish the guest image" and "the OS comes from Apple only" are
# the two rules this project cannot get wrong once. Both are currently
# satisfied by construction: we ship a recipe, and the recipe fetches
# Apple's InstallESD.dmg at RUNTIME, on the user's machine, from Apple.
# Nothing Apple-derived is ever committed.
#
# Satisfied-by-construction is exactly the condition under which a rule
# quietly stops being true. A 6 GB .dmg committed "just for a minute" to
# debug something, a BaseSystem extract left in a fixtures directory, a
# kext copied out of a guest -- each is one `git add -A` away, and none of
# them looks wrong in a diff that is already large. The cost of checking is
# a second per CI run. The cost of finding out later is a DMCA notice.
#
# WHAT IT CHECKS
#
# Exactly what a release would contain: what `git archive REF` would
# package -- REF's tree, not the working directory. Give it a ref (a tag,
# almost always) and it checks exactly that tree via `git ls-tree`,
# `git cat-file` and `git show REF:path`. Give it nothing and it checks
# the index instead, which is today's pre-release approximation of the
# same tree. Either way, an untracked InstallESD.dmg beside the repo is
# how this project is MEANT to work (see decisions/0003: images live on
# local disk, outside the repo) and must never redden either mode.
#
# A ref that does not resolve is a FAILURE, not a pass: cannot-verify is
# not the same answer as verified-clean, and a release gate that
# green-lights because it could not find the tag is worse than no gate.
#
#   usage: bin/no-apple-bytes.sh [ref]     (default: the working tree's index)
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=no-apple-bytes

cd "$MQG_REPO_ROOT"

git rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git repository -- a release is what git would archive," \
           "so there is nothing to check here"

MQG_NAB_REF=${1:-}
if [ -n "$MQG_NAB_REF" ]; then
    git rev-parse --verify --quiet "${MQG_NAB_REF}^{commit}" >/dev/null \
        || die "no such ref: $MQG_NAB_REF -- cannot verify a release that" \
               "does not resolve, which is a failure, never a pass"
fi

# The three primitives, switched once on whether a ref was given, so every
# check below reads the same regardless of mode. Ref mode is exactly what
# `git archive` packages; no-ref mode is the index, today's behavior.
list_tracked() {
    if [ -n "$MQG_NAB_REF" ]; then
        git ls-tree -r --name-only "$MQG_NAB_REF"
    else
        git ls-files
    fi
}

blob_show() {  # $1 = path -- the committed content, never the working tree
    if [ -n "$MQG_NAB_REF" ]; then
        git show "$MQG_NAB_REF:$1" 2>/dev/null
    else
        git show ":$1" 2>/dev/null
    fi
}

blob_size() {  # $1 = path
    if [ -n "$MQG_NAB_REF" ]; then
        git cat-file -s "$MQG_NAB_REF:$1" 2>/dev/null
    else
        git cat-file -s ":$1" 2>/dev/null
    fi
}

status=0
flag() {
    printf 'APPLE-DERIVED  %s\n' "$1" >&2
    printf '               %s\n' "$2" >&2
    status=1
}

# 1. Shapes. A disk image, an installer package or a kext bundle in the
#    tracked tree is, in this project, almost certainly Apple's -- and the
#    one package we DO build (image/payload/) is built at runtime into
#    $MQG_IMAGE_DIR, never committed. The exceptions list is deliberately
#    empty; an entry here would need a reason in INGREDIENTS.md's
#    deviations block, like any other.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case $f in
        *.dmg|*.DMG|*.sparseimage|*.sparsebundle)
            flag "$f" "a disk image -- Apple's OS media never enters this repo" ;;
        *.pkg|*.mpkg)
            flag "$f" "an installer package -- ours are built at runtime into \$MQG_IMAGE_DIR" ;;
        *.kext|*.kext/*)
            flag "$f" "a kernel extension bundle" ;;
        *.iso|*.cdr|*.img)
            flag "$f" "an optical/disk image" ;;
        *InstallESD*|*BaseSystem*|*OSInstall.mpkg*)
            flag "$f" "named after part of Apple's installer" ;;
    esac
done < <(list_tracked)

# 2. Bytes. A renamed blob defeats the list above, so look at the first
#    few bytes of every tracked file that is not plainly text. These are
#    the magic numbers of the things this project handles.
#
#    The committed content of each file (via `blob_show`), never the
#    working tree, because the release is made from what is COMMITTED. A
#    file whose working copy was cleaned up but whose committed version is
#    a 6 GB dmg still ships one -- and in ref mode, "committed" means AT
#    THAT REF, which may differ from what the index holds today.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    head4=$(blob_show "$f" | head -c 4 | od -An -tx1 | tr -d ' \n') || continue
    case $head4 in
        # "koly" is the HFS+ disk-image trailer, but an Apple .dmg starts
        # with either the UDIF header or zlib; check for the ones that are
        # unambiguous at offset 0.
        78617221)  # "xar!" -- a flat package
            flag "$f" "starts with xar! -- a flat installer package" ;;
        482b0004|48580005)  # "H+", "HX" -- a bare HFS+/HFSX volume
            flag "$f" "starts with an HFS+ volume signature" ;;
        6b6f6c79)  # "koly"
            flag "$f" "starts with koly -- a UDIF disk image trailer" ;;
        cafebabe|cffaedfe|cefaedfe)  # Mach-O, fat or thin
            flag "$f" "is a Mach-O binary -- this repository ships source, not binaries" ;;
    esac
done < <(list_tracked)

# 3. Size. Nothing legitimate here is large, and every Apple artifact is.
#    A 6 GB blob under another name and with a scrubbed header is still a
#    6 GB blob, and this catches it without knowing what it is.
MAX_TRACKED_BYTES=${MQG_MAX_TRACKED_BYTES:-2097152}
while IFS= read -r f; do
    [ -n "$f" ] || continue
    size=$(blob_size "$f") || continue
    if [ "$size" -gt "$MAX_TRACKED_BYTES" ]; then
        flag "$f" "$size bytes -- nothing this project authors is that large;" \
             "if it is genuinely ours, raise MQG_MAX_TRACKED_BYTES with a reason"
    fi
done < <(list_tracked)

# 4. The registry's own statement. vendor/sources.tsv names Apple's
#    InstallESD as a URL fetched at runtime. If it ever named a path
#    inside the repository instead, the rule would be broken by the
#    registry rather than by a file.
#
#    Read via `blob_show`, not off disk -- the registry AT THE REF being
#    checked is what matters, not whatever the working tree happens to
#    hold right now.
registry_content=$(blob_show vendor/sources.tsv) || registry_content=""
if printf '%s\n' "$registry_content" | grep -q '^apple-'; then
    while IFS=$'\t' read -r name url _; do
        case $name in apple-*) : ;; *) continue ;; esac
        case $url in
            http://*|https://*) : ;;
            *) flag "vendor/sources.tsv:$name" \
                    "points at $url, not at a URL -- Apple's media must be" \
                    "fetched at runtime, never carried" ;;
        esac
    done <<EOF
$registry_content
EOF
fi

if [ "$status" -eq 0 ]; then
    log "no Apple-derived bytes in the tracked tree ($(list_tracked | wc -l) files)"
else
    die "the tracked tree carries Apple-derived bytes. A release of this" \
        "project is a RECIPE: it fetches Apple's media at runtime, on the" \
        "user's machine, and carries none of it. See README.md's ground rules."
fi
