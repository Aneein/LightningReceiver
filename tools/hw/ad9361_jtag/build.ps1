# Build the AD9361 JTAG bring-up tool with the MinGW-w64 gcc bundled with
# Vitis HLS 2021.1 (no separate compiler install needed).
param(
    [string]$Gcc = 'D:\Xilinx\Vitis_HLS\2021.1\tps\win64\msys64\mingw64\bin\gcc.exe'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$env:PATH = (Split-Path -Parent $Gcc) + ';' + $env:PATH

$src = @(
    'src\main.c', 'src\lr_platform.c', 'src\lr_init_param.c',
    'no_os\ad9361\ad9361.c', 'no_os\ad9361\ad9361_api.c',
    'no_os\ad9361\ad9361_conv.c', 'no_os\ad9361\ad9361_util.c',
    'no_os\axi_core\axi_adc_core.c', 'no_os\axi_core\axi_dac_core.c',
    'no_os\util\no_os_util.c', 'no_os\api\no_os_spi.c', 'no_os\api\no_os_gpio.c'
)
$inc = @('-Isrc', '-Ino_os\ad9361', '-Ino_os\axi_core', '-Ino_os\include')
# -UWIN32: ad9361_util.h stubs out snprintf/strsep when WIN32 is defined
# (meant for MSVC); MinGW provides real implementations.
$flags = @('-std=gnu11', '-O2', '-UWIN32', '-include', 'src/lr_compat.h', '-Wall', '-Wno-unused-variable',
           '-Wno-unused-function', '-Wno-format')
& $Gcc @flags @inc @src -o ad9361_jtag.exe -lws2_32 -lm
if ($LASTEXITCODE -ne 0) { throw "build failed" }
Write-Output "BUILD_OK $here\ad9361_jtag.exe"
