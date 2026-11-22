#!/usr/bin/env bash
# Настройка Android TV по сети: быстрый лаунчер, Happ, AirPlay для iPhone.
# Запуск на Mac или Linux (Терминал):
#   bash <(curl -fsSL https://raw.githubusercontent.com/Mag1c3R/tv-setup/main/install.sh)
set -euo pipefail

REPO="Mag1c3R/tv-setup"
LAUNCHER=com.gathin.tvhome
AIRPLAY=io.github.jqssun.airplay
AUTOCLOSE=local.airplay.autoclose
HAPP=su.happ.proxyutility

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local a=""; read -r -p "$1" a || true; printf '%s' "$a"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- adb от Google ---------------------------------------------------------
case "$(uname -s)" in
  Darwin) PT=darwin ;;
  Linux)  PT=linux ;;
  *) fail "этот скрипт для Mac и Linux. На Windows запустите install.ps1." ;;
esac
say "Скачиваю adb (официальный, с dl.google.com)…"
curl -fsSL -o "$WORK/pt.zip" "https://dl.google.com/android/repository/platform-tools-latest-$PT.zip"
unzip -q "$WORK/pt.zip" -d "$WORK"
ADB="$WORK/platform-tools/adb"
"$ADB" start-server >/dev/null 2>&1

# --- подключение -----------------------------------------------------------
IP=$(ask "IP-адрес телевизора (Настройки → Сеть): ")
IP=${IP// /}
[ -n "$IP" ] || fail "адрес не введён"
case "$IP" in *:*) ;; *) IP="$IP:5555" ;; esac
say "Подключаюсь к $IP. Если на экране телевизора появится «Разрешить отладку?» — нажмите «Разрешить»."
for i in $(seq 1 30); do
  "$ADB" connect "$IP" >/dev/null 2>&1 || true
  state=$("$ADB" -s "$IP" get-state 2>/dev/null || true)
  [ "$state" = device ] && break
  sleep 2
done
[ "${state:-}" = device ] || fail "телевизор не отвечает. Проверьте: включена «Отладка по сети» (Настройки → Для разработчиков), ноутбук в той же сети, нажато «Разрешить»."
A() { "$ADB" -s "$IP" "$@"; }
S() { "$ADB" -s "$IP" shell "$@" | tr -d '\r'; }

MODEL=$(S getprop ro.product.model)
SDK=$(S getprop ro.build.version.sdk)
REL=$(S getprop ro.build.version.release)
say "Телевизор: $MODEL, Android $REL"
[ "${SDK:-0}" -ge 26 ] || fail "нужен Android 8 или новее"

# --- бэкап -----------------------------------------------------------------
BK="$HOME/tv-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
S pm list packages -f > "$BK/packages.txt"
S pm list packages -d > "$BK/disabled.txt"
for n in global secure system; do S settings list "$n" > "$BK/settings-$n.txt"; done
S cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME > "$BK/home.txt"
say "Бэкап списка приложений и настроек: $BK"

# --- город для неба --------------------------------------------------------
LAT=""; LON=""
CITY=$(ask "Город для фона-неба (Enter — пропустить): ")
if [ -n "$CITY" ]; then
  Q=$(printf '%s' "$CITY" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')
  G=$(curl -fsSL "https://geocoding-api.open-meteo.com/v1/search?name=$Q&count=1&language=ru&format=json" || true)
  LAT=$(printf '%s' "$G" | grep -o '"latitude":[-0-9.]*' | head -1 | cut -d: -f2)
  LON=$(printf '%s' "$G" | grep -o '"longitude":[-0-9.]*' | head -1 | cut -d: -f2)
  NAME=$(printf '%s' "$G" | grep -o '"admin1":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$LAT" ]; then echo "Нашёл: $CITY ($NAME), $LAT, $LON"; else echo "Город не найден, небо будет без привязки к городу."; fi
fi

# --- скачивание с проверкой sha256 -----------------------------------------
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# fetch <owner/repo> <asset name> <file>: последний выпуск на GitHub, sha256 сверяется с GitHub.
fetch() {
  local api json url digest
  json=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest") || fail "нет доступа к GitHub ($1)"
  url=$(printf '%s\n' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*/$2\"" | head -1 | sed 's/.*"\(https[^"]*\)"$/\1/')
  digest=$(printf '%s\n' "$json" | awk -v n="\"$2\"" '/"name":/{cur=$0} /"digest":/{ if (index(cur, n)) { match($0, /sha256:[0-9a-f]+/); print substr($0, RSTART+7, RLENGTH-7); exit } }')
  [ -n "$url" ] || fail "в выпуске $1 нет файла $2"
  curl -fsSL -o "$3" "$url"
  if [ -n "$digest" ]; then
    [ "$(sha "$3")" = "$digest" ] || fail "контрольная сумма $2 не совпала: файл повреждён или подменён"
    echo "  $2 — контрольная сумма совпала"
  else
    echo "  $2 — GitHub не дал контрольную сумму, проверка пропущена"
  fi
}
say "Скачиваю приложения…"
fetch "$REPO" launcher.apk "$WORK/launcher.apk"
fetch "$REPO" airplay-autoclose.apk "$WORK/autoclose.apk"
fetch Happ-proxy/happ-android Happ.apk "$WORK/happ.apk"
fetch jqssun/android-airplay-server app-release.apk "$WORK/airplay.apk"

# --- установка -------------------------------------------------------------
say "Устанавливаю (может занять пару минут)…"
for f in launcher happ airplay autoclose; do
  printf '  %s… ' "$f"
  out=$(A install -r "$WORK/$f.apk" 2>&1 | tr -d '\r' | tail -1)
  echo "$out"
  case "$out" in Success*) ;; *) fail "не установилось: $f ($out)";; esac
done

# Лаунчер — главным экраном. Стандартный не отключается: вернуть его можно в Настройках → Приложения.
S pm grant $LAUNCHER android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
S cmd package set-home-activity --user 0 $LAUNCHER/.MainActivity >/dev/null 2>&1 || true

# Город — в config.json лаунчера.
if [ -n "$LAT" ]; then
  printf '{"latitude": %s, "longitude": %s}\n' "$LAT" "$LON" > "$WORK/config.json"
  A push "$WORK/config.json" /data/local/tmp/tvsetup-config.json >/dev/null
  S "o=\$(content write --uri content://$LAUNCHER.theme/config.json < /data/local/tmp/tvsetup-config.json 2>&1); case \"\$o\" in *rror*|*nsupported*) mkdir -p /sdcard/Android/data/$LAUNCHER/files; cp /data/local/tmp/tvsetup-config.json /sdcard/Android/data/$LAUNCHER/files/config.json;; esac; rm -f /data/local/tmp/tvsetup-config.json" >/dev/null 2>&1 || true
fi

# AirPlay: показ поверх приложений (сам выходит на экран при подключении iPhone), первый запуск — чтобы
# заработали автозапуск при включении и сервер. Помощник автозакрытия — служба спец. возможностей.
S appops set $AIRPLAY SYSTEM_ALERT_WINDOW allow
S monkey -p $AIRPLAY -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1 || true
sleep 4
CUR=$(S settings get secure enabled_accessibility_services)
SVC=$AUTOCLOSE/$AUTOCLOSE.AutoCloseService
case "$CUR" in
  *"$SVC"*) ;;
  ""|null) S settings put secure enabled_accessibility_services "$SVC" ;;
  *) S settings put secure enabled_accessibility_services "$CUR:$SVC" ;;
esac
S settings put secure accessibility_enabled 1

# Анимации системы вдвое короче.
for k in window_animation_scale transition_animation_scale animator_duration_scale; do S settings put global $k 0.5; done

# --- по желанию: ассистент и Chromecast ------------------------------------
YN=$(ask "Отключить голосового ассистента Google и Chromecast? Кнопка микрофона на пульте перестанет работать. [y/N]: ")
case "$YN" in
  y|Y|д|Д)
    for p in com.google.android.katniss com.google.android.apps.mediashell; do
      S pm disable-user --user 0 $p >/dev/null 2>&1 && echo "  отключено: $p" || true
    done
    echo "  Вернуть: Настройки → Приложения → Показать системные → включить." ;;
esac

# Перезапуск главного экрана.
S am force-stop $LAUNCHER
S am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1 || true
sleep 3
HOME_NOW=$(S cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)
case "$HOME_NOW" in
  $LAUNCHER/*) say "Готово: новый лаунчер — главный экран." ;;
  *) say "Готово, но главным экраном пока остался $HOME_NOW. Нажмите «Домой» на пульте и выберите «Home» / Clean Your TV, «Всегда»." ;;
esac
cat <<EOF
  • Кнопка VPN сверху открывает Happ — добавьте в нём свою подписку.
  • AirPlay: на iPhone «Повтор экрана» → «Android AirPlay».
  • Бэкап: $BK
EOF

# --- закрыть отладку -------------------------------------------------------
YN=$(ask "Выключить отладку на телевизоре (рекомендуется)? [Y/n]: ")
case "$YN" in
  n|N|н|Н) echo "Отладка оставлена включённой. Выключить: Настройки → Для разработчиков." ;;
  *) S settings put global adb_enabled 0 >/dev/null 2>&1 || true
     echo "Отладка выключена." ;;
esac
"$ADB" disconnect "$IP" >/dev/null 2>&1 || true
"$ADB" kill-server >/dev/null 2>&1 || true
