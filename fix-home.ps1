# Делает лаунчер главным экраном, если после install.ps1 остался прежний. Показывает, что на телевизоре.
#   irm https://raw.githubusercontent.com/Mag1c3R/tv-setup/main/fix-home.ps1 | iex
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Launcher = 'com.gathin.tvhome'
$Home_    = "$Launcher/.MainActivity"
$HomeQ    = 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME'

$Work = Join-Path $env:TEMP ("tv-fix-" + [guid]::NewGuid())
New-Item -ItemType Directory $Work | Out-Null
try {
  Write-Host 'Скачиваю adb…'
  try {
    Invoke-WebRequest 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile "$Work\pt.zip" -UseBasicParsing -ErrorAction Stop
    Expand-Archive "$Work\pt.zip" $Work -Force -ErrorAction Stop
  } catch { Write-Host "Не удалось скачать adb: $($_.Exception.Message)" -ForegroundColor Red; return }
  $Adb = "$Work\platform-tools\adb.exe"
  & $Adb start-server 2>&1 | Out-Null

  $Ip = (Read-Host 'IP-адрес телевизора').Trim()
  if ($Ip -notmatch ':') { $Ip = "${Ip}:5555" }
  Write-Host 'Подключаюсь. Если на телевизоре «Разрешить отладку?» — нажмите «Разрешить».'
  $state = ''
  for ($i = 0; $i -lt 30; $i++) {
    & $Adb connect $Ip 2>&1 | Out-Null
    $state = (& $Adb -s $Ip get-state 2>$null) -join ''
    if ($state -eq 'device') { break }
    Start-Sleep 2
  }
  if ($state -ne 'device') { Write-Host 'Телевизор не отвечает: включите снова «Отладку по сети» (Настройки → Для разработчиков).' -ForegroundColor Red; return }
  function S { ((& $Adb -s $Ip shell @args 2>&1) -join "`n").Replace("`r", '') }

  Write-Host "`n--- Что на телевизоре ---"
  Write-Host ("Модель: " + (S getprop ro.product.model) + ", Android " + (S getprop ro.build.version.release))
  Write-Host ("Лаунчер установлен: " + (S pm list packages $Launcher))
  Write-Host ("Главный экран сейчас: " + (S $HomeQ).Split("`n")[-1])
  Write-Host ("Роль HOME: " + (S cmd role get-role-holders android.app.role.HOME))
  Write-Host "Кто может быть главным экраном:"
  Write-Host (S cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME)

  if (-not (S pm list packages $Launcher)) { Write-Host "`nЛаунчер не установлен: запустите install.ps1 ещё раз." -ForegroundColor Red; return }

  Write-Host "`n--- Делаю лаунчер главным экраном ---"
  Write-Host (S cmd role add-role-holder android.app.role.HOME $Launcher)
  Write-Host (S cmd package set-home-activity --user 0 $Home_)
  S am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
  Start-Sleep 3
  $now = (S $HomeQ).Split("`n")[-1]
  if ($now -like "$Launcher/*") { Write-Host "`nГотово: лаунчер — главный экран. Нажмите «Домой» на пульте." -ForegroundColor Green }
  else {
    Write-Host "`nТелевизор оставил главным экраном $now." -ForegroundColor Yellow
    if ($now -match 'cvte') {
      Write-Host 'Стандартный экран этой платы отключать нельзя. Нажмите «Домой» на пульте и выберите лаунчер, «Всегда».'
    } else {
      $yn = Read-Host "Отключить стандартный главный экран ($($now.Split('/')[0]))? Вернуть: Настройки → Приложения. [y/N]"
      if ($yn -match '^(y|д)$') {
        Write-Host (S pm disable-user --user 0 $now.Split('/')[0])
        S cmd package set-home-activity --user 0 $Home_ | Out-Null
        S am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
        Start-Sleep 3
        Write-Host ("Главный экран теперь: " + (S $HomeQ).Split("`n")[-1])
      }
    }
  }
  $yn = Read-Host "`nВыключить отладку на телевизоре? [Y/n]"
  if ($yn -notmatch '^(n|н)$') { S settings put global adb_enabled 0 | Out-Null; Write-Host 'Отладка выключена.' }
} finally {
  if ($Adb -and (Test-Path $Adb)) { & $Adb kill-server 2>&1 | Out-Null }
  Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
