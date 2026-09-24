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

@test "no-apple-bytes checks a named ref, which is what a release will pass it" {
    dir="$(make_repo)"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh HEAD"
    [ "$status" -eq 0 ]
}

@test "a violation on a TAG is caught when that tag is checked" {
    # The release path checks the tag it is about to publish, not the
    # working tree. A planted .dmg at that tag must fail it.
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/InstallESD.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag 20260922.1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 20260922.1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"InstallESD.dmg"* ]]
}

@test "a clean tag passes even when the WORKING TREE has Apple's media beside it" {
    # This is how the project is meant to work: decisions/0003 puts images
    # on local disk outside the repo. An untracked InstallESD.dmg must not
    # redden a release.
    dir="$(make_repo)"
    git -C "$dir" tag 20260922.1
    printf 'x\n' > "$dir/InstallESD.dmg"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 20260922.1"
    [ "$status" -eq 0 ]
}

@test "an unknown ref is a failure, never a pass, and names the ref" {
    # Cannot-verify is a FAILURE. A release gate that green-lights because
    # it could not find the tag is worse than no gate. It should also say
    # WHICH ref it could not find, not just that something failed.
    dir="$(make_repo)"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 19700101.1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"19700101.1"* ]]
}

@test "a violation on a TAG is caught even though the same file was removed from the index afterward" {
    # This is the case that distinguishes checking the ref from checking
    # the index: a planted .dmg is committed and tagged, then git-rm'd in a
    # later commit. Checking the TAG must still fail, naming the file --
    # that .dmg really did ship in the tagged tree. Checking with no ref
    # (today's index behavior) must pass, because the index has moved on.
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/InstallESD.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag 20260922.2
    git -C "$dir" rm -q InstallESD.dmg
    git -C "$dir" -c commit.gpgsign=false commit -qm removed
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 20260922.2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"InstallESD.dmg"* ]]
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -eq 0 ]
}

# --- fix round 1: C-quoting, pipefail/SIGPIPE, and unreadable blobs -------
#
# Three defects each let the checks above PASS on bytes `git archive
# <tag>` would package, in both modes: a path git C-quotes (non-ASCII, a
# double quote) matched no pattern and could not be opened; `head -c 4`
# SIGPIPEd a large blob's `git show` under pipefail, so the byte check
# skipped anything past a pipe buffer; and an unreadable blob was
# skipped rather than flagged. Each was reproduced against the pre-fix
# script before it was fixed; these tests hold the fixes in place.

@test "a disk image named with a non-ASCII byte is caught in ref mode" {
    # Without -z, `git ls-tree`/`git ls-files` C-quote a non-ASCII path:
    # é.dmg becomes the literal characters "\303\251.dmg" on stdout, which
    # matches none of the *.dmg patterns and is not a path `git show` can
    # open either.
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/é.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
}

@test "a disk image named with a non-ASCII byte is caught in index mode" {
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/é.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
}

@test "a large blob named with a non-ASCII byte is caught in ref mode" {
    dir="$(make_repo)"
    head -c 3000000 /dev/zero > "$dir/ü"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
}

@test "a large blob named with a non-ASCII byte is caught in index mode" {
    dir="$(make_repo)"
    head -c 3000000 /dev/zero > "$dir/ü"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
}

@test "a filename holding a double quote is caught, not silently C-quoted away" {
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/a\"b.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
}

@test "a Mach-O file well over a pipe buffer is still caught by its bytes, in ref mode" {
    # `head -c 4` exits the instant it has its four bytes. Without
    # `set +o pipefail` scoped to just that capture, the upstream `git
    # show` -- which can be streaming a multi-megabyte blob -- gets
    # SIGPIPE, dies with 141, and the script's own `set -o pipefail` fails
    # the whole pipeline, so anything past a pipe buffer's worth (~64 KiB)
    # silently skipped this check no matter what its header said. 200 KB
    # is comfortably past that and comfortably under the 2 MiB size gate,
    # so this exercises the byte check specifically, not the size check.
    dir="$(make_repo)"
    { printf '\xcf\xfa\xed\xfe'; head -c 200000 /dev/zero; } > "$dir/innocuous.bin"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Mach-O"* ]]
}

@test "a Mach-O file well over a pipe buffer is still caught by its bytes, in index mode" {
    dir="$(make_repo)"
    { printf '\xcf\xfa\xed\xfe'; head -c 200000 /dev/zero; } > "$dir/innocuous.bin"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Mach-O"* ]]
}

@test "a blob that cannot be read is a failure, not a silent skip" {
    # Cannot-verify must never read as clean. Commit a file, tag it, then
    # delete its own loose object so nothing can actually read the blob
    # back -- the corruption case the readability check exists to catch.
    dir="$(make_repo)"
    printf 'whatever\n' > "$dir/plugin.bin"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    sha=$(git -C "$dir" rev-parse "t1:plugin.bin")
    obj="$dir/.git/objects/${sha:0:2}/${sha:2}"
    [ -f "$obj" ]
    rm -f "$obj"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"plugin.bin"* ]]
    [[ "$output" == *"cannot be read"* ]]
}

@test "index mode with nothing in the index is a failure, not a pass on 0 files" {
    # "no Apple-derived bytes in the tracked tree (0 files)" was a pass.
    # Checking nothing is cannot-verify, which is never a pass. A fresh
    # repository has no index file at all; `git rm --cached` leaves an
    # empty one. Both.
    dir="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$dir/bin" "$dir/lib"
    cp "$REPO/bin/no-apple-bytes.sh" "$dir/bin/"
    cp "$REPO/lib/common.sh" "$dir/lib/"
    git -C "$dir" init -q
    [ ! -e "$dir/.git/index" ]
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot verify"* ]]
    [[ "$output" != *"no Apple-derived bytes"* ]]

    dir="$(make_repo)"
    git -C "$dir" rm -rq --cached .
    [ -e "$dir/.git/index" ]
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot verify"* ]]
}

@test "index mode reads the file named 0:evil, not stage 0 of evil" {
    # `git show ":$f"` parses ":0:evil" as stage 0 of "evil". With a benign
    # "evil" beside it, the byte check read the wrong blob and the
    # Mach-O in "0:evil" passed (MEASURED, final review). ":0:$f" names
    # stage 0 explicitly, so the rest is the path, whatever it holds.
    dir="$(make_repo)"
    printf 'plain text\n' > "$dir/evil"
    printf '\xcf\xfa\xed\xfe\x00\x00\x00\x00' > "$dir/0:evil"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0:evil"*"Mach-O"* ]]
    # Ref mode already read "<sha>:0:evil" as a path; it still does.
    git -C "$dir" tag t1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0:evil"*"Mach-O"* ]]
}

@test "a path holding a space is checked correctly in ref mode" {
    dir="$(make_repo)"
    mkdir -p "$dir/docs"
    printf 'not really\n' > "$dir/docs/install esd.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"install esd.dmg"* ]]
}

@test "the byte check runs in ref mode against the ref's own content, not the index" {
    # A flat package planted, tagged, then git-rm'd -- same shape as the
    # index-vs-ref test above, but for section 2 (magic bytes) rather than
    # section 1 (name).
    dir="$(make_repo)"
    mkdir -p "$dir/docs"
    printf 'xar!payload\n' > "$dir/docs/notes.txt"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    git -C "$dir" rm -q docs/notes.txt
    git -C "$dir" -c commit.gpgsign=false commit -qm removed
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"xar!"* ]]
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -eq 0 ]
}

@test "the size check runs in ref mode against the ref's own content, not the index" {
    dir="$(make_repo)"
    head -c 3000000 /dev/zero > "$dir/docs-appendix"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    git -C "$dir" rm -q docs-appendix
    git -C "$dir" -c commit.gpgsign=false commit -qm removed
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs-appendix"* ]]
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -eq 0 ]
}

@test "the registry check runs in ref mode against the ref's own vendor/sources.tsv" {
    dir="$(make_repo)"
    printf 'apple-bogus\t/not/a/url\tdeadbeef\n' >> "$dir/vendor/sources.tsv"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag t1
    git -C "$dir" checkout -q HEAD~1 -- vendor/sources.tsv
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm reverted
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh t1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"apple-bogus"* ]]
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh"
    [ "$status" -eq 0 ]
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
assert cfg['extraKnownMarketplaces']['mavergreen']['source']['repo'] \
    == 'Mavergreen/shipyard', cfg
assert cfg['enabledPlugins']['mavergreen@mavergreen'] is True, cfg
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

# --- Task 11: declared state, and a narrower version-scheme deviation -----

@test "INGREDIENTS.md declares a release state, with exactly one upstream entry" {
    run bash -c "sed -n '/^## Declared state/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep -c '^- upstream: '"
    [ "$output" = "1" ]
}

@test "the declared upstream is the file build/version.sh reads" {
    # release-state.sh exits 2 when these disagree, nightly, from its
    # first run. Catch it here instead.
    run bash -c "sed -n '/^## Declared state/,/^## /p' '$REPO/INGREDIENTS.md' \
        | sed -n 's/^- upstream: //p'"
    [ "$output" = "UPSTREAM_VERSION" ]
    [ -f "$REPO/UPSTREAM_VERSION" ]
}

@test "no prose line in the declared-state section starts with a dash and a colon" {
    # A dash-line containing a colon is parsed as an entry. If the text
    # after the colon happens to name a real file, the digest silently
    # gains an entry nobody intended -- the failure mode the whole design
    # exists to prevent.
    run bash -c "sed -n '/^## Declared state/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep '^- ' | grep -cvE '^- (upstream|pins|openssh|opencore-config): '"
    [ "$output" = "0" ]
}

@test "every declared-state path exists" {
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -e "$REPO/$p" ] || { echo "declared but absent: $p"; false; }
    done < <(sed -n '/^## Declared state/,/^## /p' "$REPO/INGREDIENTS.md" \
             | sed -n 's/^- [a-z-]*: //p' | cut -d: -f1)
}

@test "every version-scheme deviation names the self-upstream shape, not a bare refusal" {
    # Fix round 1 tightened this: it used to be enough for ONE of the
    # three version-scheme lines to say "self-upstream" and the other two
    # to ride on "same product, same reason" -- which a reader hits
    # without ever seeing the words that explain what the reason IS.
    total=$(sed -n '/^## Conformance deviations/,/^## /p' "$REPO/INGREDIENTS.md" \
        | grep -c '^- version-scheme')
    named=$(sed -n '/^## Conformance deviations/,/^## /p' "$REPO/INGREDIENTS.md" \
        | grep '^- version-scheme' | grep -ci 'self-upstream')
    [ "$total" -ge 1 ]
    [ "$named" = "$total" ]
}

@test "every declared deviation still carries a reason" {
    run bash -c "
        sed -n '/^## Conformance deviations/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep '^- ' \
        | grep -cvE '^- [a-z][a-z0-9_-]*(:[^ :]+)?: +\\S'"
    [ "$output" = "0" ]
}

# --- Task 9: the README as product documentation ---------------------------

@test "the README leads with what the tool does, not with the host it was built on" {
    run head -12 "$REPO/README.md"
    [[ "$output" == *"vmavs"* ]]
    [[ "$output" != *"Mac mini 2018"* ]]
    [[ "$output" != *"Linux Mint"* ]]
}

@test "the README shows the quickstart commands, honestly" {
    run head -30 "$REPO/README.md"
    [[ "$output" == *"vmavs doctor"* ]]
    [[ "$output" == *"vmavs image"* ]]
    # vmavs run p4-linuxmedia forwards SSH on host port 2223; vmavs ssh
    # defaults to 2222. Pairing them as a bare "run then ssh" quickstart
    # would document a path that fails to connect, so if the README
    # mentions that pairing at all, the line right after it must not be a
    # bare, defaultport `vmavs ssh`.
    run bash -c "grep -A1 'vmavs run p4-linuxmedia' '$REPO/README.md' | tail -1"
    [ "$output" != "vmavs ssh" ]
}

@test "the README states the never-publish rule above the fold" {
    # In the global constraint's own words: the image OR A SNAPSHOT. An
    # earlier README said only "the guest image is never published".
    run head -45 "$REPO/README.md"
    [[ "$output" == *"Never publish the guest image or a snapshot"* ]]
    [[ "$output" == *"Apple"* ]]
}

@test "the README offers p4-linuxmedia only as a developer profile, with what it needs" {
    # Final review: the README offered `vmavs run p4-linuxmedia` as the way
    # to boot, but that profile boots work/p4-target.qcow2 with installer
    # media -- not the built image -- and nothing shipped creates that
    # disk or its VARS file, so on a fresh host it fails.
    run grep -B3 'vmavs run p4-linuxmedia' "$REPO/README.md"
    [[ "$output" == *"developer profile"* ]]
    [[ "$output" == *"work/p4-target.qcow2"* ]]
    run head -30 "$REPO/README.md"
    [[ "$output" == *"No shipped command boots the image"* ]]
    run grep -c 'most builds are tested against\|other pieces of getting from a' "$REPO/README.md"
    [ "$output" = "0" ]
}

@test "the README carries no unread-by-a-human marker" {
    # publish-release.yml refuses a first release while that line stands.
    run grep -c 'not been read or edited by a human' "$REPO/README.md" || true
    [ "$output" = "0" ]
}
