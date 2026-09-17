#!/usr/bin/env bash
# Report whether this host can build OpenCore. Installs nothing.
#
# Installing host packages is a stop-and-ask in this project's design, so
# this script deliberately only reports. It prints the apt line to run, and
# a human decides.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

# tool:package -- the binary we need, and the Debian package providing it.
REQUIRED=(
    "gcc:build-essential"
    "make:build-essential"
    "git:git"
    "python3:python3"
    "nasm:nasm"
    "iasl:acpica-tools"
    "mcopy:mtools"
    "mformat:mtools"
    "sgdisk:gdisk"
)

missing_pkgs=()
missing_any=0

for entry in "${REQUIRED[@]}"; do
    tool=${entry%%:*}
    pkg=${entry#*:}
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'PASS  %-10s %s\n' "$tool" "$(command -v "$tool")"
    else
        printf 'MISS  %-10s (package: %s)\n' "$tool" "$pkg"
        missing_any=1
        case " ${missing_pkgs[*]-} " in
            *" $pkg "*) ;;
            *) missing_pkgs+=("$pkg") ;;
        esac
    fi
done

echo
if [ "$missing_any" -eq 0 ]; then
    log "build prerequisites: all present"
    exit 0
fi

warn "missing build prerequisites"
warn "this script does not install anything -- that is a decision for a human"
printf '\n    sudo apt install %s\n\n' "${missing_pkgs[*]}"
exit 1
