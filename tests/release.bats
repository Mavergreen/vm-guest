#!/usr/bin/env bats
#
# The checks that guard what this project ships, and what it is made of.
#
# Two of them pass by construction today -- the tracked tree carries no
# Apple bytes because the tool fetches at runtime, and no pin has moved
# because nobody has moved one. A check that can only pass is a check
# nobody trusts, so each one here is also fired at a planted violation.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# A throwaway git repository holding a copy of bin/ and lib/, so a planted
# violation can be committed without touching this one.
make_repo() {
    local dir="$BATS_TEST_TMPDIR/planted"
    mkdir -p "$dir/bin" "$dir/lib" "$dir/vendor" "$dir/boot/config" \
        "$dir/components/openssh"
    cp "$REPO/bin/no-apple-bytes.sh" "$dir/bin/"
    cp "$REPO/bin/ingredient-fingerprint.sh" "$dir/bin/"
    cp "$REPO/bin/image-staleness.sh" "$dir/bin/"
    cp "$REPO/lib/common.sh" "$dir/lib/"
    cp "$REPO/vendor/sources.tsv" "$dir/vendor/"
    cp "$REPO/boot/config/config.plist" "$dir/boot/config/"
    cp "$REPO/components/openssh/version" "$dir/components/openssh/"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name t
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm first
    printf '%s\n' "$dir"
}

# --- no Apple-derived bytes ------------------------------------------------

@test "the tracked tree carries no Apple-derived bytes" {
    run "$REPO/bin/no-apple-bytes.sh"
    [ "$status" -eq 0 ]
}

@test "a committed disk image is caught by name" {
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/InstallESD.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"InstallESD.dmg"* ]]
}

@test "a committed flat package is caught by its bytes, not its name" {
    # The name check is defeated by `mv`. The magic number is not.
    dir="$(make_repo)"
    mkdir -p "$dir/docs"
    printf 'xar!and then some payload\n' > "$dir/docs/notes.txt"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"xar!"* ]]
}

@test "a large committed blob is caught even with neither name nor magic" {
    dir="$(make_repo)"
    head -c 3000000 /dev/zero > "$dir/docs-appendix"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs-appendix"* ]]
}

@test "Apple's media is registered as a URL, never as a path in the tree" {
    run awk -F'\t' '$1 ~ /^apple-/ { print $2 }' "$REPO/vendor/sources.tsv"
    [ -n "$output" ]
    [[ "$output" == http://* || "$output" == https://* ]]
}

# --- the ingredient fingerprint -------------------------------------------

@test "every registry entry and every component pin is an ingredient" {
    run "$REPO/bin/ingredient-fingerprint.sh" --list
    [ "$status" -eq 0 ]
    # One line per non-comment registry entry, plus each components/*/version,
    # plus config.plist.
    registry=$(awk -F'\t' '$0 !~ /^#/ && NF >= 3 && $1 != "" { n++ } END { print n+0 }' \
        "$REPO/vendor/sources.tsv")
    components=$(ls -d "$REPO"/components/*/ 2>/dev/null | wc -l)
    [ "${#lines[@]}" -eq $((registry + components + 1)) ]
    [[ "$output" == *"config.plist"* ]]
    [[ "$output" == *"openssh"* ]]
}

@test "the fingerprint is a digest of the listing, and moves when a pin moves" {
    before="$("$REPO/bin/ingredient-fingerprint.sh")"
    [ "${#before}" -eq 64 ]
    dir="$(make_repo)"
    same="$(cd "$dir" && ./bin/ingredient-fingerprint.sh)"
    [ "$same" = "$before" ]
    printf '10.5p1-mavericks.99\n' > "$dir/components/openssh/version"
    after="$(cd "$dir" && ./bin/ingredient-fingerprint.sh)"
    [ "$after" != "$before" ]
}

@test "the fingerprint does not depend on the order of the registry file" {
    dir="$(make_repo)"
    before="$(cd "$dir" && ./bin/ingredient-fingerprint.sh)"
    # Reverse the entry lines; the pins are identical, so the digest must be.
    { grep '^#' "$dir/vendor/sources.tsv"
      grep -v '^#' "$dir/vendor/sources.tsv" | grep . | tac
    } > "$dir/vendor/sources.tsv.new"
    mv "$dir/vendor/sources.tsv.new" "$dir/vendor/sources.tsv"
    after="$(cd "$dir" && ./bin/ingredient-fingerprint.sh)"
    [ "$after" = "$before" ]
}

# --- staleness, which is the recipe-shaped problem -------------------------

@test "an image whose recorded pins all still match is not stale" {
    dir="$(make_repo)"
    {
        printf 'name\tfresh\n'
        (cd "$dir" && ./bin/ingredient-fingerprint.sh --list) \
            | sed 's/^/ingredient./'
    } > "$BATS_TEST_TMPDIR/fresh.manifest"
    run bash -c "cd '$dir' && ./bin/image-staleness.sh '$BATS_TEST_TMPDIR/fresh.manifest'"
    [ "$status" -eq 0 ]
}

@test "an image built before a pin moved is reported stale, and names the pin" {
    dir="$(make_repo)"
    {
        printf 'name\tolder\n'
        (cd "$dir" && ./bin/ingredient-fingerprint.sh --list) \
            | sed 's/^/ingredient./'
    } > "$BATS_TEST_TMPDIR/older.manifest"
    printf '10.5p1-mavericks.99\n' > "$dir/components/openssh/version"
    run bash -c "cd '$dir' && ./bin/image-staleness.sh '$BATS_TEST_TMPDIR/older.manifest'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"STALE"* ]]
    [[ "$output" == *"openssh"* ]]
    # Both sides, so the reader can see what moved and where to.
    [[ "$output" == *"image:"* ]]
    [[ "$output" == *"repository:"* ]]
}

@test "an ingredient the repository GAINED is reported as that, not as a moved pin" {
    # The two are different news and the summary used to report both as "an
    # ingredient this checkout no longer pins" -- which is the opposite of
    # true when the checkout has gained one. It stopped being hypothetical
    # the day vendor/sources.tsv gained Apple's update pins: every golden on
    # disk suddenly "no longer matched" ingredients it could not have had.
    dir="$(make_repo)"
    {
        printf 'name\tbefore-the-new-pin\n'
        (cd "$dir" && ./bin/ingredient-fingerprint.sh --list) \
            | sed 's/^/ingredient./'
    } > "$BATS_TEST_TMPDIR/predates.manifest"
    printf 'brand-new-thing\thttp://example.invalid/x.tar.gz\t%s\n' \
        0000000000000000000000000000000000000000000000000000000000000001 \
        >> "$dir/vendor/sources.tsv"
    run bash -c "cd '$dir' && ./bin/image-staleness.sh '$BATS_TEST_TMPDIR/predates.manifest'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GAINED"* ]]
    [[ "$output" == *"brand-new-thing"* ]]
    [[ "$output" != *"MOVED"* ]]
}

@test "a pin that moved is still reported as having moved" {
    dir="$(make_repo)"
    {
        printf 'name\tunder-a-moved-pin\n'
        (cd "$dir" && ./bin/ingredient-fingerprint.sh --list) \
            | sed 's/^/ingredient./'
    } > "$BATS_TEST_TMPDIR/moved.manifest"
    printf '10.5p1-mavericks.99\n' > "$dir/components/openssh/version"
    run bash -c "cd '$dir' && ./bin/image-staleness.sh '$BATS_TEST_TMPDIR/moved.manifest'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MOVED"* ]]
    [[ "$output" != *"GAINED"* ]]
}

@test "a manifest with no ingredients says so rather than passing" {
    # "I cannot tell" and "it is fine" must not be the same answer: that is
    # how a stale golden gets trusted.
    printf 'name\tantique\n' > "$BATS_TEST_TMPDIR/antique.manifest"
    run "$REPO/bin/image-staleness.sh" "$BATS_TEST_TMPDIR/antique.manifest"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be determined"* ]]
}

# --- the family wiring -----------------------------------------------------

@test "build/msc.sh is shipyard's template and carries the do-not-edit note" {
    [ -f "$REPO/build/msc.sh" ]
    # The gate compares it byte for byte with
    # $SHIPYARD_SCRIPTS/templates/msc.sh. We cannot reach shipyard from
    # here, so check the marker the template carries: an edited copy is
    # overwhelmingly likely to have lost or reworded it.
    run grep -c 'CANONICAL COPY' "$REPO/build/msc.sh"
    [ "$output" = "1" ]
    run grep -c 'SHIPYARD_SCRIPTS' "$REPO/build/msc.sh"
    [ "$output" -ge 1 ]
}

@test "the marketplace is registered so a contributor's agent loads the conventions" {
    run python3 -c "
import json
cfg = json.load(open('$REPO/.claude/settings.json'))
assert cfg['extraKnownMarketplaces']['modernmavericks']['source']['repo'] \
    == 'Mavergreen/shipyard', cfg
assert cfg['enabledPlugins']['modernmavericks@modernmavericks'] is True, cfg
print('ok')
"
    [ "$status" -eq 0 ]
}

@test "INGREDIENTS.md exists and every declared deviation has a reason" {
    [ -f "$REPO/INGREDIENTS.md" ]
    # The family's own grammar: "- <check>[:<glob>]: <reason>". An entry
    # with no reason fails deviations.sh; reproduce enough of the parse to
    # catch that here, where shipyard is not checked out.
    run bash -c "sed -n '/^## Conformance deviations/,/^## /p' '$REPO/INGREDIENTS.md' | grep -c '^- '"
    [ "$output" -ge 1 ]
    run bash -c "
        sed -n '/^## Conformance deviations/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep '^- ' \
        | grep -cvE '^- [a-z][a-z0-9_-]*(:[^ :]+)?: +\\S'"
    [ "$output" = "0" ]
}

@test "no INGREDIENTS.md row is marked untracked without saying untrackable" {
    # The family gate's rule: a bare cross reads as an oversight rather
    # than a decision.
    #
    # "no datasource" joined the list for Apple's update packages
    # (docs/decisions/0011). They are not untrackABLE in the sense the
    # other phrases mean -- the URL is stable and fetchable -- there is
    # simply no feed to track and no newer version to find, because the
    # product line was discontinued in 2016. That is a decision with a
    # reason, which is all this gate is asking for.
    run bash -c "grep '^|' '$REPO/INGREDIENTS.md' | grep '❌' | grep -cv 'untrack\|not ingredients\|unpinnable\|deliberately untracked\|no datasource'"
    [ "$output" = "0" ]
}

@test "INGREDIENTS.md says what a release does about upstream release notes" {
    run grep -c '^No upstream release notes: .' "$REPO/INGREDIENTS.md"
    [ "$output" = "1" ]
}
