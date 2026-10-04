# Build lr_jtagd.exe (FT2232H MPSSE JTAG daemon) with the MinGW-w64 gcc
# bundled with Vitis HLS 2021.1.  ftd2xx.dll is loaded at run time, so no
# FTDI SDK is needed to build.
param(
    [string]$Gcc = 'D:\Xilinx\Vitis_HLS\2021.1\tps\win64\msys64\mingw64\bin\gcc.exe'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$env:PATH = (Split-Path -Parent $Gcc) + ';' + $env:PATH
& $Gcc -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter lr_jtagd.c -o lr_jtagd.exe -lws2_32
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
Write-Output "BUILD_OK $here\lr_jtagd.exe"
