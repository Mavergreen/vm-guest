#!/usr/bin/env bats
#
# lib/sshkey.sh -- the one search image/build-image.sh's resolve_ssh_key
# and vm/ssh.sh both call, so they can never disagree about which key an
# image authorized. See the file's own header for why that matters.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/sshkey.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export MQG_IMAGE_DIR="$BATS_TEST_TMPDIR/images"
    mkdir -p "$HOME/.ssh" "$MQG_IMAGE_DIR/keys"
}

@test "sshkey_find returns nothing and fails when there is no key anywhere" {
    run sshkey_find
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "sshkey_find uses the image-dir key when \$HOME/.ssh has none" {
    printf 'pub\n' > "$MQG_IMAGE_DIR/keys/mqg_rsa.pub"
    run sshkey_find
    [ "$status" -eq 0 ]
    [ "$output" = "$MQG_IMAGE_DIR/keys/mqg_rsa.pub" ]
}

@test "sshkey_find prefers a \$HOME/.ssh key over an image-dir one" {
    # Same order as image/build-image.sh's resolve_ssh_key: $HOME/.ssh is
    # searched first. A generated key living under MQG_IMAGE_DIR must not
    # shadow a key the user already had.
    printf 'pub\n' > "$HOME/.ssh/id_ed25519.pub"
    printf 'pub\n' > "$MQG_IMAGE_DIR/keys/mqg_rsa.pub"
    run sshkey_find
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.ssh/id_ed25519.pub" ]
}

@test "sshkey_find requires MQG_IMAGE_DIR to be set" {
    unset MQG_IMAGE_DIR
    run sshkey_find
    [ "$status" -ne 0 ]
    [[ "$output" == *"MQG_IMAGE_DIR"* ]]
}
