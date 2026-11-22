# Удалённая настройка телевизора: этот ноутбук пересылает подключение к телевизору через Tailscale.
# Нужно: Tailscale на ноутбуке, вход в тот же аккаунт, что у настраивающего. PowerShell от имени администратора:
#   irm https://raw.githubusercontent.com/Mag1c3R/tv-setup/main/remote-adb.ps1 | iex
# Пересылка открыта только для адресов Tailscale (100.64.0.0/10) и убирается, когда вы нажмёте Enter.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Port = 15555
$Rule = 'tv-setup remote adb'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Write-Host 'Нужен PowerShell от имени администратора: Пуск → PowerShell → правой кнопкой → «Запуск от имени администратора».' -ForegroundColor Red
  return
}
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) { Write-Host 'Tailscale не установлен: https://tailscale.com/download/windows' -ForegroundColor Red; return }
$tsIp = ((& $ts ip -4) -join '').Trim()
if (-not $tsIp) { Write-Host 'Tailscale не подключён: откройте его и войдите в аккаунт.' -ForegroundColor Red; return }

$Ip = (Read-Host 'IP-адрес телевизора').Trim()
if (-not $Ip) { return }
$tv = Test-NetConnection $Ip -Port 5555 -WarningAction SilentlyContinue
if (-not $tv.TcpTestSucceeded) {
  Write-Host "Телевизор $Ip не отвечает на порту 5555: включите «Отладку по сети» (Настройки → Для разработчиков)." -ForegroundColor Red
  return
}

netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=$tsIp 2>&1 | Out-Null
netsh interface portproxy add v4tov4 listenport=$Port listenaddress=$tsIp connectport=5555 connectaddress=$Ip | Out-Null
Remove-NetFirewallRule -DisplayName $Rule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $Rule -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null

Write-Host "`nГотово. Сообщите настраивающему: $tsIp`:$Port" -ForegroundColor Green
Write-Host 'Когда на телевизоре появится «Разрешить отладку?» — нажмите «Разрешить».'
Write-Host 'Не закрывайте это окно, пока идёт настройка.'
Read-Host "`nКогда настройка закончится, нажмите Enter — пересылка удалится" | Out-Null

netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=$tsIp 2>&1 | Out-Null
Remove-NetFirewallRule -DisplayName $Rule -ErrorAction SilentlyContinue
Write-Host 'Пересылка удалена.'
