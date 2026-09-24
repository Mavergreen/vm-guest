#!/usr/bin/env bats
# vm/screenshot.sh -- the verdict, which is the part anyone reads.

setup() {
    REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export REPO
    SHOT=$BATS_TEST_TMPDIR/shot
    export SHOT
}

# Write a P6 PPM with a given number of distinct colours and a given
# fraction of non-black pixels.
make_ppm() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
out, ncol, frac = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
w = h = 200
n = w * h
lit = int(n * frac)
px = bytearray()
for i in range(n):
    if i < lit:
        if ncol <= 2:
            px += b"\xff\xff\xff"
        else:
            px += bytes([(i * 37) % 256, (i * 11) % 256, 200])
    else:
        px += b"\x00\x00\x00"
open(out, "wb").write(b"P6\n%d %d\n255\n" % (w, h) + bytes(px))
PY
}

# Run only the verdict block of screenshot.sh against a PPM.
verdict_of() {
    sed -n '/^python3 - "\$base.ppm" <<.PY.$/,/^PY$/p' "$REPO/vm/screenshot.sh" \
        | sed -e '1d' -e '$d' > "$BATS_TEST_TMPDIR/verdict.py"
    python3 "$BATS_TEST_TMPDIR/verdict.py" "$1" 2>&1
}

@test "a kernel panic reads as text, not as graphical" {
    # The one that was wrong. OS X's panic screen is white-on-black: 2
    # colours and about 9.6% lit, measured on ap-juicer and pet-power-plant
    # on 2026-09-21. The old rule was "under 5% lit is text", so 9.6% came
    # out as "graphical" -- the single word most likely to make a reader
    # believe the guest was healthy.
    make_ppm "$SHOT.ppm" 2 0.096
    run verdict_of "$SHOT.ppm"
    [[ "$output" == *"2 colours"* ]]
    [[ "$output" == *text* ]]
    [[ "$output" != *graphical* ]]
}

@test "a blank screen is blank, and one colour is what makes it blank" {
    make_ppm "$SHOT.ppm" 1 0.0
    run verdict_of "$SHOT.ppm"
    [[ "$output" == *blank* ]]
}

@test "white-on-black text is not mistaken for a blank screen" {
    # The P3 mistake, in the other direction: reading a low colour count as
    # "nothing on screen" cost an hour, a firmware bisection and four CPU
    # tests. Two colours is text. One colour is blank.
    make_ppm "$SHOT.ppm" 2 0.004
    run verdict_of "$SHOT.ppm"
    [[ "$output" == *text* ]]
    [[ "$output" != *blank* ]]
}

@test "a drawn desktop is graphical" {
    make_ppm "$SHOT.ppm" 5000 0.99
    run verdict_of "$SHOT.ppm"
    [[ "$output" == *graphical* ]]
}

@test "the verdict needs no PIL" {
    # It used to sit inside `if python3 -c 'import PIL'`, so a host without
    # python3-pil printed "python3-pil not installed; leaving PPM" instead
    # of saying what was on the screen -- on ap-juicer that happened every
    # four minutes for an hour, during the one run whose whole question was
    # whether the guest had panicked.
    grep -q 'THE VERDICT IS COMPUTED FROM THE RAW PPM' "$REPO/vm/screenshot.sh"
    # The verdict block comes before the PIL check, not inside it.
    v=$(grep -n 'THE VERDICT IS COMPUTED FROM THE RAW PPM' "$REPO/vm/screenshot.sh" | head -1 | cut -d: -f1)
    p=$(grep -n "if python3 -c 'import PIL'" "$REPO/vm/screenshot.sh" | head -1 | cut -d: -f1)
    [ "$v" -lt "$p" ]
    # And the no-PIL branch says the verdict still happened.
    grep -q 'the verdict above is unaffected' "$REPO/vm/screenshot.sh"
}

# --- vmavs ssh, run, clone --------------------------------------------------

@test "vmavs ssh --dry-run prints the command and starts nothing" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == ssh\ * ]]
    [[ "$output" == *"-p 2222"* ]]
    [[ "$output" == *"mavsuser@127.0.0.1"* ]]
}

@test "vmavs ssh disables host key checking, because every clone has new keys" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null
    [[ "$output" == *"StrictHostKeyChecking=no"* ]]
    [[ "$output" == *"UserKnownHostsFile=/dev/null"* ]]
}

@test "vmavs ssh uses only the key it was given" {
    # Without IdentitiesOnly a loaded agent offers every key it holds and
    # the server closes the connection on MaxAuthTries before reaching the
    # one the image authorized.
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null
    [[ "$output" == *"IdentitiesOnly=yes"* ]]
}

@test "vmavs ssh honours --port, --user and --key" {
    run "$REPO/bin/vmavs" ssh --dry-run --port 2299 --user ci --key /dev/null
    [[ "$output" == *"-p 2299"* ]]
    [[ "$output" == *"ci@127.0.0.1"* ]]
}

@test "vmavs ssh passes everything after -- to ssh" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null -- uname -a
    [[ "$output" == *"uname -a"* ]]
}

@test "vmavs ssh refuses a key that is not there, naming it" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /nonexistent/id_ed25519
    [ "$status" -ne 0 ]
    [[ "$output" == *"/nonexistent/id_ed25519"* ]]
}

@test "vmavs ssh defaults its key from \$MQG_SSH_KEY when no --key is given" {
    run env MQG_SSH_KEY=/dev/null "$REPO/bin/vmavs" ssh --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"-i /dev/null"* ]]
}

@test "vmavs ssh finds a default key the same way build-image.sh's resolve_ssh_key does" {
    # resolve_ssh_key (image/build-image.sh) picks the PUBLIC key it
    # authorizes in the image by searching $HOME/.ssh/id_*.pub, then
    # $MQG_IMAGE_DIR/keys/*.pub. vmavs ssh needs the PRIVATE half of
    # whichever one that would have picked -- not a guess from a different
    # search -- so it must find this pair through the same search, in the
    # same order.
    mkdir -p "$BATS_TEST_TMPDIR/home/.ssh"
    printf 'private\n' > "$BATS_TEST_TMPDIR/home/.ssh/id_ed25519"
    printf 'public\n' > "$BATS_TEST_TMPDIR/home/.ssh/id_ed25519.pub"
    run env HOME="$BATS_TEST_TMPDIR/home" \
        MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/images" \
        "$REPO/bin/vmavs" ssh --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"-i $BATS_TEST_TMPDIR/home/.ssh/id_ed25519 "* ]]
}

@test "vmavs run lists the profiles when given none" {
    run "$REPO/bin/vmavs" run
    [ "$status" -ne 0 ]
    [[ "$output" == *"p4-linuxmedia"* ]]
}

@test "vmavs clone reaches vm/clone.sh" {
    run "$REPO/bin/vmavs" clone
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* || "$output" == *"golden"* ]]
}
