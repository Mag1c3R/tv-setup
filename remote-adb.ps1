# Удалённая настройка телевизора одной командой: ноутбук рядом с телевизором ставит Tailscale, входит по
# одноразовому ключу (его присылает настраивающий) и пересылает к телевизору подключения только из его сети
# Tailscale. Enter в конце всё убирает: пересылку, правило брандмауэра и вход в Tailscale.
# PowerShell от имени администратора:
#   irm https://raw.githubusercontent.com/Mag1c3R/tv-setup/main/remote-adb.ps1 | iex
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Port = 15555
$Rule = 'tv-setup remote adb'
$ts   = 'C:\Program Files\Tailscale\tailscale.exe'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Write-Host 'Нужен PowerShell от имени администратора: Пуск → PowerShell → правой кнопкой → «Запуск от имени администратора».' -ForegroundColor Red
  return
}

# --- Tailscale -------------------------------------------------------------
$installedHere = $false
if (-not (Test-Path $ts)) {
  Write-Host 'Ставлю Tailscale (официальный установщик с pkgs.tailscale.com)…'
  $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
  try { Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi -UseBasicParsing -ErrorAction Stop }
  catch { Write-Host "Не удалось скачать Tailscale: $($_.Exception.Message)" -ForegroundColor Red; return }
  $sig = Get-AuthenticodeSignature $msi
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Tailscale') {
    Write-Host "Подпись установщика Tailscale не прошла проверку ($($sig.Status)). Остановлено." -ForegroundColor Red
    Remove-Item $msi -Force -ErrorAction SilentlyContinue; return
  }
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart TS_NOLAUNCH=1" -Wait
  Remove-Item $msi -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 30 -and -not (Test-Path $ts); $i++) { Start-Sleep 1 }
  if (-not (Test-Path $ts)) { Write-Host 'Tailscale не установился.' -ForegroundColor Red; return }
  $installedHere = $true
  Start-Sleep 5
}
$tsIp = ((& $ts ip -4 2>$null) -join '').Trim()
$joinedHere = $false
if (-not $tsIp) {
  $key = (Read-Host 'Ключ Tailscale (начинается с tskey-, его пришлёт настраивающий)').Trim()
  if ($key -notlike 'tskey-*') { Write-Host 'Это не ключ Tailscale.' -ForegroundColor Red; return }
  & $ts up --authkey=$key --hostname=tv-helper --unattended 2>&1 | Out-Host
  for ($i = 0; $i -lt 20 -and -not $tsIp; $i++) { Start-Sleep 1; $tsIp = ((& $ts ip -4 2>$null) -join '').Trim() }
  if (-not $tsIp) { Write-Host 'Не удалось войти в Tailscale: ключ неверный или уже использован.' -ForegroundColor Red; return }
  $joinedHere = $true
}

# --- телевизор -------------------------------------------------------------
$Ip = (Read-Host 'IP-адрес телевизора').Trim()
if (-not $Ip) { return }
$tv = Test-NetConnection $Ip -Port 5555 -WarningAction SilentlyContinue
if (-not $tv.TcpTestSucceeded) {
  Write-Host "Телевизор $Ip не отвечает на порту 5555: включите «Отладку по сети» (Настройки → Для разработчиков) и запустите команду снова." -ForegroundColor Red
  return
}

Start-Service iphlpsvc -ErrorAction SilentlyContinue
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=$tsIp 2>&1 | Out-Null
netsh interface portproxy add v4tov4 listenport=$Port listenaddress=$tsIp connectport=5555 connectaddress=$Ip | Out-Null
Remove-NetFirewallRule -DisplayName $Rule -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $Rule -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null

Write-Host "`nГотово. Сообщите настраивающему: $tsIp`:$Port" -ForegroundColor Green
Write-Host 'Когда на телевизоре появится «Разрешить отладку?» — нажмите «Разрешить».'
Write-Host 'Не закрывайте это окно, пока идёт настройка.'
Read-Host "`nКогда настройка закончится, нажмите Enter — всё уберётся" | Out-Null

netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=$tsIp 2>&1 | Out-Null
Remove-NetFirewallRule -DisplayName $Rule -ErrorAction SilentlyContinue
if ($joinedHere) { & $ts logout 2>&1 | Out-Null }
if ($installedHere) {
  $yn = Read-Host 'Удалить Tailscale с этого ноутбука? [Y/n]'
  if ($yn -notmatch '^(n|н)$') {
    $p = Get-Package -Name 'Tailscale*' -ErrorAction SilentlyContinue
    if ($p) { $p | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null }
  }
}
Write-Host 'Готово: пересылка удалена, ноутбук отключён от сети Tailscale.'
