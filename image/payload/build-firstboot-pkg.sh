#!/usr/bin/env bash
# Build the first-boot payload as a flat installer package, on Linux.
#
# The package is listed in OSInstall.collection, so Apple's installer
# installs it during the OS install. That is upstream's shape
# (timsutton/osx-vm-templates, create_firstboot_pkg) and it is better than
# injecting files into a finished volume: the installer writes them as root,
# at the moment the volume is already open, with no second pass and no
# second thing to keep correct.
#
# What goes in: firstboot.sh, com.mqg.firstboot.plist, the SSH public key,
# and a generated firstboot.conf carrying the parameters. What does not go
# in: any key committed to this repository. There is none, and the tests
# check for that.
#
# The container is written by ./mkflatpkg.py -- there is no xar(1) on this
# host and the project installs nothing. Read that file for the format and
# for why the package is payload-free.
set -euo pipefail

MQG_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"

HERE="$MQG_REPO_ROOT/image/payload"
MQG_IMAGE_DIR=${MQG_IMAGE_DIR:-$HOME/.local/share/mavericks-qemu-guest}

user=${MQG_FIRSTBOOT_USER:-mavsuser}
uid=${MQG_FIRSTBOOT_UID:-501}
gid=${MQG_FIRSTBOOT_GID:-20}
realname=${MQG_FIRSTBOOT_REALNAME:-Mavericks User}
hostname=${MQG_FIRSTBOOT_HOSTNAME:-mavericks}
shell=${MQG_FIRSTBOOT_SHELL:-/bin/bash}
autologin=1
# Never defaulted to anything. An image with no secret in it is the right
# default for something that is never published and is reached by key.
secret=${MQG_FIRSTBOOT_PASSWORD:-}
identifier=com.mqg.firstboot
version=1.0
ssh_key=${MQG_FIRSTBOOT_SSH_KEY:-}
# The guest's own OpenSSH. Not carried IN this package -- it is payload-free
# and the OpenSSH packages are 12 MB of product archive -- only named in the
# conf file, so ./postinstall knows what to copy off the media and
# firstboot.sh knows what to install. See image/fetch-openssh.sh.
openssh_pkgs=()
openssh_tag=
# Apple's post-10.9.5 updates, same arrangement as the OpenSSH packages
# above and for the same reason: 354 MB (or 685 MB) of product archive does
# not go inside a payload-free script package. They ride on the installer
# media, ./postinstall copies them to the target volume, firstboot.sh
# installs them. See image/fetch-updates.sh.
update_pkgs=()
updates=none
out=
describe=0

usage() {
    cat <<EOF
usage: $(basename "$0") [options]

  --ssh-key PATH   Public key to authorize for the guest account.
                   Default: the first of ~/.ssh/id_*.pub on this host.
  --user NAME      Account short name (default: $user)
  --uid N          (default: $uid)
  --gid N          Primary group (default: $gid, staff, as the click-log records)
  --realname TEXT  (default: $realname)
  --hostname NAME  ComputerName/HostName/LocalHostName (default: $hostname)
  --no-autologin   Do not enable auto-login.
  --openssh-pkg PATH
                   A Mavergreen/openssh package the media carries.
                   Pass both: the base package and the System-Replace one.
                   firstboot.sh installs them on the guest, which is what
                   lifts OpenSSH 6.2's Ed25519 and ssh-rsa limits. Without
                   any, the image keeps the stock OpenSSH 6.2 and an
                   Ed25519 key is refused below.
  --openssh-tag TAG
                   The release tag those packages came from, recorded in
                   the conf file so the guest can say what it has.
  --update-pkg PATH
                   A post-10.9.5 update package the media carries.
                   Repeatable, and ORDER MATTERS: they are installed in the
                   order given, before the OpenSSH packages above, because
                   Security Update 2016-004 replaces /usr/bin/ssh and
                   /usr/sbin/sshd and would otherwise undo them.
  --updates WHICH  Which selection those packages are (none, security,
                   all), recorded in the conf file so the guest can say
                   what it was asked to carry.
  --out PATH       Where to write the package
                   (default: \$MQG_IMAGE_DIR/payload/mqg-firstboot.pkg)
  --describe       Print what would be built and exit. Touches nothing.

Environment: MQG_FIRSTBOOT_PASSWORD sets an account secret. It is not
defaulted and never stored in the repository; without it the account has no
password and is reached by SSH key only.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --ssh-key) ssh_key=$2; shift ;;
        --user) user=$2; shift ;;
        --uid) uid=$2; shift ;;
        --gid) gid=$2; shift ;;
        --realname) realname=$2; shift ;;
        --hostname) hostname=$2; shift ;;
        --no-autologin) autologin=0 ;;
        --openssh-pkg) openssh_pkgs+=("$2"); shift ;;
        --openssh-tag) openssh_tag=$2; shift ;;
        --update-pkg) update_pkgs+=("$2"); shift ;;
        --updates) updates=$2; shift ;;
        --out) out=$2; shift ;;
        --describe) describe=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

out=${out:-$MQG_IMAGE_DIR/payload/mqg-firstboot.pkg}

if [ "$describe" -eq 1 ]; then
    cat <<EOF
first-boot payload package
  output            $out
  identifier        $identifier
  version           $version

  container         xar, written by image/payload/mkflatpkg.py
                    (no xar(1) on this host, and the project installs nothing)
  members           PackageInfo   the package description
                    Scripts       gzip-compressed odc cpio holding exactly
                                  one file, ./postinstall, with
                                  firstboot.sh, com.mqg.firstboot.plist,
                                  firstboot.conf and the authorized key
                                  embedded in it as quoted heredocs.
                                  PackageKit extracts only the file
                                  PackageInfo names, so a sibling is a file
                                  that will not be there.
  Bom, Payload      absent. This is a payload-free package, the shape
                    \`pkgbuild --nopayload\` produces, chosen because it is
                    the only flat package buildable here without
                    reimplementing mkbom.

  installed by      the OS X Installer, from OSInstall.collection, during
                    the install itself
  what it leaves    /private/var/db/.mqg-firstboot/{firstboot.sh,conf,keys}
                    /Library/LaunchDaemons/com.mqg.firstboot.plist
                    /private/var/db/.AppleSetupDone

  openssh           ${openssh_tag:-none}$([ "${#openssh_pkgs[@]}" -gt 0 ] && printf ' (%s)' "$(for p in ${openssh_pkgs[@]+"${openssh_pkgs[@]}"}; do printf '%s ' "$(basename "$p")"; done)")
  updates           $updates$([ "${#update_pkgs[@]}" -gt 0 ] && printf ' (%s)' "$(for p in ${update_pkgs[@]+"${update_pkgs[@]}"}; do printf '%s ' "$(basename "$p")"; done)")
                    installed BEFORE OpenSSH, in the order listed
                    named in firstboot.conf, carried on the media by
                    media/build-installer-img.sh --extra-pkg, installed on
                    the guest by firstboot.sh

  account           $user, uid $uid, gid $gid, admin
  hostname          $hostname
  auto-login        $([ "$autologin" = 1 ] && echo yes || echo no)
  ssh key           ${ssh_key:-<the first of ~/.ssh/id_*.pub>}
EOF
    exit 0
fi

require_cmd python3 sha256sum

if [ -z "$ssh_key" ]; then
    # The default is the build host's own key. Deliberately not "generate
    # one": a generated key would have to be stored somewhere, and a key
    # stored beside an image is a key that ends up published with it.
    for candidate in "$HOME"/.ssh/id_*.pub; do
        [ -f "$candidate" ] || continue
        ssh_key=$candidate
        break
    done
fi
[ -n "$ssh_key" ] || die "no SSH public key: pass --ssh-key PATH, or create" \
    "one with ssh-keygen. This pipeline will not generate a key into an image."
[ -f "$ssh_key" ] || die "no such SSH public key: $ssh_key"
grep -qE '^(ssh|ecdsa)-' "$ssh_key" \
    || die "$ssh_key does not look like an SSH public key"
case $(head -c 64 "$ssh_key") in
    *PRIVATE*) die "$ssh_key looks like a PRIVATE key. Pass the .pub." ;;
esac

# THE ED25519 QUESTION, WHICH --openssh-pkg ANSWERS
#
# Stock 10.9 ships OpenSSH 6.2. Ed25519 arrived in 6.5, in January 2014,
# three months after Mavericks shipped -- so on a stock guest an Ed25519
# key in authorized_keys is a line sshd cannot parse, and the only symptom
# is "Permission denied (publickey)" from a server that is otherwise
# working perfectly. That cost a full install to find.
#
# When the image carries Mavergreen/openssh, the guest's sshd is
# current and an Ed25519 key is simply a key. So this is no longer a
# property of "OS X 10.9"; it is a property of "an image built with
# --no-openssh", which is the only shape that still needs the refusal.
if [ "${#openssh_pkgs[@]}" -gt 0 ]; then
    case $(awk '{print $1}' < "$ssh_key") in
        ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-*|sk-*) : ;;
        *) warn "$ssh_key is a $(awk '{print $1}' < "$ssh_key") key;" \
                "OpenSSH $openssh_tag may not understand it" ;;
    esac
else
    case $(awk '{print $1}' < "$ssh_key") in
        ssh-ed25519|*ed25519*)
            die "$ssh_key is an Ed25519 key, and a stock OS X 10.9 guest" \
                "cannot use one: it ships OpenSSH 6.2, and Ed25519 arrived" \
                "in 6.5. Build the image with the family's OpenSSH (the" \
                "default -- see image/build-image.sh --openssh), or use an" \
                "RSA or ECDSA key:" \
                "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa" ;;
        ssh-rsa|ssh-dss|ecdsa-sha2-*) : ;;
        *) warn "$ssh_key is a $(awk '{print $1}' < "$ssh_key") key;" \
                "OS X 10.9's OpenSSH 6.2 may not understand it" ;;
    esac
fi

# The names travel through a space-separated shell list in firstboot.conf,
# so a name carrying whitespace would silently become two names that are
# not there. Reject it here, where the message can say so.
for pkg in ${openssh_pkgs[@]+"${openssh_pkgs[@]}"}; do
    [ -f "$pkg" ] || die "no such --openssh-pkg: $pkg"
    [ "$(head -c 4 "$pkg")" = "xar!" ] \
        || die "$pkg is not a flat package (no xar magic)"
    case $(basename "$pkg") in
        *[[:space:]]*) die "--openssh-pkg name contains whitespace:" \
                           "$(basename "$pkg")" ;;
    esac
done
if [ "${#openssh_pkgs[@]}" -gt 0 ] && [ -z "$openssh_tag" ]; then
    die "--openssh-pkg needs --openssh-tag: an image must record which" \
        "OpenSSH it was built with"
fi

# The same checks, for the same reason, on the update packages: their names
# travel through a space-separated shell list in firstboot.conf.
for pkg in ${update_pkgs[@]+"${update_pkgs[@]}"}; do
    [ -f "$pkg" ] || die "no such --update-pkg: $pkg"
    [ "$(head -c 4 "$pkg")" = "xar!" ] \
        || die "$pkg is not a flat package (no xar magic)"
    case $(basename "$pkg") in
        *[[:space:]]*) die "--update-pkg name contains whitespace:" \
                           "$(basename "$pkg")" ;;
    esac
done
case $updates in
    none|security|all) : ;;
    *) die "unknown --updates '$updates': choose none, security or all" ;;
esac
if [ "${#update_pkgs[@]}" -gt 0 ] && [ "$updates" = none ]; then
    die "--update-pkg was given but --updates says none;" \
        "the image would carry packages it does not admit to"
fi
if [ "${#update_pkgs[@]}" -eq 0 ] && [ "$updates" != none ]; then
    die "--updates $updates names no packages -- image/fetch-updates.sh" \
        "should have produced some"
fi

mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"

# Two directories, not one. $staging becomes the package's Scripts archive
# verbatim -- every file in it is packaged -- so the intermediates used to
# assemble postinstall have to live somewhere else. They did not, once, and
# the package shipped its own scaffolding.
staging=$(mktemp -d) || die "cannot create a staging directory"
assembly=$(mktemp -d) || die "cannot create an assembly directory"
trap 'rm -rf "$staging" "$assembly"' EXIT

# The parameters travel as a conf file rather than as edits to firstboot.sh,
# so the script in the repository is the script in the image and a diff
# between them means something.
{
    printf '# Generated by image/payload/build-firstboot-pkg.sh. Do not edit.\n'
    printf 'MQG_FB_USER=%q\n' "$user"
    printf 'MQG_FB_UID=%q\n' "$uid"
    printf 'MQG_FB_GID=%q\n' "$gid"
    printf 'MQG_FB_ADMIN_GID=80\n'
    printf 'MQG_FB_REALNAME=%q\n' "$realname"
    printf 'MQG_FB_SHELL=%q\n' "$shell"
    printf 'MQG_FB_HOSTNAME=%q\n' "$hostname"
    printf 'MQG_FB_AUTOLOGIN=%q\n' "$autologin"
    if [ "${#openssh_pkgs[@]}" -gt 0 ]; then
        printf 'MQG_FB_OPENSSH=1\n'
        printf 'MQG_FB_OPENSSH_TAG=%q\n' "$openssh_tag"
        # Space-separated basenames, deliberately unquoted where it is read:
        # ./postinstall walks the list with `for x in $MQG_FB_EXTRA_PKGS`.
        # A package name with a space in it would break that, which is why
        # the names are checked below rather than hoped about.
        printf 'MQG_FB_EXTRA_PKGS=%q\n' \
            "$(for p in ${openssh_pkgs[@]+"${openssh_pkgs[@]}"}; do \
                   printf '%s ' "$(basename "$p")"; done)"
    else
        printf 'MQG_FB_OPENSSH=0\n'
    fi
    # WRITTEN ONLY WHEN THERE IS SOMETHING TO SAY.
    #
    # firstboot.sh defaults MQG_FB_UPDATES to none, so a `--updates none`
    # image's conf file is BYTE-IDENTICAL to one built before this switch
    # had a second value. That is deliberate: none is P5's baseline and
    # every performance measurement compares against it.
    if [ "${#update_pkgs[@]}" -gt 0 ]; then
        printf 'MQG_FB_UPDATES=%q\n' "$updates"
        # Space-separated basenames, IN INSTALL ORDER, read the same way
        # MQG_FB_EXTRA_PKGS is. image/fetch-updates.sh gives every one an
        # mqg-update-NN- prefix, so the order is legible in the names too.
        printf 'MQG_FB_UPDATE_PKGS=%q\n' \
            "$(for p in ${update_pkgs[@]+"${update_pkgs[@]}"}; do \
                   printf '%s ' "$(basename "$p")"; done)"
    fi
    if [ -n "$secret" ]; then
        printf 'MQG_FB_PASSWORD=%q\n' "$secret"
    fi
} > "$assembly/firstboot.conf"
chmod 600 "$assembly/firstboot.conf"

# ONE FILE GOES IN THE PACKAGE, AND IT CONTAINS EVERYTHING.
#
# The first version shipped five files in Scripts and had postinstall copy
# its four siblings. PackageKit materialised only `postinstall` -- the file
# PackageInfo's <scripts> element names -- so the install produced a system
# with Setup Assistant skipped and no account on it, which is worse than
# either working or failing. See the P4 Task 6 entry in NOTES.md.
#
# So the four data files are embedded into postinstall as quoted heredocs.
# Quoted, so nothing in them is expanded; and the delimiters are long enough
# that no line of a shell script, an XML plist or an SSH key could collide
# with one.
embed() {
    local var=$1 src=$2 dst=$3 mode=$4
    printf 'say "writing %s"\n' "$dst"
    printf "cat > \"%s\" <<'MQG_EOF_%s'\n" "$dst" "$var"
    cat "$src"
    printf 'MQG_EOF_%s\n' "$var"
    printf 'chmod %s "%s" 2>/dev/null\n\n' "$mode" "$dst"
}

# The '$CONF_DIR' and '$DAEMON' below are single-quoted on purpose: they
# are variables for the GENERATED script to expand on the guest, not here.
# shellcheck disable=SC2016
{
    embed FIRSTBOOT_SH "$HERE/firstboot.sh" \
        '$CONF_DIR/firstboot.sh' 755
    embed FIRSTBOOT_CONF "$assembly/firstboot.conf" \
        '$CONF_DIR/firstboot.conf' 600
    embed AUTHORIZED_KEYS "$ssh_key" \
        '$CONF_DIR/authorized_keys' 644
    embed LAUNCHDAEMON "$HERE/com.mqg.firstboot.plist" \
        '$DAEMON' 644
} > "$assembly/embedded.sh"

python3 - "$HERE/postinstall" "$assembly/embedded.sh" "$staging/postinstall" \
    <<'PYEOF' || die "cannot assemble the postinstall script"
import sys

template, embedded, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(template) as fh:
    text = fh.read()
marker = "#MQG_EMBEDDED_FILES\n"
if marker not in text:
    sys.exit("%s has no %s line to substitute" % (template, marker.strip()))
with open(embedded) as fh:
    body = fh.read()
with open(out, "w") as fh:
    fh.write(text.replace(marker, body, 1))
PYEOF
chmod 755 "$staging/postinstall"

# A last check before it is sealed into a package: the assembled script has
# to be valid shell. A syntax error here becomes "Install Failed" twenty
# minutes into a VM boot.
sh -n "$staging/postinstall" \
    || die "the assembled postinstall is not valid shell"

python3 "$HERE/mkflatpkg.py" --scripts "$staging" \
    --identifier "$identifier" --version "$version" --out "$out" >&2 \
    || die "could not build $out"

sum=$(sha256_file "$out")
printf '%s  %s\n' "$sum" "$(basename "$out")" > "$out.sha256"
log "built $out ($(stat -c %s "$out") bytes), sha256 $sum"
log "authorized key: $(awk '{print $1, substr($2,1,16) "..."}' < "$ssh_key")"
printf '%s\n' "$out"
