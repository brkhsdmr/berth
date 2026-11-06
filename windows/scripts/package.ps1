# Dağıtım paketleri: Inno Setup kurulumu (doğrudan dağıtım) ve MSIX (Microsoft Store).
#   windows\scripts\package.ps1 [-Version 1.0.0] [-StoreName X.Y] [-StorePublisher "CN=..."]
# Önce build.ps1 Release çalışmış olmalı.
# Store'a gitmeden yerelde denemek (Geliştirici modu açık olmalı; imza gerekmez):
#   Add-AppxPackage -Register windows\build\msix\AppxManifest.xml
# İmzasız .msix kurulamaz: tam güvenli (full trust) uygulamalarda Windows imza şartı koyuyor.
param([string]$Version = '1.0.0', [string]$StoreName = 'BurakHasdemir.Berth', [string]$StorePublisher = 'CN=BurakHasdemir')
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build\Release'
$dist = Join-Path $root 'build\dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# 1) Kurulum dosyası
$iscc = Get-ChildItem "${env:ProgramFiles(x86)}\Inno Setup*","$env:ProgramFiles\Inno Setup*","$env:LOCALAPPDATA\Programs\Inno Setup*" -Filter ISCC.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($iscc) {
  & $iscc.FullName /Q "/DAppVersion=$Version" (Join-Path $root 'packaging\Berth.iss')
  "kurulum=$LASTEXITCODE"
} else { "Inno Setup bulunamadi; kurulum dosyasi atlandi." }

# 2) MSIX
$makeappx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'x64' } | Select-Object -Last 1
if ($makeappx) {
  $stage = Join-Path $root 'build\msix'
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path "$stage\assets" | Out-Null
  Copy-Item "$build\Berth.exe" $stage
  Copy-Item "$build\assets\*.png" "$stage\assets"
  $v = (($Version.Split('.') + @('0','0','0','0'))[0..3]) -join '.'
  (Get-Content (Join-Path $root 'packaging\msix\AppxManifest.xml') -Raw -Encoding UTF8).Replace('__NAME__', $StoreName).Replace('__PUBLISHER__', $StorePublisher).Replace('__VERSION__', $v) |
    Set-Content "$stage\AppxManifest.xml" -Encoding UTF8
  & $makeappx.FullName pack /o /d $stage /p (Join-Path $dist "Berth-$Version.msix") | Select-String 'succeeded|error' | ForEach-Object { $_.Line }
} else { "makeappx bulunamadi; MSIX atlandi." }
Get-ChildItem $dist | ForEach-Object { "$($_.Name) $([math]::Round($_.Length/1KB)) KB" }
