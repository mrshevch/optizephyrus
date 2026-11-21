#!/usr/bin/env bash
# Самопроверка lib.sh и g14-wifi-powersave без root:  bash test-lib.sh
set -euo pipefail
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
DRY=0
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
BK="$T/bk"; mkdir -p "$BK"; : > "$BK/created-files.txt"
f="$T/etc/a.conf"
fail() { echo "FAIL: $*"; exit 1; }

put "$f" <<< "x = 1" >/dev/null
[[ "$(cat "$f")" == "x = 1" && $CHANGES -eq 1 ]]          || fail "новый файл не создан"
grep -qx "$f" "$BK/created-files.txt"                     || fail "новый файл не записан в created-files.txt"

out="$(put "$f" <<< "x = 1")"
[[ $out == *"✓"* && $CHANGES -eq 1 ]]                     || fail "одинаковый файл не пропущен"

out="$(put "$f" <<< "x = 2"; echo "n=$CHANGES")"
[[ $out == *"~ update"* && $out == *"+x = 2"* && $out == *"n=2"* ]] || fail "нет diff для изменённого файла"
[[ "$(cat "$BK$f")" == "x = 1" && "$(cat "$f")" == "x = 2" ]]      || fail "нет бэкапа прежней версии"

DRY=1; put "$f" <<< "x = 3" >/dev/null
[[ "$(cat "$f")" == "x = 2" ]]                            || fail "dry-run изменил файл"

printf '# c\nvm.swappiness = %s\n' "$(sysctl -n vm.swappiness)" > "$T/s.conf"
sysctl_live "$T/s.conf"                                   || fail "sysctl_live не видит действующее значение"
echo "vm.swappiness = 12345" > "$T/s.conf"
! sysctl_live "$T/s.conf"                                 || fail "sysctl_live пропустил отличие"

n=$CHANGES; pkgs bash >/dev/null
[[ $CHANGES -eq $n ]]                                     || fail "pkgs ставит уже установленный пакет"
out="$(pkgs --allowerasing bash no-such-pkg-xyz)"
[[ $out == "+ dnf -y install --allowerasing no-such-pkg-xyz" ]] || fail "pkgs должен ставить только недостающие: $out"

# --- g14-wifi-powersave: заглушка iw пишет свои аргументы в лог ---
H="$(dirname "${BASH_SOURCE[0]}")/g14-wifi-powersave"
mkdir -p "$T/iwbin" "$T/net/wlx/wireless" "$T/net/eth0"
printf '#!/bin/sh\necho "$*" >> "%s/iw.log"\n' "$T" > "$T/iwbin/iw"; chmod +x "$T/iwbin/iw"
wps() { rm -f "$T/iw.log"; G14_AC_ONLINE="$T/ac" G14_NET="$T/net" PATH="$T/iwbin:$PATH" bash "$H"; }

echo 0 > "$T/ac"; wps
[[ "$(cat "$T/iw.log")" == "dev wlx set power_save on" ]]   || fail "на батарее power save не включён"
echo 1 > "$T/ac"; wps
[[ "$(cat "$T/iw.log")" == "dev wlx set power_save off" ]]  || fail "от сети power save не выключен"
rm "$T/ac"; wps
[[ "$(cat "$T/iw.log")" == "dev wlx set power_save off" ]]  || fail "без AC0 должно быть как от сети"
rm -r "$T/net/wlx"; echo 0 > "$T/ac"; wps
[[ ! -e "$T/iw.log" ]]                                       || fail "iw вызван без Wi-Fi-интерфейсов"
mkdir -p "$T/net/wlx/wireless"; printf '#!/bin/sh\nexit 1\n' > "$T/iwbin/iw"
wps                                                          || fail "ошибка iw уронила помощник"

# --- unpkgs / mask_user: только недостающее, в dry-run бэкап не трогают ---
DRY=1; BK="$T/nobk"
out="$(unpkgs no-such-pkg-xyz)"
[[ $out == *"✓"* ]]                                              || fail "unpkgs: неустановленный пакет не пропущен"
out="$(unpkgs bash no-such-pkg-xyz)"
[[ $out == "+ dnf -y remove bash" ]]                             || fail "unpkgs должен удалять только установленные: $out"
out="$(mask_user no-such-unit-xyz.service)"
[[ $out == "+ systemctl --global mask no-such-unit-xyz.service" ]] || fail "mask_user: $out"
mkdir -p "$T/sdbin"; printf '#!/bin/sh\necho masked\n' > "$T/sdbin/systemctl"; chmod +x "$T/sdbin/systemctl"
out="$(PATH="$T/sdbin:$PATH" mask_user x.service)"
[[ $out == *"✓"* ]]                                              || fail "mask_user: замаскированный не пропущен"
[[ ! -e $BK ]]                                                   || fail "dry-run записал в бэкап"
DRY=0; BK="$T/bk2"; mkdir -p "$BK" "$T/stub"   # вне dry-run: заглушки вместо dnf/systemctl, проверяем журналы для rollback
printf '#!/bin/sh\necho enabled\n' > "$T/stub/systemctl"; printf '#!/bin/sh\nexit 0\n' > "$T/stub/dnf"; chmod +x "$T/stub/"*
PATH="$T/stub:$PATH" unpkgs bash no-such-pkg-xyz >/dev/null
PATH="$T/stub:$PATH" mask_user a.service b.service >/dev/null
[[ "$(cat "$BK/removed-packages.txt")" == "bash" ]]                  || fail "unpkgs: журнал удалённых пакетов"
[[ "$(cat "$BK/masked-user-units.txt")" == $'a.service\nb.service' ]] || fail "mask_user: журнал замаскированных юнитов"

echo "OK: lib.sh"
