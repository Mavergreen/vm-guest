#!/bin/sh
# What Setup Assistant would have done, done once, with nobody watching.
#
# WHERE THIS RUNS
#
# On the installed Mavericks system, as root, on its first boot, launched by
# /Library/LaunchDaemons/com.mqg.firstboot.plist. Both this script and that
# plist are put there at install time by ./postinstall, which the OS X
# Installer runs because mqg-firstboot.pkg is listed in
# OSInstall.collection -- so the payload is installed *as part of the
# install*, not injected into a finished volume afterwards.
#
# WHAT IT IS A SPECIFICATION OF
#
# docs/install-log.md's "First boot and Setup Assistant" section: the list
# of what Setup Assistant actually asks. That log exists so this script
# could be written against something observed rather than remembered.
#
# IT RUNS EXACTLY ONCE
#
# The last thing it does is remove its own LaunchDaemon. A first-boot script
# that runs on every boot silently undoes manual changes for the rest of the
# image's life, and the symptom turns up long after the cause. Removing the
# plist is therefore not tidiness, it is the safety property.
#
# NOTHING HERE MAY HANG FOREVER
#
# This is a 2013 OS that may be talking to Apple's 2026 servers. Every step
# runs under run_with_timeout and every failure is non-fatal: a payload that
# skips a nicety is better than a payload that never finishes and leaves an
# image with no account on it.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

CONF_DIR=/private/var/db/.mqg-firstboot
LOG=/private/var/log/mqg-firstboot.log
DAEMON=/Library/LaunchDaemons/com.mqg.firstboot.plist
DONE_MARKER=$CONF_DIR/.done

# Defaults, overridden by the conf file the build writes next to this
# script. They are here so the script is readable on its own and so a hand
# run in a rescue shell does something sensible.
MQG_FB_USER=mavsuser
MQG_FB_UID=501
MQG_FB_GID=20
MQG_FB_ADMIN_GID=80
MQG_FB_REALNAME="Mavericks User"
MQG_FB_SHELL=/bin/bash
MQG_FB_HOSTNAME=mavericks
MQG_FB_AUTOLOGIN=1

[ -r "$CONF_DIR/firstboot.conf" ] && . "$CONF_DIR/firstboot.conf"

say() {
    echo "mqg-firstboot: $*"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') mqg-firstboot: $*" >> "$LOG" 2>/dev/null
}

# 10.9 has no timeout(1), so here is one: run the command in the background
# with a watchdog beside it, and kill it if it outstays its welcome.
#
# Used for everything, not only the network-touching steps, because the
# distinction is less clean than it looks -- systemsetup and dscl both talk
# to launchd and opendirectoryd, either of which can be slow or wedged on a
# system that has never booted before.
run_with_timeout() {
    _limit=$1
    shift
    say "run (${_limit}s limit): $*"
    "$@" >> "$LOG" 2>&1 &
    _pid=$!
    (
        _n=0
        while [ "$_n" -lt "$_limit" ]; do
            kill -0 "$_pid" 2>/dev/null || exit 0
            sleep 1
            _n=$((_n + 1))
        done
        echo "mqg-firstboot: TIMED OUT after ${_limit}s: $*" >> "$LOG"
        kill -9 "$_pid" 2>/dev/null
    ) &
    _dog=$!
    wait "$_pid" 2>/dev/null
    _rc=$?
    kill "$_dog" 2>/dev/null
    [ "$_rc" -eq 0 ] || say "  -> rc=$_rc (continuing; nothing here is fatal)"
    return 0
}

if [ -e "$DONE_MARKER" ]; then
    say "already ran (marker $DONE_MARKER exists); doing nothing"
    exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
say "starting on $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null)"

# --- Setup Assistant -------------------------------------------------------
#
# ./postinstall already created this at install time, which is what actually
# wins the race against loginwindow. Doing it again here is belt and braces
# and makes this script correct when run by hand on a system that has not
# had the package installed.
touch /private/var/db/.AppleSetupDone 2>/dev/null
touch /private/var/db/.AppleDiagnosticsSetupDone 2>/dev/null
say ".AppleSetupDone present: $([ -e /private/var/db/.AppleSetupDone ] && echo yes || echo no)"

# --- wait for Open Directory ----------------------------------------------
#
# dscl needs opendirectoryd, and a LaunchDaemon with RunAtLoad can easily
# beat it there on a system booting for the very first time.
waited=0
while ! dscl . -list /Users >/dev/null 2>&1; do
    if [ "$waited" -ge 120 ]; then
        say "opendirectoryd never answered in ${waited}s; the account cannot be created"
        break
    fi
    sleep 2
    waited=$((waited + 2))
done
say "opendirectoryd answered after ${waited}s"

# --- the account -----------------------------------------------------------
#
# docs/install-log.md records what Setup Assistant produced: uid 501, gid 20
# (staff), and membership of group 80 (admin). This reproduces that rather
# than inventing a different shape of account.
#
# Idempotent on purpose: the payload is also tested against a clone that
# already has this account, and an account half-created by an interrupted
# run must be repairable by running this again.
if dscl . -read "/Users/$MQG_FB_USER" >/dev/null 2>&1; then
    say "account $MQG_FB_USER already exists; updating it rather than failing"
else
    say "creating account $MQG_FB_USER"
    run_with_timeout 60 dscl . -create "/Users/$MQG_FB_USER"
fi

run_with_timeout 60 dscl . -create "/Users/$MQG_FB_USER" UserShell "$MQG_FB_SHELL"
run_with_timeout 60 dscl . -create "/Users/$MQG_FB_USER" RealName "$MQG_FB_REALNAME"
run_with_timeout 60 dscl . -create "/Users/$MQG_FB_USER" UniqueID "$MQG_FB_UID"
run_with_timeout 60 dscl . -create "/Users/$MQG_FB_USER" PrimaryGroupID "$MQG_FB_GID"
run_with_timeout 60 dscl . -create "/Users/$MQG_FB_USER" \
    NFSHomeDirectory "/Users/$MQG_FB_USER"
run_with_timeout 60 dscl . -append /Groups/admin GroupMembership "$MQG_FB_USER"
run_with_timeout 60 dscl . -append /Groups/admin GroupMembers \
    "$(dscl . -read "/Users/$MQG_FB_USER" GeneratedUID 2>/dev/null | awk 'NR==1{print $2}')"

# The secret, if there is one, arrives in the conf file the build writes --
# never in this script, and never in the repository. An image with no
# secret in it is the default: MQG_FB_PASSWORD unset means the account has
# none, which is right for a local image that is never published and is
# reached by key.
if [ -n "${MQG_FB_PASSWORD:-}" ]; then
    run_with_timeout 60 dscl . -passwd "/Users/$MQG_FB_USER" "$MQG_FB_PASSWORD"
else
    say "no account secret configured; the account is reached by SSH key"
fi

say "group $MQG_FB_ADMIN_GID (admin) now: $(dscl . -read /Groups/admin GroupMembership 2>/dev/null)"
say "group $MQG_FB_ADMIN_GID gid check: $(dscl . -read /Groups/admin PrimaryGroupID 2>/dev/null)"

# --- home directory --------------------------------------------------------
if [ -d "/Users/$MQG_FB_USER" ]; then
    say "/Users/$MQG_FB_USER already exists"
else
    run_with_timeout 120 createhomedir -c -u "$MQG_FB_USER"
fi
if [ ! -d "/Users/$MQG_FB_USER" ]; then
    say "createhomedir produced nothing; falling back to the user template"
    mkdir -p "/Users/$MQG_FB_USER"
    ditto "/System/Library/User Template/English.lproj" "/Users/$MQG_FB_USER" \
        >> "$LOG" 2>&1
fi
chown -R "$MQG_FB_UID:$MQG_FB_GID" "/Users/$MQG_FB_USER" 2>/dev/null

# --- the SSH key -----------------------------------------------------------
#
# The key is a build-time parameter (image/payload/build-firstboot-pkg.sh
# --ssh-key), so it travels in the package rather than in the repository.
if [ -s "$CONF_DIR/authorized_keys" ]; then
    mkdir -p "/Users/$MQG_FB_USER/.ssh"
    cp "$CONF_DIR/authorized_keys" "/Users/$MQG_FB_USER/.ssh/authorized_keys"
    chmod 700 "/Users/$MQG_FB_USER/.ssh"
    chmod 600 "/Users/$MQG_FB_USER/.ssh/authorized_keys"
    chown -R "$MQG_FB_UID:$MQG_FB_GID" "/Users/$MQG_FB_USER/.ssh"
    say "installed $(wc -l < "$CONF_DIR/authorized_keys") authorized key line(s)"
else
    say "no authorized_keys in the package; SSH will accept no key"
fi

# --- Remote Login ----------------------------------------------------------
#
# Both spellings, because they fail differently. systemsetup is the
# documented one but asks an interactive yes/no question without -f; loading
# the job directly is what actually has to end up true.
run_with_timeout 60 systemsetup -f -setremotelogin on
run_with_timeout 60 launchctl load -w /System/Library/LaunchDaemons/ssh.plist
say "remote login: $(systemsetup -getremotelogin 2>&1)"

# --- sleep, screensaver ----------------------------------------------------
#
# An image that sleeps is an image that stops answering SSH, and an image
# that runs a screensaver spends its CPU on it -- which would land in P5's
# measurements as though it were the guest being slow.
run_with_timeout 60 systemsetup -setsleep Never
run_with_timeout 60 systemsetup -setcomputersleep Never
run_with_timeout 60 systemsetup -setdisplaysleep Never
run_with_timeout 60 systemsetup -setharddisksleep Never

defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0
su - "$MQG_FB_USER" -c \
    'defaults -currentHost write com.apple.screensaver idleTime 0' \
    >> "$LOG" 2>&1
pmset -a displaysleep 0 disksleep 0 sleep 0 >> "$LOG" 2>&1

# --- software update -------------------------------------------------------
#
# This is the step most likely to hang: a 2013 OS asking Apple's 2026
# servers about updates. Under run_with_timeout, non-fatal, and the whole
# question of whether images should carry post-10.9.5 updates is
# docs/open-questions.md Q1 -- which this deliberately does not answer.
# Turning the *schedule* off is not the same as deciding no updates: it
# stops the guest reaching out on its own, which a reproducible image must
# not do.
run_with_timeout 120 softwareupdate --schedule off

# --- identity --------------------------------------------------------------
#
# docs/install-log.md notes that Setup Assistant derived "Maverickss-iMac"
# from the full name and that P4 should set this deliberately instead.
run_with_timeout 30 scutil --set ComputerName "$MQG_FB_HOSTNAME"
run_with_timeout 30 scutil --set HostName "$MQG_FB_HOSTNAME"
run_with_timeout 30 scutil --set LocalHostName "$MQG_FB_HOSTNAME"

# --- auto-login ------------------------------------------------------------
#
# The click-log records that Setup Assistant turned this on for a
# single-user system, and that later phases lean on it: an unattended boot
# must not stall at a login window. Skipping Setup Assistant means nothing
# turned it on, so we do.
#
# /etc/kcpassword holds the account secret obfuscated -- not encrypted --
# with a fixed key. That is Apple's design, it is why auto-login and "never
# publish the guest image" belong in the same sentence, and it is written
# here only when a secret was configured at build time.
if [ "$MQG_FB_AUTOLOGIN" = "1" ]; then
    defaults write /Library/Preferences/com.apple.loginwindow \
        autoLoginUser "$MQG_FB_USER"
    if [ -n "${MQG_FB_PASSWORD:-}" ]; then
        printf '%s' "$MQG_FB_PASSWORD" | perl -e '
            my @k = (0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F);
            my $p = do { local $/; <STDIN> };
            my @o;
            for my $i (0 .. length($p) - 1) {
                push @o, ord(substr($p, $i, 1)) ^ $k[$i % 11];
            }
            push @o, $k[scalar(@o) % 11] while scalar(@o) % 12;
            print pack("C*", @o);
        ' > /private/etc/kcpassword 2>>"$LOG"
        chmod 600 /private/etc/kcpassword 2>/dev/null
    fi
    say "auto-login set to $MQG_FB_USER"
fi

# --- verdict ---------------------------------------------------------------
say "account: $(id "$MQG_FB_USER" 2>&1)"
say "sshd job: $(launchctl list 2>/dev/null | grep -c com.openssh.sshd) entries"

# Copy the log somewhere a host can find it without a running VM: the log in
# /private/var/log is fine once SSH works, and useless when it does not.
cp "$LOG" /.mqg-firstboot.log 2>/dev/null

# Written BEFORE the LaunchDaemon is removed, so that a machine losing power
# between the two lines still refuses to run this again.
mkdir -p "$CONF_DIR" 2>/dev/null
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$DONE_MARKER"

# --- run exactly once ------------------------------------------------------
#
# REMOVE THE FILE FIRST, AND DO NOT UNLOAD.
#
# The first version called `launchctl unload "$DAEMON"` and then `rm -f`.
# Unloading the job that is running this script terminates the script, so
# the `rm` never happened: the log ended at the line above, the plist stayed
# in /Library/LaunchDaemons, and every later boot started firstboot.sh
# again. The marker below is what made that harmless -- it is the second
# guard, and it is the one that held when the first one broke. Both are
# worth keeping for exactly that reason.
#
# There is nothing to unload anyway. The job has no KeepAlive, so launchd
# does not restart it, and removing the plist means there is no job at the
# next boot.
say "removing the LaunchDaemon so this never runs again"
rm -f "$DAEMON"
say "LaunchDaemon gone: $([ -e "$DAEMON" ] && echo NO || echo yes)"

# Restart loginwindow so auto-login takes effect on this boot rather than
# the next one. loginwindow started before the account existed, so it has no
# idea about it; this is what turns a login window into a desktop without a
# reboot.
if [ "$MQG_FB_AUTOLOGIN" = "1" ]; then
    say "restarting loginwindow so auto-login applies now"
    killall -HUP loginwindow 2>/dev/null || killall loginwindow 2>/dev/null
fi

say "done"
exit 0
