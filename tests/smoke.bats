#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "disk images are ignored wherever they appear" {
    for f in work/scratch.qcow2 golden/base.qcow2 media/images/installer.img \
             media/images/installer.dmg some.iso; do
        run git -C "$REPO" check-ignore -q "$f"
        [ "$status" -eq 0 ] || { echo "not ignored: $f"; return 1; }
    done
}

@test "source files are not ignored" {
    for f in lib/common.sh vm/run.sh boot/build-opencore.sh; do
        run git -C "$REPO" check-ignore -q "$f"
        [ "$status" -eq 0 ] && { echo "wrongly ignored: $f"; return 1; }
    done
    return 0
}
