# Build the Lightning Receiver FM installer:
#   1) flutter build windows --release
#   2) Inno Setup -> installer\Output\LR_Radio_Setup_<ver>.exe
param(
    [string]$Flutter = 'D:\tools\flutter\bin\flutter.bat',
    [string]$Iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Split-Path -Parent $here

# Always rebuild the bundled host tools so the installer never ships a stale exe
# (1.1.0 shipped an ad9361_jtag.exe that predated design ID 0x4C520004).
foreach ($b in @("$app\..\..\tools\hw\ad9361_jtag\build.ps1",
                 "$app\..\..\tools\hw\lr_jtagd\build.ps1")) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $b
    if ($LASTEXITCODE -ne 0) { throw "tool build failed: $b" }
}

Push-Location $app
try {
    & $Flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }
} finally { Pop-Location }

foreach ($f in @("$app\..\..\tools\hw\lr_jtagd\lr_jtagd.exe",
                 "$app\..\..\tools\hw\lr_jtag_bridge.tcl",
                 "$app\..\..\tools\hw\ad9361_jtag\ad9361_jtag.exe")) {
    if (-not (Test-Path $f)) { throw "missing bundled resource: $f" }
}

& $Iscc "$here\lr_radio.iss"
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
Get-ChildItem "$here\Output\*.exe" | ForEach-Object { "INSTALLER_OK $($_.FullName) ($([math]::Round($_.Length / 1MB, 1)) MB)" }
