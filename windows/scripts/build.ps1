# Windows'ta derler: windows\scripts\build.ps1 [Release|Debug] [-Version 1.0.0]
# Gerekli: Visual Studio 2022 ya da sonrası, "Desktop development with C++" iş yükü (Build Tools yeterli).
# İki geçiş: önce uygulama derlenir ve kendi simge dosyalarını yazar (--write-icons), sonra simge ve
# sürüm bilgisi gömülerek yeniden bağlanır. Simge kodla çizildiği için ayrı bir görsel dosya yok.
param([string]$Config = 'Release', [string]$Version = '1.0.0')
$root = Split-Path -Parent $PSScriptRoot
# Visual Studio, Microsoft'un vswhere aracıyla bulunur: sürüm ve kurulum yeri değişebilir.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "C++ araçları kurulu bir Visual Studio bulunamadı." }
$vc = '"' + (Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat') + '"'
$out = Join-Path $root "build\$Config"
$assets = Join-Path $out 'assets'
New-Item -ItemType Directory -Force -Path $out, $assets | Out-Null
$opt = if ($Config -eq 'Release') { '/O2 /GL /MT' } else { '/Od /Zi /MTd /DDEBUG' }
$link = if ($Config -eq 'Release') { '/LTCG /OPT:REF /OPT:ICF' } else { '/DEBUG' }
$src = "src\core\layout.cpp src\app\vdesktop.cpp src\app\source.cpp src\app\taskbar.cpp src\app\settings.cpp src\app\icon.cpp src\app\layouts.cpp src\app\remote.cpp src\app\text.cpp src\app\main.cpp"
$exe = Join-Path $out 'Berth.exe'
Push-Location $root
try {
  cmd /c "$vc >nul && cl /nologo /EHsc /std:c++20 /utf-8 /W3 /DUNICODE /D_UNICODE $opt $src /Fo$out\ /Fe$exe /link /SUBSYSTEM:WINDOWS /MANIFEST:EMBED /MANIFESTINPUT:packaging\app.manifest $link 2>&1"
  "derleme=$LASTEXITCODE"

  # Simge ve sürüm bilgisi
  $p = Start-Process -FilePath $exe -ArgumentList "--write-icons `"$assets`"" -Wait -PassThru
  if ($p.ExitCode -eq 0 -and (Test-Path "$assets\app.ico")) {
    $v = ($Version.Split('.') + @('0','0','0','0'))[0..3] -join ','
    $rc = @"
1 ICON "$($assets -replace '\\','\\')\\app.ico"
1 VERSIONINFO
FILEVERSION $v
PRODUCTVERSION $v
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "041F04B0"
    BEGIN
      VALUE "CompanyName", "Burak Hasdemir"
      VALUE "FileDescription", "Berth"
      VALUE "FileVersion", "$Version"
      VALUE "ProductName", "Berth"
      VALUE "ProductVersion", "$Version"
      VALUE "OriginalFilename", "Berth.exe"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x41F, 1200
  END
END
"@
    Set-Content -Path "$out\app.rc" -Value $rc -Encoding Unicode
    cmd /c "$vc >nul && rc /nologo /fo $out\app.res $out\app.rc 2>&1"
    cmd /c "$vc >nul && cl /nologo /EHsc /std:c++20 /utf-8 /W3 /DUNICODE /D_UNICODE $opt $src $out\app.res /Fo$out\ /Fe$exe /link /SUBSYSTEM:WINDOWS /MANIFEST:EMBED /MANIFESTINPUT:packaging\app.manifest $link 2>&1" | Out-Null
    "simge=$LASTEXITCODE"
  } else {
    "simge yazilamadi"
  }

  cmd /c "$vc >nul && cl /nologo /EHsc /std:c++20 /utf-8 /W3 $opt tests\core_tests.cpp src\core\layout.cpp /Fo$out\ /Fe$out\core_tests.exe 2>&1" | Out-Null
  & "$out\core_tests.exe"
} finally { Pop-Location }
if (Test-Path $exe) { "boyut=$([math]::Round((Get-Item $exe).Length/1KB)) KB" }
