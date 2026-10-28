<#
  Windows kurulumunu uçtan uca sınar (Yönetici PowerShell):
    powershell -ExecutionPolicy Bypass -File tests\windows-admin-test.ps1 -Link 'vless://…'
  Kurar → görevleri ve tüneli denetler → xray'i öldürüp görevin yeniden
  başlattığını doğrular → kaldırır.
#>
param([Parameter(Mandatory)] [string]$Link, [string]$Name = 'hetest-win')
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '..\client\install.ps1'
$port = [int]([regex]::Match($Link, '@[^:]+:(\d+)').Groups[1].Value)
function Tunnel { @(Get-NetTCPConnection -State Established -RemotePort $port -ErrorAction SilentlyContinue).Count -gt 0 }
function Line($k, $v) { '{0,-28} {1}' -f $k, $v }

& $installer -Link $Link -Name $Name
Line 'görev durumu' (Get-ScheduledTask -TaskName "xray-$Name").State
Line 'bekçi görevi' (Get-ScheduledTask -TaskName "xray-$Name-watchdog").State
Line 'xray süreci (SYSTEM)' ((Get-Process xray | Where-Object Path -like "*\$Name\*" | Select-Object -First 1).Id)
Line 'tünel' (Tunnel)
Line 'config okunabilir (kullanıcı)' ((icacls "$env:ProgramData\$Name\config.json") -join ' ' -match 'Users')

Get-Process xray | Where-Object Path -like "*\$Name\*" | Stop-Process -Force
Line 'xray öldürüldü, tünel' (Tunnel)
$t0 = Get-Date
while (-not (Tunnel) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep 2 }
Line 'yeniden bağlandı mı' ("{0} ({1:N0} sn)" -f (Tunnel), ((Get-Date) - $t0).TotalSeconds)

& $installer -Name $Name -Uninstall
Line 'kaldırma sonrası görev' ([bool](Get-ScheduledTask -TaskName "xray-$Name" -ErrorAction SilentlyContinue))
Line 'kaldırma sonrası klasör' (Test-Path "$env:ProgramData\$Name")
