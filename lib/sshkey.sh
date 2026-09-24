# shellcheck shell=bash
# The one search that decides which already-existing SSH public key
# image/build-image.sh authorizes in a built image, and which private key
# vm/ssh.sh therefore has to use to reach one.
#
# Kept in exactly one place because these two callers have to agree:
# build-image.sh decides what a running image will accept, and ssh.sh has
# to arrive at the same key from the outside, with no way to ask a
# running guest afterwards which key it got. If the search ever drifted
# between two copies, `vmavs ssh` would silently try a key the image
# never authorized, and nothing would say why -- it would just look like
# a broken image.
#
# Requires lib/common.sh. Callers set MQG_IMAGE_DIR.

# sshkey_find -- print the path of the first already-existing public key
# this project would authorize, or print nothing and return 1 if there
# isn't one. Never generates anything; that stays the caller's decision
# (image/build-image.sh's --generate-ssh-key is opt-in).
#
# Search order: $HOME/.ssh/id_*.pub, then $MQG_IMAGE_DIR/keys/*.pub -- the
# second is where --generate-ssh-key (image/build-image.sh) writes
# mqg_rsa.pub, so a key this project generated for itself is found the
# same way a key someone already had on the host is.
sshkey_find() {
    local candidate
    for candidate in "$HOME"/.ssh/id_*.pub "${MQG_IMAGE_DIR:?MQG_IMAGE_DIR is unset}"/keys/*.pub; do
        [ -f "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}
