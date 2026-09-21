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

@test "the NIC is a build-time choice, and the default is the measured one" {
    # docs/open-questions.md Q2, answered 2026-09-21: usb-net is CDC-ECM at
    # 10baseT and measured 1.24 MB/s; e1000-82545em measured 174 MB/s on the
    # same host with one changed line. See docs/decisions/0008.
    # --dry-run prints a shell-quoted command line, so the commas inside a
    # -device value arrive backslash-escaped. Match on that spelling rather
    # than on the one the script writes.
    run "$BUILD" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'e1000-82545em\,netdev=net0'* ]]
    [[ "$output" != *"usb-net"* ]]
}

@test "the NIC the image was built with stays available by flag" {
    # Changing the default migrates no existing image: 10.9 records the
    # interfaces it has seen and gives a NIC it meets later no network
    # service at all. An image built with usb-net still needs usb-net.
    run "$BUILD" --nic usb-net --dry-run
    [ "$status" -eq 0 ]
    # usb-net is a USB device and must hang off the EHCI controller; the
    # PCI ones must not carry a bus= at all.
    [[ "$output" == *'usb-net\,bus=usb.0\,netdev=net0'* ]]
    run "$BUILD" --nic virtio-net-pci --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'virtio-net-pci\,netdev=net0'* ]]
    [[ "$output" != *'virtio-net-pci\,bus='* ]]
}

@test "build-image.sh rejects a NIC it has not measured" {
    run "$BUILD" --nic nonsense --describe
    [ "$status" -ne 0 ]
    [[ "$output" == *"nic"* ]]
}

@test "the manifest records which NIC produced the image" {
    # It is an input that changes what is in the image, like --updates:
    # the network services 10.9 creates during installation are built from
    # the hardware it saw then.
    run "$BUILD" --manifest-fields
    [ "$status" -eq 0 ]
    [[ "$output" == *"nic"* ]]
}

@test "compare-images.sh boots each image with the NIC its manifest names" {
    # 10.9 gives a NIC it meets after installation no network service, so
    # booting an image with the wrong NIC produces "never answered SSH" and
    # a comparison that blames the image. The manifest knows which; a
    # manifest with no nic field predates the field, and every image from
    # then was built with usb-net.
    local S="$BATS_TEST_TMPDIR"
    printf 'name\tx\nnic\te1000-82545em\n' > "$S/a.manifest"
    printf 'name\tx\n' > "$S/b.manifest"
    eval "$(sed -n '/^nic_device_for() {/,/^}/p' "$REPO/image/compare-images.sh")"
    [ "$(nic_device_for "$S/a.manifest")" = "e1000-82545em,netdev=net0" ]
    [ "$(nic_device_for "$S/b.manifest")" = "usb-net,bus=usb.0,netdev=net0" ]
    [ "$(nic_device_for "$S/nosuch.manifest")" = "usb-net,bus=usb.0,netdev=net0" ]
}

# --- stage freshness -------------------------------------------------------
#
# The pipeline used to skip a stage whenever its output file was present.
# The failure that motivated all of this: Renovate bumps the OpenCore pin
# in vendor/sources.tsv, the opencore stage sees its .efi sitting there,
# skips, and we build an image from stale firmware without a word. Each
# stage now records what it consumed beside its output, and `--freshness`
# answers "would this run, and why" without building anything -- which is
# what makes every branch below testable in milliseconds.

# The decision and the reason for one stage, out of --freshness's output.
freshness_row() {
    printf '%s\n' "$output" | awk -F'\t' -v s="$1" '$1 == s { print $2 "\t" $3 }'
}

# A sandbox with a private sources registry, so a pin can be bumped without
# touching the checkout. MQG_SOURCES is the seam boot/build-opencore.sh
# already uses.
freshness_sandbox() {
    export MQG_SOURCES="$BATS_TEST_TMPDIR/sources.tsv"
    cp "$REPO/vendor/sources.tsv" "$MQG_SOURCES"
    mkdir -p "$MQG_IMAGE_DIR/media" "$MQG_IMAGE_DIR/build/artifacts"
}

# Plant an output and the record of the inputs that produced it.
plant_stage() {
    local stage=$1 out=$2
    shift 2
    mkdir -p "$(dirname "$out")"
    printf 'stand-in for the real artifact\n' > "$out"
    "$REPO/bin/ingredient-fingerprint.sh" --stage "$stage" --list "$@" \
        > "$out.inputs"
}

bump_pin() {
    local name=$1
    awk -F'\t' -v OFS='\t' -v n="$name" \
        '$0 !~ /^#/ && $1 == n { $3 = "0000000000000000000000000000000000000000000000000000000000000000" } { print }' \
        "$MQG_SOURCES" > "$MQG_SOURCES.new"
    mv "$MQG_SOURCES.new" "$MQG_SOURCES"
}

@test "a stage whose recorded inputs still match is skipped, and says so" {
    freshness_sandbox
    plant_stage esd "$MQG_IMAGE_DIR/media/InstallESD.dmg"
    run "$BUILD" --freshness
    [ "$status" -eq 0 ]
    [ "$(freshness_row esd)" = "$(printf 'skip\tinputs unchanged')" ]
}

@test "an output whose inputs were never recorded is rebuilt, not trusted" {
    # "I cannot tell" and "it is fine" must not be the same answer -- the
    # distinction bin/image-staleness.sh makes about a manifest with no
    # ingredient lines, made here about an artifact with no stamp.
    freshness_sandbox
    printf 'an artifact from before this existed\n' \
        > "$MQG_IMAGE_DIR/media/InstallESD.dmg"
    run "$BUILD" --freshness
    [ "$status" -eq 0 ]
    [[ "$(freshness_row esd)" == run* ]]
    [[ "$(freshness_row esd)" == *"no input record"* ]]
}

@test "a bumped pin in vendor/sources.tsv reruns the stage that consumes it" {
    # THE SCENARIO THIS EXISTS FOR.
    freshness_sandbox
    plant_stage esd "$MQG_IMAGE_DIR/media/InstallESD.dmg"
    plant_stage opencore "$MQG_IMAGE_DIR/build/artifacts/SHA256SUMS"
    plant_stage ovmf "$MQG_IMAGE_DIR/build/firmware/OVMF_CODE.fd"

    run "$BUILD" --freshness
    [ "$(freshness_row opencore)" = "$(printf 'skip\tinputs unchanged')" ]

    bump_pin opencorepkg-src
    run "$BUILD" --freshness
    [ "$status" -eq 0 ]
    # The firmware stages rerun, and the reason names the pin that moved.
    [[ "$(freshness_row opencore)" == *"inputs changed (source:opencorepkg-src)"* ]]
    [[ "$(freshness_row ovmf)" == *"inputs changed (source:opencorepkg-src)"* ]]
    # And nothing else does. A bump that rebuilt the world would be as
    # uninformative as one that rebuilt nothing.
    [ "$(freshness_row esd)" = "$(printf 'skip\tinputs unchanged')" ]
}

@test "bumping the ESD pin reruns the esd stage and not the firmware" {
    freshness_sandbox
    plant_stage esd "$MQG_IMAGE_DIR/media/InstallESD.dmg"
    plant_stage opencore "$MQG_IMAGE_DIR/build/artifacts/SHA256SUMS"
    bump_pin apple-installesd-10.9.5
    run "$BUILD" --freshness
    [ "$status" -eq 0 ]
    [[ "$(freshness_row esd)" == *"inputs changed (source:apple-installesd-10.9.5)"* ]]
    [ "$(freshness_row opencore)" = "$(printf 'skip\tinputs unchanged')" ]
}

@test "a stage reruns when an earlier stage's output changed, not only its pins" {
    # The efi stage consumes OpenCore's BINARIES. Naming them by the
    # checksum of what was built -- rather than by the pins that were
    # supposed to produce it -- is what catches a compiler that emitted
    # different bytes from identical sources, which is the exact failure
    # docs/decisions/0004 says is the silent one.
    freshness_sandbox
    local sums="$MQG_IMAGE_DIR/build/artifacts/SHA256SUMS"
    printf 'aaaa  OpenCore.efi\n' > "$sums"
    plant_stage efi "$MQG_IMAGE_DIR/work/opencore-p3.img" \
        "opencore-artifacts=$(sha256sum "$sums" | cut -d' ' -f1)" \
        "smbios=iMac14,2"
    run "$BUILD" --freshness
    [ "$(freshness_row efi)" = "$(printf 'skip\tinputs unchanged')" ]

    printf 'bbbb  OpenCore.efi\n' > "$sums"
    run "$BUILD" --freshness
    [ "$status" -eq 0 ]
    [[ "$(freshness_row efi)" == *"inputs changed (opencore-artifacts)"* ]]
}

@test "the efi stage reruns when --smbios changes, because the config goes ON the image" {
    # The SMBIOS model is not only a manifest note: it changes the
    # config.plist boot/build-efi-image.sh copies onto the EFI image. A
    # stage that skipped because the OpenCore artifacts had not moved would
    # hand the next run somebody else's SMBIOS -- and the G14 experiment
    # would silently test the default. See docs/decisions/0010.
    freshness_sandbox
    local sums="$MQG_IMAGE_DIR/build/artifacts/SHA256SUMS"
    printf 'aaaa  OpenCore.efi\n' > "$sums"
    plant_stage efi "$MQG_IMAGE_DIR/work/opencore-p3.img" \
        "opencore-artifacts=$(sha256sum "$sums" | cut -d' ' -f1)" \
        "smbios=iMac14,2"
    run "$BUILD" --freshness
    [ "$(freshness_row efi)" = "$(printf 'skip\tinputs unchanged')" ]

    run "$BUILD" --freshness --smbios MacPro5,1
    [ "$status" -eq 0 ]
    [[ "$(freshness_row efi)" == *"inputs changed (smbios)"* ]]
}

@test "--force reruns everything, and says that is why" {
    freshness_sandbox
    plant_stage esd "$MQG_IMAGE_DIR/media/InstallESD.dmg"
    run "$BUILD" --freshness --force
    [ "$status" -eq 0 ]
    [ "$(freshness_row esd)" = "$(printf 'run\t--force')" ]
}

@test "every stage that records inputs is one ingredient-fingerprint.sh knows" {
    # Two lists that must agree: the stages build-image.sh stamps, and the
    # stages the fingerprint script can describe. A stage in one and not
    # the other is a silent skip waiting to happen.
    run "$REPO/bin/ingredient-fingerprint.sh" --stages
    [ "$status" -eq 0 ]
    for s in esd opencore ovmf efi payload media install; do
        [[ "$output" == *"$s"* ]] || { echo "no such stage: $s"; return 1; }
    done
}

@test "--freshness touches nothing, not even with --generate-ssh-key" {
    # It is a question about the build, and a question must not invent a
    # secret to answer it. HOME is redirected so a key the host already has
    # cannot make this pass by accident.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    run "$BUILD" --freshness --generate-ssh-key
    [ "$status" -eq 0 ]
    [ ! -d "$MQG_IMAGE_DIR/keys" ]
    [[ "$output" == *"esd"* ]]
}
