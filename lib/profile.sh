# shellcheck shell=bash
# Profiles: QEMU configuration as composable plain text.
#
# One argument per line, so quoting never enters the picture. Full-line
# comments start with '#'. '@include <name>' pulls in another profile.
# '%REPO%' expands to the repository root, '%IMAGES%' to the image
# directory -- which is deliberately NOT under the repo, because the repo
# is on NFS and a guest disk must not be.
#
# The point of the format is that an experiment is a diff. Changing one
# variable at a time is only verifiable if the change is a file change.
#
# Requires lib/common.sh. Callers set PROFILE_DIR, MQG_REPO_ROOT and
# MQG_IMAGE_DIR.

profile_path() {
    printf '%s/%s.args\n' "${PROFILE_DIR:?PROFILE_DIR is unset}" "$1"
}

# profile_expand <name> [include-chain]
#
# include-chain is the colon-delimited list of ancestor profile names
# currently being expanded -- i.e. the path from the top-level call down to
# (but not including) this call. It is deliberately not a "seen" set: a
# diamond (d includes b and c, both of which include a) must expand a's
# contents twice without being mistaken for a cycle, since this is textual
# inclusion, not idempotent import. Only an ancestor of the current call is
# a cycle.
profile_expand() {
    local name=$1 chain=${2:-} path line included

    case ":$chain:" in
        *":$name:"*) die "profile include cycle: $chain -> $name" ;;
    esac

    path=$(profile_path "$name")
    [ -f "$path" ] || die "no such profile: $name (looked for $path)"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
        line="${line%"${line##*[![:space:]]}"}"   # strip trailing whitespace
        [ -n "$line" ] || continue
        case $line in
            '#'*)
                continue ;;
            '@include')
                die "@include with no profile name in $path" ;;
            '@include '*)
                included="${line#@include }"
                included="${included#"${included%%[![:space:]]*}"}"
                [ -n "$included" ] \
                    || die "@include with no profile name in $path"
                profile_expand "$included" "$chain:$name" ;;
            *)
                case $line in *'%REPO%'*)
                    line="${line//'%REPO%'/${MQG_REPO_ROOT:?MQG_REPO_ROOT is unset}}" ;;
                esac
                case $line in *'%IMAGES%'*)
                    line="${line//'%IMAGES%'/${MQG_IMAGE_DIR:?MQG_IMAGE_DIR is unset}}" ;;
                esac
                printf '%s\n' "$line" ;;
        esac
    done < "$path"
}

# List every profile name.
profile_list() {
    local p
    for p in "${PROFILE_DIR:?PROFILE_DIR is unset}"/*.args; do
        [ -e "$p" ] || continue
        basename "$p" .args
    done
}
