#!/usr/bin/env bats
#
# bin/verify-changed-sources.sh diffs the registry against a base ref. The
# registry moved from vendor/sources.tsv to assets/pins/sources.tsv; a base
# commit from before that move still has it at the old path, so the script
# must fall back to the old path when the new one is not there yet -- see
# the comment above the git show fallback in bin/verify-changed-sources.sh.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# A throwaway git repository carrying just enough of the tree for
# bin/verify-changed-sources.sh to run: the script itself, the two lib
# files it sources, and a registry at the given path.
make_repo() {
    local dir="$BATS_TEST_TMPDIR/planted" registry_path="$1"
    mkdir -p "$dir/bin" "$dir/lib" "$dir/$(dirname "$registry_path")"
    cp "$REPO/bin/verify-changed-sources.sh" "$dir/bin/"
    cp "$REPO/lib/common.sh" "$dir/lib/"
    cp "$REPO/lib/vendor.sh" "$dir/lib/"
    printf '%s\n' \
        "thing	file://$dir/upstream.zip	$2" \
        > "$dir/$registry_path"
    printf 'payload\n' > "$dir/upstream.zip"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name t
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm "$3"
    printf '%s\n' "$dir"
}

@test "verify-changed-sources falls back to vendor/sources.tsv for a pre-move base ref" {
    dir="$(make_repo vendor/sources.tsv wrongsum "pre-move, unpinned")"
    got=$(sha256sum "$dir/upstream.zip" | cut -d' ' -f1)
    base=$(git -C "$dir" rev-parse HEAD)

    # The move: the registry's new home, with the checksum now correctly
    # pinned. Nothing else about the "thing" row changed.
    mkdir -p "$dir/assets/pins"
    git -C "$dir" mv vendor/sources.tsv assets/pins/sources.tsv
    printf '%s\n' "thing	file://$dir/upstream.zip	$got" \
        > "$dir/assets/pins/sources.tsv"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm "pins move, and pin"

    run bash -c "cd '$dir' && ./bin/verify-changed-sources.sh '$base'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"verifying thing"* ]]
}

@test "verify-changed-sources sees no change across the move when the pin did not move" {
    dir="$(make_repo vendor/sources.tsv PLACEHOLDER "pre-move")"
    got=$(sha256sum "$dir/upstream.zip" | cut -d' ' -f1)
    sed -i "s/PLACEHOLDER/$got/" "$dir/vendor/sources.tsv"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm "pin the checksum"
    base=$(git -C "$dir" rev-parse HEAD)

    # The move alone: same name, same url, same checksum, new path.
    mkdir -p "$dir/assets/pins"
    git -C "$dir" mv vendor/sources.tsv assets/pins/sources.tsv
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm "pins move"

    run bash -c "cd '$dir' && ./bin/verify-changed-sources.sh '$base'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to fetch"* ]]
}
