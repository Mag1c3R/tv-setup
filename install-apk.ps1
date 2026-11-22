# Ставит на телевизор приложение по ссылке на APK (или из файла на ноутбуке).
#   irm https://raw.githubusercontent.com/Mag1c3R/tv-setup/main/install-apk.ps1 | iex
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Work = Join-Path $env:TEMP ("tv-apk-" + [guid]::NewGuid())
New-Item -ItemType Directory $Work | Out-Null
try {
  Write-Host 'Скачиваю adb (официальный, с dl.google.com)…'
  try {
    Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile "$Work\pt.zip" -UseBasicParsing -ErrorAction Stop
    Expand-Archive "$Work\pt.zip" $Work -Force -ErrorAction Stop
  } catch { Write-Host "Не удалось скачать adb: $($_.Exception.Message)" -ForegroundColor Red; return }
  $Adb = "$Work\platform-tools\adb.exe"
  & $Adb start-server 2>&1 | Out-Null

  $Ip = (Read-Host 'IP-адрес телевизора').Trim()
  if (-not $Ip) { return }
  if ($Ip -notmatch ':') { $Ip = "${Ip}:5555" }
  Write-Host 'Подключаюсь. Если на телевизоре «Разрешить отладку?» — нажмите «Разрешить».'
  $state = ''
  for ($i = 0; $i -lt 30; $i++) {
    & $Adb connect $Ip 2>&1 | Out-Null
    $state = (& $Adb -s $Ip get-state 2>$null) -join ''
    if ($state -eq 'device') { break }
    Start-Sleep 2
  }
  if ($state -ne 'device') { Write-Host 'Телевизор не отвечает: включите «Отладку по сети» (Настройки → Для разработчиков).' -ForegroundColor Red; return }

  while ($true) {
    $src = (Read-Host "`nСсылка на APK или путь к файлу (Enter — закончить)").Trim().Trim('"')
    if (-not $src) { break }
    $apk = "$Work\app.apk"
    if (Test-Path $src) { Copy-Item $src $apk -Force }
    else {
      Write-Host 'Скачиваю…'
      try { Invoke-WebRequest $src -OutFile $apk -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop }
      catch { Write-Host "Не удалось скачать: $($_.Exception.Message)" -ForegroundColor Red; continue }
    }
    $bytes = [IO.File]::ReadAllBytes($apk)
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
      Write-Host 'Это не APK (по ссылке пришла страница, а не файл). Нужна прямая ссылка на .apk.' -ForegroundColor Red; continue
    }
    $hash = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
    Write-Host ("Файл: {0:N1} МБ, SHA-256 {1}" -f ($bytes.Length / 1MB), $hash)
    Write-Host 'Устанавливаю…'
    $out = ((& $Adb -s $Ip install -r $apk 2>&1) | Select-Object -Last 1).ToString().Trim()
    if ($out -like 'Success*') { Write-Host 'Установлено.' -ForegroundColor Green }
    elseif ($out -match 'NO_MATCHING_ABIS') { Write-Host 'Не подходит процессору телевизора: нужна сборка armeabi-v7a (или universal).' -ForegroundColor Red }
    elseif ($out -match 'UPDATE_INCOMPATIBLE') { Write-Host 'Уже стоит эта программа с другой подписью: удалите её на телевизоре и повторите.' -ForegroundColor Red }
    else { Write-Host "Не установилось: $out" -ForegroundColor Red }
    Remove-Item $apk -Force -ErrorAction SilentlyContinue
  }

  $yn = Read-Host 'Выключить отладку на телевизоре? [Y/n]'
  if ($yn -notmatch '^(n|н)$') { & $Adb -s $Ip shell settings put global adb_enabled 0 2>&1 | Out-Null; Write-Host 'Отладка выключена.' }
  & $Adb disconnect $Ip 2>&1 | Out-Null
} finally {
  if ($Adb -and (Test-Path $Adb)) { & $Adb kill-server 2>&1 | Out-Null }
  Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
