#!/usr/bin/env bash
# Self-test for lib.sh and g14-wifi-powersave, runs without root:  bash test-lib.sh
set -euo pipefail
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
DRY=0
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BK="$T/bk"; mkdir -p "$BK"; : > "$BK/created-files.txt"
f="$T/etc/a.conf"
fail() { echo "FAIL: $*"; exit 1; }

put "$f" <<< "x = 1" >/dev/null
[[ "$(cat "$f")" == "x = 1" && $CHANGES -eq 1 ]]          || fail "new file was not created"
grep -qx "$f" "$BK/created-files.txt"                     || fail "new file is missing from created-files.txt"

out="$(put "$f" <<< "x = 1")"
[[ $out == *"✓"* && $CHANGES -eq 1 ]]                     || fail "identical file was not skipped"

out="$(put "$f" <<< "x = 2"; echo "n=$CHANGES")"
[[ $out == *"~ update"* && $out == *"+x = 2"* && $out == *"n=2"* ]] || fail "no diff for a changed file"
[[ "$(cat "$BK$f")" == "x = 1" && "$(cat "$f")" == "x = 2" ]]      || fail "no backup of the previous version"

DRY=1; put "$f" <<< "x = 3" >/dev/null
[[ "$(cat "$f")" == "x = 2" ]]                            || fail "dry-run changed the file"

printf '# c\nvm.swappiness = %s\n' "$(sysctl -n vm.swappiness)" > "$T/s.conf"
sysctl_live "$T/s.conf"                                   || fail "sysctl_live does not see the live value"
echo "vm.swappiness = 12345" > "$T/s.conf"
! sysctl_live "$T/s.conf"                                 || fail "sysctl_live missed a difference"

n=$CHANGES; pkgs bash >/dev/null
[[ $CHANGES -eq $n ]]                                     || fail "pkgs installs a package that is already installed"
out="$(pkgs --allowerasing bash no-such-pkg-xyz)"
[[ $out == "+ dnf -y install --allowerasing no-such-pkg-xyz" ]] || fail "pkgs must install only the missing ones: $out"

# --- g14-wifi-powersave: a stub iw writes its arguments to a log ---
H="$(dirname "${BASH_SOURCE[0]}")/g14-wifi-powersave"
mkdir -p "$T/iwbin" "$T/net/wlx/wireless" "$T/net/eth0"
printf '#!/bin/sh\necho "$*" >> "%s/iw.log"\n' "$T" > "$T/iwbin/iw"; chmod +x "$T/iwbin/iw"
wps() { rm -f "$T/iw.log"; G14_AC_ONLINE="$T/ac" G14_NET="$T/net" PATH="$T/iwbin:$PATH" bash "$H"; }

echo 0 > "$T/ac"; wps
[[ "$(cat "$T/iw.log")" == "dev wlx set power_save on" ]]   || fail "power save not turned on on battery"
echo 1 > "$T/ac"; wps
[[ "$(cat "$T/iw.log")" == "dev wlx set power_save off" ]]  || fail "power save not turned off on AC"
rm "$T/ac"; wps
[[ ! -e "$T/iw.log" ]]                                       || fail "power save must be left alone without AC0"
echo x > "$T/ac"; wps
[[ ! -e "$T/iw.log" ]]                                       || fail "power save must be left alone when AC0 is unclear"
rm -r "$T/net/wlx"; echo 0 > "$T/ac"; wps
[[ ! -e "$T/iw.log" ]]                                       || fail "iw called without Wi-Fi interfaces"
mkdir -p "$T/net/wlx/wireless"; printf '#!/bin/sh\nexit 1\n' > "$T/iwbin/iw"
wps                                                          || fail "an iw error made the helper fail"

# --- unpkgs / mask_user: only what is needed, no backup writes in dry-run ---
DRY=1; BK="$T/nobk"
out="$(unpkgs no-such-pkg-xyz)"
[[ $out == *"✓"* ]]                                              || fail "unpkgs: package that is not installed was not skipped"
out="$(unpkgs bash no-such-pkg-xyz)"
[[ $out == "+ dnf -y remove bash" ]]                             || fail "unpkgs must remove only installed packages: $out"
out="$(mask_user no-such-unit-xyz.service)"
[[ $out == "+ systemctl --global mask no-such-unit-xyz.service" ]] || fail "mask_user: $out"
mkdir -p "$T/sdbin"; printf '#!/bin/sh\necho masked\n' > "$T/sdbin/systemctl"; chmod +x "$T/sdbin/systemctl"
out="$(PATH="$T/sdbin:$PATH" mask_user x.service)"
[[ $out == *"✓"* ]]                                              || fail "mask_user: masked unit was not skipped"
[[ ! -e $BK ]]                                                   || fail "dry-run wrote to the backup"
DRY=0; BK="$T/bk2"; mkdir -p "$BK" "$T/stub"   # not dry-run: stubs replace dnf/systemctl, check the logs rollback reads
printf '#!/bin/sh\necho enabled\n' > "$T/stub/systemctl"; printf '#!/bin/sh\nexit 0\n' > "$T/stub/dnf"; chmod +x "$T/stub/"*
PATH="$T/stub:$PATH" unpkgs bash no-such-pkg-xyz >/dev/null
PATH="$T/stub:$PATH" mask_user a.service b.service >/dev/null
[[ "$(cat "$BK/removed-packages.txt")" == "bash" ]]                  || fail "unpkgs: removed-packages log"
[[ "$(cat "$BK/masked-user-units.txt")" == $'a.service\nb.service' ]] || fail "mask_user: masked-user-units log"

echo "OK: lib.sh"
