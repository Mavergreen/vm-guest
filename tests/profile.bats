#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/profile.sh"
    PROFILE_DIR="$BATS_TEST_TMPDIR/profiles"
    MQG_REPO_ROOT="/fake/repo"
    MQG_IMAGE_DIR="/fake/images"
    MQG_VENDOR_DIR="/fake/vendor-reference"
    mkdir -p "$PROFILE_DIR"
}

@test "profile_expand emits one argument per line" {
    printf '%s\n' '-enable-kvm' '-m' '4096' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-enable-kvm" ]
    [ "${lines[1]}" = "-m" ]
    [ "${lines[2]}" = "4096" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "profile_expand skips full-line comments and blank lines" {
    printf '%s\n' '# a comment' '' '-enable-kvm' '   # indented comment' \
        > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "-enable-kvm" ]
}

@test "profile_expand keeps a hash that is not at the start of a line" {
    printf '%s\n' '-fw_cfg' 'name=opt/x,string=a#b' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[1]}" = 'name=opt/x,string=a#b' ]
}

@test "profile_expand trims surrounding whitespace" {
    printf '%s\n' '   -enable-kvm   ' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[0]}" = "-enable-kvm" ]
}

@test "profile_expand resolves @include in place" {
    printf '%s\n' '-enable-kvm' > "$PROFILE_DIR/base.args"
    printf '%s\n' '@include base' '-m' '4096' > "$PROFILE_DIR/derived.args"
    run profile_expand derived
    [ "${lines[0]}" = "-enable-kvm" ]
    [ "${lines[1]}" = "-m" ]
    [ "${lines[2]}" = "4096" ]
}

@test "profile_expand resolves nested includes" {
    printf '%s\n' '-enable-kvm' > "$PROFILE_DIR/a.args"
    printf '%s\n' '@include a' '-m' > "$PROFILE_DIR/b.args"
    printf '%s\n' '@include b' '4096' > "$PROFILE_DIR/c.args"
    run profile_expand c
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[2]}" = "4096" ]
}

@test "profile_expand detects an include cycle instead of looping forever" {
    printf '%s\n' '@include b' > "$PROFILE_DIR/a.args"
    printf '%s\n' '@include a' > "$PROFILE_DIR/b.args"
    run profile_expand a
    [ "$status" -ne 0 ]
    [[ "$output" == *"cycle"* ]]
}

@test "profile_expand fails for a missing profile and names it" {
    run profile_expand nosuch
    [ "$status" -ne 0 ]
    [[ "$output" == *"nosuch"* ]]
}

@test "profile_expand substitutes %REPO% with the repository root" {
    printf '%s\n' '-drive' 'file=%REPO%/boot/opencore.efi' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[1]}" = "file=/fake/repo/boot/opencore.efi" ]
}

@test "profile_expand substitutes %IMAGES% with the image directory" {
    printf '%s\n' '-drive' 'file=%IMAGES%/work/disk.qcow2' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[1]}" = "file=/fake/images/work/disk.qcow2" ]
}

@test "profile_expand substitutes %VENDOR% with the vendor quarantine directory" {
    printf '%s\n' '-drive' 'file=%VENDOR%/opencore-legacy/EFI-LEGACY.img' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[1]}" = "file=/fake/vendor-reference/opencore-legacy/EFI-LEGACY.img" ]
}

@test "profile_expand substitutes all three tokens on one line" {
    printf '%s\n' 'a=%REPO%/x,b=%IMAGES%/y,c=%VENDOR%/z' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[0]}" = "a=/fake/repo/x,b=/fake/images/y,c=/fake/vendor-reference/z" ]
}

@test "profile_expand resolves @include with trailing whitespace after the name" {
    printf '%s\n' '-enable-kvm' > "$PROFILE_DIR/base.args"
    printf '%s\n' '@include base   ' > "$PROFILE_DIR/derived.args"
    run profile_expand derived
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-enable-kvm" ]
}

@test "profile_expand rejects a bare @include with no name" {
    printf '%s\n' '@include' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -ne 0 ]
    [[ "$output" == *"@include"* ]]
}

@test "profile_expand rejects @include followed only by whitespace" {
    printf '%s\n' '@include ' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -ne 0 ]
    [[ "$output" == *"@include"* ]]
}

@test "profile_expand rejects a profile including itself directly" {
    printf '%s\n' '@include a' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -ne 0 ]
    [[ "$output" == *"cycle"* ]]
}

@test "profile_expand allows diamond includes without falsely reporting a cycle" {
    printf '%s\n' '-shared' > "$PROFILE_DIR/a.args"
    printf '%s\n' '@include a' > "$PROFILE_DIR/b.args"
    printf '%s\n' '@include a' > "$PROFILE_DIR/c.args"
    printf '%s\n' '@include b' '@include c' > "$PROFILE_DIR/d.args"
    run profile_expand d
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "-shared" ]
    [ "${lines[1]}" = "-shared" ]
}

@test "profile_expand strips a trailing carriage return from CRLF line endings" {
    printf '%s\r\n' '-enable-kvm' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "${lines[0]}" = "-enable-kvm" ]
    [[ "${lines[0]}" != *$'\r' ]]
}

@test "profile_expand does not require MQG_IMAGE_DIR for a profile that never uses %IMAGES%" {
    unset MQG_IMAGE_DIR
    printf '%s\n' '-enable-kvm' '-m' '4096' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "profile_expand still fails for an unset MQG_IMAGE_DIR when %IMAGES% is used" {
    unset MQG_IMAGE_DIR
    printf '%s\n' 'file=%IMAGES%/work/disk.qcow2' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -ne 0 ]
}

@test "profile_expand does not require MQG_VENDOR_DIR for a profile that never uses %VENDOR%" {
    unset MQG_VENDOR_DIR
    printf '%s\n' '-enable-kvm' '-m' '4096' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "profile_expand still fails for an unset MQG_VENDOR_DIR when %VENDOR% is used" {
    unset MQG_VENDOR_DIR
    printf '%s\n' 'file=%VENDOR%/opencore-legacy/EFI-LEGACY.img' > "$PROFILE_DIR/a.args"
    run profile_expand a
    [ "$status" -ne 0 ]
}
