# shellcheck shell=bash
# Host precondition verdicts.
#
# Each *_verdict function takes an already-gathered fact and returns a line
# of the form "<PASS|WARN|FAIL>\t<name>\t<detail>". Gathering is separated
# from judging so the judging can be tested without a particular host.
#
# Requires lib/common.sh to be sourced first.

check_result() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

cpu_vendor_verdict() {
    case $1 in
        GenuineIntel)
            check_result PASS cpu-vendor "Intel: the documented KVM path" ;;
        AuthenticAMD)
            check_result FAIL cpu-vendor \
                "AMD is a known-harder case for macOS guests; stop and ask" ;;
        *)
            check_result FAIL cpu-vendor "unrecognised CPU vendor: $1" ;;
    esac
}

vmx_verdict() {
    if [ "$1" = "yes" ]; then
        check_result PASS vmx "VT-x present"
    else
        check_result FAIL vmx "no VT-x; KVM acceleration unavailable"
    fi
}

kvm_device_verdict() {
    if [ -w "$1" ]; then
        check_result PASS kvm-device "$1 is writable by this user"
    elif [ -e "$1" ]; then
        check_result FAIL kvm-device \
            "$1 exists but is not writable; is this user in group kvm?"
    else
        check_result FAIL kvm-device "$1 does not exist"
    fi
}

# Somlo and OSX-KVM both require ignore_msrs. Setting it needs sudo, which
# is an ask -- so this warns rather than fails, and says what to do.
ignore_msrs_verdict() {
    if [ "$1" = "Y" ]; then
        check_result PASS ignore-msrs "kvm.ignore_msrs is enabled"
    else
        check_result WARN ignore-msrs \
            "kvm.ignore_msrs is '$1'; required by prior art. Needs sudo: ask before running 'echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs'"
    fi
}

ovmf_verdict() {
    local dir=$1
    if [ -f "$dir/OVMF_CODE_4M.fd" ] && [ -f "$dir/OVMF_VARS_4M.fd" ]; then
        check_result PASS ovmf "4M split CODE/VARS found in $dir"
    elif [ -f "$dir/OVMF.fd" ]; then
        check_result PASS ovmf "combined OVMF.fd found in $dir"
    else
        check_result FAIL ovmf "no usable OVMF firmware in $dir"
    fi
}

tool_verdict() {
    local tool=$1
    if command -v "$tool" >/dev/null 2>&1; then
        check_result PASS "tool:$tool" "$(command -v "$tool")"
    else
        check_result FAIL "tool:$tool" "not installed"
    fi
}

# Matched in-process rather than by piping into `grep -q`. grep -q exits on
# the first match, SIGPIPEing the writer; under `set -o pipefail` (which
# bin/preconditions.sh sets) the pipeline then reports 141 and this function
# would return 0 -- reporting GO *because* it found a FAIL. Same bug bit
# bin/tier-check.sh. No pipe, no signal, no surprise.
verdicts_exit_code() {
    case $1 in
        FAIL*|*"
FAIL"*) return 1 ;;
    esac
    return 0
}
