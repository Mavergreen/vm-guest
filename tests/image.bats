#!/usr/bin/env bats
#
# image/build-image.sh -- the one command that turns a clean checkout into a
# bootable image. Nothing here boots a VM: these are the checks that can be
# made in milliseconds, so that the ones that cost a quarter of an hour are
# only ever spent on questions they can actually answer.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    BUILD="$REPO/image/build-image.sh"
    export MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/images"
}

@test "build-image.sh --describe lists its stages without doing anything" {
    run "$BUILD" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"media"* ]]
    [[ "$output" == *"install"* ]]
    [[ "$output" == *"payload"* ]]
    # --describe must not create the image directory it describes.
    [ ! -d "$MQG_IMAGE_DIR/images" ]
}

@test "build-image.sh rejects an unknown accelerator" {
    run "$BUILD" --accel nonsense --describe
    [ "$status" -ne 0 ]
    [[ "$output" == *"accel"* ]]
}

@test "build-image.sh accepts both accelerators the project uses" {
    # P6 runs this same pipeline under TCG on arm64. A second pipeline
    # would be a second thing to keep correct.
    run "$BUILD" --accel kvm --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"kvm"* ]]
    run "$BUILD" --accel tcg --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"tcg"* ]]
}

@test "the manifest records every input that affects the output" {
    run "$BUILD" --manifest-fields
    [ "$status" -eq 0 ]
    for f in media opencore ovmf config payload commit; do
        [[ "$output" == *"$f"* ]] || { echo "manifest missing: $f"; return 1; }
    done
}

# The compiler is the input the pins forgot. OpenCorePkg 1.0.7 does not
# build at all under a C23-default gcc and OvmfPkg builds to different
# bytes, so an image manifest that names every pinned source and not the
# thing that translated them is incomplete. See docs/decisions/0004.
@test "the manifest records the compiler, which is recorded but not pinned" {
    run "$BUILD" --manifest-fields
    [ "$status" -eq 0 ]
    [[ "$output" == *"compiler"* ]]
}

# WHICH compiler and WHAT WE THOUGHT OF IT are two different facts, and the
# second one cannot be reconstructed later: the supported range moves as
# evidence arrives (lib/compiler.sh) and the image does not. Without this
# line, an image built above the ceiling silently becomes a supported build
# the day the ceiling is raised. See docs/decisions/0004, "Answered".
@test "the manifest records whether that compiler was inside the declared range" {
    run "$BUILD" --manifest-fields
    [ "$status" -eq 0 ]
    [[ "$output" == *"compilerrange"* ]]
}

@test "the build scripts can say which compiler they will use" {
    run "$REPO/boot/build-opencore.sh" --compiler
    [ "$status" -eq 0 ]
    [[ "$output" == *"-std="* ]]
}

@test "machine, CPU and RAM are parameters, not constants" {
    run "$BUILD" --machine pc --cpu qemu64 --ram 2048 --smp 1 --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"pc"* ]]
    [[ "$output" == *"qemu64"* ]]
    [[ "$output" == *"2048"* ]]
}

@test "--dry-run prints the QEMU command line and starts nothing" {
    run "$BUILD" --accel tcg --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"qemu-system-x86_64"* ]]
    [[ "$output" == *"accel=tcg"* || "$output" == *"-accel tcg"* ]]
    [[ "$output" == *"hostfwd=tcp::"* ]]
}

@test "the guest's SSH port is forwarded, which is how the image is tested" {
    run "$BUILD" --ssh-port 2299 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"hostfwd=tcp::2299-:22"* ]]
}

@test "every stage is named, and can be run or resumed from by name" {
    run "$BUILD" --describe
    [ "$status" -eq 0 ]
    for s in esd opencore ovmf efi payload media target install verify manifest; do
        [[ "$output" == *"$s"* ]] || { echo "no stage named: $s"; return 1; }
    done
    run "$BUILD" --from nosuchstage --describe
    [ "$status" -ne 0 ]
}

@test "it leaves room for the software-update question rather than closing it" {
    # docs/open-questions.md Q1 names P4 as its deadline. The pipeline must
    # not hard-code "no updates" in a way that makes answering it a rewrite.
    run "$BUILD" --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"--updates"* ]]
    run "$BUILD" --updates nonsense --describe
    [ "$status" -ne 0 ]
}

@test "build-image.sh is not Tier 2: it never reaches into the quarantine" {
    run grep -c 'vendor-reference\|MQG_VENDOR_DIR' "$BUILD"
    [ "$output" = "0" ]
}

@test "nothing the pipeline writes lands in the repository" {
    # $MQG_IMAGE_DIR is on local disk; the repo is NFS at ~18 ms per file
    # create, and guest images must never be committed.
    run bash -c "grep -nE '(>|-o|--out|mkdir -p) *\"?\\\$MQG_REPO_ROOT' '$BUILD' | grep -vc '^\$'"
    [ "$output" = "0" ]
}

@test "the verify stage boots the image without the installer media" {
    # An image that only boots with its installer attached is not the
    # deliverable. The install stage needs the media; nothing after it does.
    run "$BUILD" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"installer-linux.img"* ]]
    run grep -c 'boot_vm without-media' "$BUILD"
    [ "$output" -ge 1 ]
}

@test "verify runs while the guest is up, not after it is stopped" {
    # The first version powered the guest down at the end of the install
    # stage and then tried to SSH into it. Ordering, as code: nothing may
    # call power_down_vm before the verify stage has had the guest.
    run bash -c "grep -n 'power_down_vm\|stage_verify\|stage_install' '$BUILD' | grep -v '^.*#' | tail -20"
    [ "$status" -eq 0 ]
    # power_down_vm is called from stage_verify and from the top level after
    # every stage -- never from stage_install.
    run bash -c "sed -n '/^stage_install()/,/^}/p' '$BUILD' | grep -c power_down_vm"
    [ "$output" = "0" ]
}

@test "the shutdown path says why it terminates QEMU" {
    # 10.9 ignores the ACPI power button at the login window. That is a
    # finding, not an oversight, and the code has to say so or someone will
    # "fix" it back.
    run grep -c 'ACPI' "$BUILD"
    [ "$output" -ge 1 ]
    run grep -ci 'journal' "$BUILD"
    [ "$output" -ge 1 ]
}

@test "the OpenCore image is not mutated by running the guest" {
    # Every boot used to rewrite it: built as ba9eab36, then 7f4ce3aa after
    # one run, 0ad83718 after the next. So two builds using the SAME
    # bootloader recorded different "opencore" checksums, and P3's pinned
    # checksum for the boot stack stopped matching the file on disk after
    # the first run. snapshot=on keeps the guest's writes in a throwaway
    # overlay.
    run "$BUILD" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencore"*"snapshot=on"* ]]
}

@test "the manifest records the EFI image as built, not as last run" {
    run grep -c 'efi_img.sha256' "$BUILD"
    [ "$output" -ge 1 ]
}

@test "a build directory too long for EDK II is refused in a millisecond" {
    # EDK II enforces a 255-byte limit on debug symbol paths and says so
    # about ten minutes into compiling. Its own deepest module path is
    # ~125 characters, so the build directory has to be well short of that.
    long="$BATS_TEST_TMPDIR/$(printf 'x%.0s' $(seq 1 200))"
    run env MQG_IMAGE_DIR="$long" "$BUILD" --describe
    [ "$status" -eq 0 ]   # --describe touches nothing and must still work
    run env MQG_IMAGE_DIR="$long" "$BUILD" --stage esd
    [ "$status" -ne 0 ]
    [[ "$output" == *"255"* ]]
    [[ "$output" == *"EDK II"* ]]
}

@test "neither input the guest can write to is left writable" {
    # The OpenCore image and the installer media are both attached to the
    # guest, and the guest writes to both: the bootloader image changed on
    # every boot, and macOS put a .Spotlight-V100 store with a fresh UUID
    # on the media. An input that the run modifies is not one.
    #
    # It has a second reason now. A guest that can write to the installer
    # media can corrupt it, and in the era when it could, three media
    # builds in six produced a corrupt Essentials.pkg -- see the Task 34
    # entry in NOTES.md, which concludes the cause was something other than
    # the build writing to that file. This assertion is what keeps the
    # guest out of it.
    run bash -c "'$BUILD' --dry-run | tr ' ' '\n' | grep -c 'snapshot=on'"
    [ "$output" = "2" ]
    run bash -c "'$BUILD' --dry-run | tr ' ' '\n' | grep 'snapshot=on'"
    [[ "$output" == *"opencore"* ]]
    [[ "$output" == *"installer"* ]]
    # ...and the target disk is NOT one of them.
    run bash -c "'$BUILD' --dry-run | tr ' ' '\n' | grep 'id=target'"
    [[ "$output" != *"snapshot=on"* ]]
}

@test "a stage that needs the OpenSSH tag resolves it in its own shell" {
    # `--stage payload` on its own used to die with "--openssh-pkg needs
    # --openssh-tag". openssh_args runs inside `< <(...)`, a subshell, so
    # everything resolve_openssh set there was discarded on exit; a full
    # run only worked because stage_openssh had already resolved it in the
    # parent. Every stage that reads openssh_tag must resolve it itself.
    #
    # Checked by reading the script rather than by running the stage: the
    # stage builds a package, and a unit test should not need Apple's
    # installer media on disk to prove a scoping bug is fixed.
    run awk '/^stage_payload\(\)/, /^}/' "$BUILD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolve_openssh"* ]]
    run awk '/^stage_media\(\)/, /^}/' "$BUILD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resolve_openssh"* ]]
}

@test "the verify stage asks the guest what bus its disk is on" {
    # Ledger entry G16 says -device ide-hd on q35 presents as SATA/AHCI in
    # the guest. That was read off Disk Utility by hand, once. Asking every
    # build makes it a measurement, and gives bin/triangulate.sh something
    # to report from a host where the answer might differ.
    run awk '/^stage_verify\(\)/, /^}/' "$BUILD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"diskbus="* ]]
}
