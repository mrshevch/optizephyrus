#!/usr/bin/env bash
# Самопроверка lib.sh без root:  bash test-lib.sh
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

echo "OK: lib.sh"
