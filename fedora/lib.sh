# shellcheck shell=bash disable=SC2034  # переменные читают подключающие скрипты
# Общие функции optimize.sh и gaming.sh (подключается через source; перед ним должен быть задан DRY).
# Каждый шаг сначала проверяет, применён ли он: уже применённое печатается «✓», изменения — «+»/«~».

BK="/var/backups/os-tune-$(date +%Y%m%d-%H%M%S)"
CHANGES=0   # сколько изменений внесено (в --dry-run — было бы внесено)
CHANGED=0   # было ли изменение в текущем разделе; сбрасывается в log()
REBOOT=0    # нужна ли перезагрузка

log()  { CHANGED=0; printf '\n\e[1;34m==> %s\e[0m\n' "$*"; }
ok()   { printf '  \e[32m✓ %s\e[0m\n' "$*"; }
run()  { echo "+ $*"; CHANGES=$((CHANGES+1)); CHANGED=1; [[ $DRY -eq 1 ]] || "$@"; }

put()  { # put <файл> ; содержимое из stdin. Файл с тем же содержимым не трогает, для изменённого печатает diff
  local f="$1" new; new="$(cat)"
  if [[ -f "$f" && "$(cat "$f")" == "$new" ]]; then ok "$f — без изменений"; return; fi
  CHANGES=$((CHANGES+1)); CHANGED=1
  if [[ -e "$f" ]]; then
    echo "~ update $f"; diff -u "$f" <(printf '%s\n' "$new") | tail -n +3 | sed 's/^/    /' || true
  else
    echo "+ write $f"; printf '%s\n' "$new" | sed 's/^/    /'
  fi
  if [[ $DRY -eq 1 ]]; then return; fi
  [[ -e "$f" ]] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }
  echo "$f" >> "$BK/created-files.txt"
  mkdir -p "$(dirname "$f")"; printf '%s\n' "$new" > "$f"
}

pkgs() { # pkgs [--опции dnf] <пакет>... — dnf install только недостающих
  local a o=() p=() m=()
  for a in "$@"; do
    if [[ $a == -* ]]; then o+=("$a"); else p+=("$a"); rpm -q "$a" &>/dev/null || m+=("$a"); fi
  done
  if [[ ${#m[@]} -eq 0 ]]; then ok "уже установлены: ${p[*]}"; else run dnf -y install "${o[@]}" "${m[@]}"; fi
}

unpkgs() { # unpkgs <пакет>... — dnf remove только установленных; имена — в removed-packages.txt, rollback поставит их обратно
  local p m=()
  for p in "$@"; do if rpm -q "$p" &>/dev/null; then m+=("$p"); fi; done
  if [[ ${#m[@]} -eq 0 ]]; then ok "уже удалены: $*"; return; fi
  [[ $DRY -eq 1 ]] || printf '%s\n' "${m[@]}" >> "$BK/removed-packages.txt"
  run dnf -y remove "${m[@]}"
}

mask_user() { # mask_user <юнит>... — systemctl --global mask только ещё не замаскированных; имена — в masked-user-units.txt
  local u m=()
  for u in "$@"; do [[ "$(systemctl --global is-enabled "$u" 2>/dev/null)" == masked ]] || m+=("$u"); done
  if [[ ${#m[@]} -eq 0 ]]; then ok "уже замаскированы: $*"; return; fi
  [[ $DRY -eq 1 ]] || printf '%s\n' "${m[@]}" >> "$BK/masked-user-units.txt"
  run systemctl --global mask "${m[@]}"
}

# Без «| grep -q»: с pipefail ранний выход grep убивает писателя SIGPIPE и даёт ложное «нет»
repo_on() { [[ -n "$(dnf -q repolist --enabled "$1" 2>/dev/null)" ]]; }
karg_on() { [[ " $(grubby --info=DEFAULT | sed -n 's/^args="\(.*\)"$/\1/p') " == *" $1 "* ]]; }

sysctl_live() { # все «ключ = значение» из файла уже действуют в ядре
  local k v
  while IFS='=' read -r k v; do
    k="${k//[[:space:]]/}"; v="${v//[[:space:]]/}"
    [[ -z "$k" || $k == \#* ]] && continue
    [[ "$(sysctl -n "$k" 2>/dev/null)" == "$v" ]] || return 1
  done < "$1"
}

summary() { # нет изменений → удалить пустой бэкап и выйти; dry-run → итог и выход
  if [[ $CHANGES -eq 0 ]]; then
    [[ $DRY -eq 1 ]] || rm -rf "$BK"
    log "Всё уже применено — изменений нет"; exit 0
  fi
  if [[ $DRY -eq 1 ]]; then log "Dry-run: изменений к применению — $CHANGES. Ничего не изменено."; exit 0; fi
  log "Готово: изменений — $CHANGES. Бэкап и список изменений: $BK"
}
