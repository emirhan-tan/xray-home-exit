<#
  xray-home-exit - Windows ev cihazı kurulumu (Windows 10/11, x64 / ARM64 / x86)

  Yönetici PowerShell'de:
    & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData('https://raw.githubusercontent.com/emirhan-tan/xray-home-exit/main/client/install.ps1')))) -Link 'vless://...'
  Kaldırma:
    & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString((New-Object Net.WebClient).DownloadData('https://raw.githubusercontent.com/emirhan-tan/xray-home-exit/main/client/install.ps1')))) -Uninstall

  Xray, açılışta SYSTEM hesabıyla başlayan bir zamanlanmış görev olarak çalışır;
  çökerse yeniden başlatılır, ayrıca 2 dakikada bir bağlantı kontrol edilir.
#>
param(
    [string]$Link,
    [string]$Name = 'home-exit',
    [switch]$AllowLan,
    [switch]$IPv6,        # IPv6 çıkışını aç (linkte ipv6=1 varsa otomatik)
    [switch]$NoIPv6,
    [string]$XrayVersion = 'latest',
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$NoService    # görev kurma (test için; yönetici gerekmez)
)
$ErrorActionPreference = 'Stop'
$HeVersion = '1.0.1'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ok($m)   { Write-Host "$([char]0x2714) $m" -ForegroundColor Green }
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "$([char]0x2718) $m" -ForegroundColor Red; exit 1 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoService) { Fail 'PowerShell''i "Yönetici olarak çalıştır" ile açın' }
if ($Name -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail '-Name yalnızca küçük harf, rakam ve - içerebilir' }

$Dir = Join-Path $env:ProgramData $Name
$Xray = Join-Path $Dir 'xray.exe'
$Conf = Join-Path $Dir 'config.json'
$Task = "xray-$Name"
$WatchTask = "xray-$Name-watchdog"

function Test-Tunnel([int]$Port) {
    @(Get-NetTCPConnection -State Established -RemotePort $Port -ErrorAction SilentlyContinue).Count -gt 0
}

if ($Uninstall) {
    foreach ($t in $Task, $WatchTask) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
        }
    }
    Get-Process xray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Xray } | Stop-Process -Force
    Start-Sleep 1
    if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
    Ok "'$Name' kaldırıldı"
    exit 0
}

if ($Status) {
    if (-not (Test-Path "$Dir\port.txt")) { Fail "'$Name' kurulu değil" }
    $p = [int](Get-Content "$Dir\port.txt")
    if (Test-Tunnel $p) { Ok "Tünel bağlı (port $p)" } else { Write-Host "! Tünel bağlı değil" -ForegroundColor Yellow }
    exit 0
}

# ------------------------------------------------------------------ link
if (-not $Link) { Fail "Bağlantı linki gerekli: -Link 'vless://...' (sunucuda: install.sh link)" }
if ($Link -notmatch '^vless://(?<uuid>[0-9a-fA-F-]{36})@(?<host>\[[^\]]+\]|[^:/?#]+):(?<port>\d+)/?(\?(?<q>[^#]*))?') { Fail 'Link çözülemedi' }
$Uuid = $Matches.uuid; $SrvHost = $Matches.host.Trim('[', ']'); $Port = [int]$Matches.port
$Q = @{}
foreach ($kv in ($Matches.q -split '&')) {
    if ($kv -match '^([^=]+)=(.*)$') { $Q[$Matches[1]] = [uri]::UnescapeDataString($Matches[2]) }
}
$Fp = if ($Q.fp) { $Q.fp } else { 'chrome' }
$UseV6 = ($IPv6 -or $Q.ipv6 -eq '1') -and -not $NoIPv6
switch ($Q.security) {
    'reality' {
        if (-not $Q.pbk -or -not $Q.sni) { Fail 'REALITY linkinde pbk/sni eksik' }
        $Sec = "`"security`": `"reality`", `"realitySettings`": {`"serverName`": `"$($Q.sni)`", `"fingerprint`": `"$Fp`", `"publicKey`": `"$($Q.pbk)`", `"shortId`": `"$($Q.sid)`"}"
    }
    'tls' {
        $sni = if ($Q.sni) { $Q.sni } else { $SrvHost }
        $Sec = "`"security`": `"tls`", `"tlsSettings`": {`"serverName`": `"$sni`", `"fingerprint`": `"$Fp`"}"
    }
    default { Fail "Desteklenmeyen güvenlik türü: '$($Q.security)'" }
}

# ------------------------------------------------------------------ xray
New-Item -ItemType Directory -Force $Dir | Out-Null
$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { '64' } 'ARM64' { 'arm64-v8a' } 'x86' { '32' } default { Fail "Desteklenmeyen mimari: $_" } }
$url = if ($XrayVersion -eq 'latest') { "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-$arch.zip" }
       else { "https://github.com/XTLS/Xray-core/releases/download/$XrayVersion/Xray-windows-$arch.zip" }

if (Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $Task }
Get-Process xray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Xray } | Stop-Process -Force
Info "xray-home-exit $HeVersion - Xray indiriliyor: $url"
$zip = Join-Path $env:TEMP "xray-$Name.zip"
$tmp = Join-Path $env:TEMP "xray-$Name"
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $tmp -Force
Copy-Item "$tmp\xray.exe" $Xray -Force
Remove-Item $zip, $tmp -Recurse -Force
Ok ((& $Xray version | Select-Object -First 1))

# ------------------------------------------------------------------ ayar
# engellenecek hedefler: IPv6 kapalıysa tamamı, açıksa yalnızca yerel IPv6 aralıkları
if ($UseV6) { $nets = '"224.0.0.0/3", "ff00::/8"'; $ds = 'UseIPv4v6' } else { $nets = '"224.0.0.0/3", "::/0"'; $ds = 'UseIPv4' }
if (-not $AllowLan) { $nets += ', "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"' }
$json = @"
{
  "log": { "loglevel": "warning", "access": "none" },
  "outbounds": [
    {
      "tag": "home-direct", "protocol": "freedom",
      "settings": { "finalRules": [ { "action": "block", "ip": [$nets], "blockDelay": "0" }, { "action": "allow" } ] },
      "streamSettings": { "sockopt": { "domainStrategy": "$ds", "tcpNoDelay": true, "tcpKeepAliveIdle": 30 } }
    },
    {
      "tag": "to-server", "protocol": "vless",
      "settings": { "address": "$SrvHost", "port": $Port, "id": "$Uuid", "encryption": "none", "reverse": { "tag": "bridge" } },
      "streamSettings": { "network": "tcp", $Sec,
        "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 30 } }
    },
    { "tag": "block", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["bridge"], "ip": [$nets], "outboundTag": "block" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "home-direct" }
    ]
  }
}
"@
[IO.File]::WriteAllText($Conf, $json, (New-Object Text.UTF8Encoding $false))
$test = & $Xray run -test -c $Conf 2>&1
if ($LASTEXITCODE -ne 0) { $test | Write-Host; Fail 'Oluşan ayar geçersiz' }
Set-Content -Path "$Dir\port.txt" -Value $Port -Encoding ascii
if ($NoService) { Ok "Dosyalar kuruldu (görev kurulmadı). Çalıştırmak için: & '$Xray' run -c '$Conf'"; exit 0 }
# yapılandırma UUID içerir: yalnızca SYSTEM ve Yöneticiler okuyabilsin
icacls $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

# ------------------------------------------------------------------ görevler
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
# Xray kapanırsa 5 sn içinde yeniden başlatan döngü
Set-Content -Path (Join-Path $Dir 'run.ps1') -Encoding UTF8 -Value "while (`$true) { & '$Xray' run -c '$Conf'; Start-Sleep 5 }"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Dir 'run.ps1')`"" -WorkingDirectory $Dir
Register-ScheduledTask -TaskName $Task -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal $principal -Settings $settings -Description 'xray-home-exit ev köprüsü' -Force | Out-Null

$watch = @"
`$miss = Join-Path '$Dir' 'miss.txt'
if (@(Get-NetTCPConnection -State Established -RemotePort $Port -ErrorAction SilentlyContinue).Count -gt 0) { Remove-Item `$miss -ErrorAction SilentlyContinue; exit }
`$n = 1 + [int](Get-Content `$miss -ErrorAction SilentlyContinue)
if (`$n -lt 2) { Set-Content `$miss `$n; exit }
Remove-Item `$miss -ErrorAction SilentlyContinue
`$p = Get-Process xray -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq '$Xray' }
if (`$p) { `$p | Stop-Process -Force } else { Start-ScheduledTask -TaskName '$Task' }
"@
Set-Content -Path "$Dir\watchdog.ps1" -Value $watch -Encoding UTF8
$wAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\watchdog.ps1`""
$wTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName $WatchTask -Action $wAction -Trigger $wTrigger -Principal $principal `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable) -Force | Out-Null

Start-ScheduledTask -TaskName $Task
Info "Sunucuya bağlanılıyor ($SrvHost`:$Port)"
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep 1
    if (Test-Tunnel $Port) { Ok 'Tünel kuruldu. Sunucuda kontrol: bash install.sh status'; exit 0 }
}
Fail "20 sn içinde bağlantı kurulamadı. Linki ve sunucunun $Port portunu kontrol edin"
