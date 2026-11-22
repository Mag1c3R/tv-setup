# Настройка Android TV по сети: быстрый лаунчер, Happ, AirPlay для iPhone.
# Запуск на Windows (PowerShell):
#   irm https://raw.githubusercontent.com/Mag1c3R/tv-setup/main/install.ps1 | iex
# Windows PowerShell 5.1: с 'Stop' любая строка adb в stderr ("daemon not running; starting now") обрывает скрипт.
# Ошибки ловятся явно: -ErrorAction Stop у загрузок и Fail у проверок.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# PowerShell 5.1 по умолчанию может предлагать TLS 1.0, а GitHub и Google принимают только 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo      = 'Mag1c3R/tv-setup'
$Launcher  = 'com.gathin.tvhome'
$AirPlay   = 'io.github.jqssun.airplay'
$AutoClose = 'local.airplay.autoclose'

function Say($t)  { Write-Host "`n$t" -ForegroundColor White }
function Fail($t) { Write-Host "`nОшибка: $t" -ForegroundColor Red; throw $t }

$Work = Join-Path $env:TEMP ("tv-setup-" + [guid]::NewGuid())
New-Item -ItemType Directory $Work | Out-Null
try {

# --- adb от Google ---------------------------------------------------------
Say 'Скачиваю adb (официальный, с dl.google.com)…'
try {
  Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile "$Work\pt.zip" -UseBasicParsing -ErrorAction Stop
  Expand-Archive "$Work\pt.zip" $Work -Force -ErrorAction Stop
} catch { Fail "не удалось скачать adb: $($_.Exception.Message)" }
$Adb = "$Work\platform-tools\adb.exe"
& $Adb start-server 2>&1 | Out-Null

# --- подключение -----------------------------------------------------------
$Ip = (Read-Host 'IP-адрес телевизора (Настройки → Сеть)').Trim()
if (-not $Ip) { Fail 'адрес не введён' }
if ($Ip -notmatch ':') { $Ip = "${Ip}:5555" }
Say "Подключаюсь к $Ip. Если на экране телевизора появится «Разрешить отладку?» — нажмите «Разрешить»."
$state = ''
for ($i = 0; $i -lt 30; $i++) {
  & $Adb connect $Ip 2>&1 | Out-Null
  $state = (& $Adb -s $Ip get-state 2>$null) -join ''
  if ($state -eq 'device') { break }
  Start-Sleep 2
}
if ($state -ne 'device') { Fail 'телевизор не отвечает. Проверьте: включена «Отладка по сети» (Настройки → Для разработчиков), ноутбук в той же сети, нажато «Разрешить».' }
function A { & $Adb -s $Ip @args }
function S { ((& $Adb -s $Ip shell @args) -join "`n").Replace("`r", '') }

$Model = S getprop ro.product.model
$Sdk   = [int](S getprop ro.build.version.sdk)
$Rel   = S getprop ro.build.version.release
Say "Телевизор: $Model, Android $Rel"
if ($Sdk -lt 26) { Fail 'нужен Android 8 или новее' }

# --- бэкап -----------------------------------------------------------------
$Bk = Join-Path $HOME ('tv-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory $Bk | Out-Null
S pm list packages -f | Set-Content "$Bk\packages.txt" -Encoding UTF8
S pm list packages -d | Set-Content "$Bk\disabled.txt" -Encoding UTF8
foreach ($n in 'global','secure','system') { S settings list $n | Set-Content "$Bk\settings-$n.txt" -Encoding UTF8 }
S cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | Set-Content "$Bk\home.txt" -Encoding UTF8
Say "Бэкап списка приложений и настроек: $Bk"

# --- город для неба --------------------------------------------------------
$Lat = $null; $Lon = $null
$City = (Read-Host 'Город для фона-неба (Enter — пропустить)').Trim()
if ($City) {
  try {
    $g = Invoke-RestMethod ('https://geocoding-api.open-meteo.com/v1/search?count=1&language=ru&format=json&name=' + [uri]::EscapeDataString($City)) -UseBasicParsing -ErrorAction Stop
    if ($g.results) {
      $Lat = $g.results[0].latitude; $Lon = $g.results[0].longitude
      Write-Host "Нашёл: $City ($($g.results[0].admin1)), $Lat, $Lon"
    } else { Write-Host 'Город не найден, небо будет без привязки к городу.' }
  } catch { Write-Host 'Не удалось найти город, небо будет без привязки к городу.' }
}

# --- скачивание с проверкой sha256 -----------------------------------------
function Fetch($repo, $name, $file) {
  try { $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing -ErrorAction Stop }
  catch { Fail "нет доступа к GitHub ($repo): $($_.Exception.Message)" }
  $a = $rel.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $a) { Fail "в выпуске $repo нет файла $name" }
  try { Invoke-WebRequest $a.browser_download_url -OutFile $file -UseBasicParsing -ErrorAction Stop }
  catch { Fail "не удалось скачать ${name}: $($_.Exception.Message)" }
  if ($a.digest -match '^sha256:([0-9a-f]+)$') {
    if ((Get-FileHash $file -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]) { Fail "контрольная сумма $name не совпала: файл повреждён или подменён" }
    Write-Host "  $name — контрольная сумма совпала"
  } else { Write-Host "  $name — GitHub не дал контрольную сумму, проверка пропущена" }
}
Say 'Скачиваю приложения…'
Fetch $Repo 'launcher.apk' "$Work\launcher.apk"
Fetch $Repo 'airplay-autoclose.apk' "$Work\autoclose.apk"
Fetch 'Happ-proxy/happ-android' 'Happ.apk' "$Work\happ.apk"
Fetch 'jqssun/android-airplay-server' 'app-release.apk' "$Work\airplay.apk"

# --- установка -------------------------------------------------------------
Say 'Устанавливаю (может занять пару минут)…'
foreach ($f in 'launcher','happ','airplay','autoclose') {
  $out = ((A install -r "$Work\$f.apk" 2>&1) | Select-Object -Last 1).ToString().Trim()
  Write-Host "  $f… $out"
  if ($out -notlike 'Success*') { Fail "не установилось: $f ($out)" }
}

# Лаунчер — главным экраном. Стандартный не отключается.
S pm grant $Launcher android.permission.ACCESS_FINE_LOCATION 2>$null | Out-Null
S cmd role add-role-holder android.app.role.HOME $Launcher 2>$null | Out-Null
S cmd package set-home-activity --user 0 "$Launcher/.MainActivity" 2>$null | Out-Null

# Город — в config.json лаунчера.
if ($Lat) {
  $json = '{"latitude": ' + $Lat.ToString([Globalization.CultureInfo]::InvariantCulture) + ', "longitude": ' + $Lon.ToString([Globalization.CultureInfo]::InvariantCulture) + '}'
  [IO.File]::WriteAllText("$Work\config.json", $json, (New-Object Text.UTF8Encoding $false))
  A push "$Work\config.json" /data/local/tmp/tvsetup-config.json | Out-Null
  S "o=`$(content write --uri content://$Launcher.theme/config.json < /data/local/tmp/tvsetup-config.json 2>&1); case `"`$o`" in *rror*|*nsupported*) mkdir -p /sdcard/Android/data/$Launcher/files; cp /data/local/tmp/tvsetup-config.json /sdcard/Android/data/$Launcher/files/config.json;; esac; rm -f /data/local/tmp/tvsetup-config.json" | Out-Null
}

# AirPlay: показ поверх приложений, первый запуск, помощник автозакрытия.
S appops set $AirPlay SYSTEM_ALERT_WINDOW allow | Out-Null
S monkey -p $AirPlay -c android.intent.category.LEANBACK_LAUNCHER 1 2>$null | Out-Null
Start-Sleep 4
$cur = S settings get secure enabled_accessibility_services
$svc = "$AutoClose/$AutoClose.AutoCloseService"
if ($cur -notlike "*$svc*") {
  if (-not $cur -or $cur -eq 'null') { S settings put secure enabled_accessibility_services $svc | Out-Null }
  else { S settings put secure enabled_accessibility_services "${cur}:$svc" | Out-Null }
}
S settings put secure accessibility_enabled 1 | Out-Null

# Анимации системы вдвое короче.
foreach ($k in 'window_animation_scale','transition_animation_scale','animator_duration_scale') { S settings put global $k 0.5 | Out-Null }

# --- по желанию: ассистент и Chromecast ------------------------------------
$yn = Read-Host 'Отключить голосового ассистента Google и Chromecast? Кнопка микрофона на пульте перестанет работать. [y/N]'
if ($yn -match '^(y|д)$') {
  foreach ($p in 'com.google.android.katniss','com.google.android.apps.mediashell') {
    S pm disable-user --user 0 $p 2>$null | Out-Null; Write-Host "  отключено: $p"
  }
  Write-Host '  Вернуть: Настройки → Приложения → Показать системные → включить.'
}

# Перезапуск главного экрана.
S am force-stop $Launcher | Out-Null
S am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>$null | Out-Null
Start-Sleep 3
$homeNow = (S cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME).Split("`n")[-1]
if ($homeNow -like "$Launcher/*") { Say 'Готово: новый лаунчер — главный экран.' }
else { Say "Готово, но главным экраном пока остался $homeNow. Нажмите «Домой» на пульте и выберите «Home» / Clean Your TV, «Всегда»." }
Write-Host '  • Кнопка VPN сверху открывает Happ — добавьте в нём свою подписку.'
Write-Host '  • AirPlay: на iPhone «Повтор экрана» → «Android AirPlay».'
Write-Host "  • Бэкап: $Bk"

# --- закрыть отладку -------------------------------------------------------
$yn = Read-Host 'Выключить отладку на телевизоре (рекомендуется)? [Y/n]'
if ($yn -match '^(n|н)$') { Write-Host 'Отладка оставлена включённой. Выключить: Настройки → Для разработчиков.' }
else { S settings put global adb_enabled 0 2>$null | Out-Null; Write-Host 'Отладка выключена.' }
& $Adb disconnect $Ip 2>$null | Out-Null

} finally {
  if ($Adb -and (Test-Path $Adb)) { & $Adb kill-server 2>&1 | Out-Null }
  Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
