# Derlenmiş uygulamayı kullanıcının Programlar klasörüne kurar, Başlat menüsüne kısayol ekler.
param([string]$Config = 'Release')
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'Programs\Berth'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Get-Process Berth -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400
Copy-Item (Join-Path $root "build\$Config\Berth.exe") $target -Force
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Berth.lnk'
$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($lnk)
$s.TargetPath = Join-Path $target 'Berth.exe'
$s.Description = 'Berth'
$s.Save()
"kuruldu: $target"
