param(
    [Parameter(Mandatory = $true)][string]$Test,
    [string]$VivadoBin = 'D:\Xilinx\Vivado\2021.1\bin',
    [string]$ProjectRoot = 'D:\workspace\LightningReceiver'
)

# Compile all RTL plus one testbench and run it (same flow as
# run_rtl_regression.ps1, for iterating on a single test).
$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
Set-Location $ProjectRoot

$rtl = @(Get-ChildItem -Path rtl -Recurse -File |
    Where-Object { $_.Name -match '\.(v|sv)$' } |
    ForEach-Object { Resolve-Path -Relative $_.FullName })
$snapshot = $Test + '_snapshot'

& (Join-Path $VivadoBin 'xvlog.bat') -sv -i rtl/include @rtl (Join-Path 'sim' ($Test + '.sv')) 2>&1 |
    Where-Object { "$_" -match 'ERROR|WARNING: \[VRFC' } | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $Test" }
& (Join-Path $VivadoBin 'xelab.bat') $Test -s $snapshot 2>&1 |
    Where-Object { "$_" -match 'ERROR|WARNING' } | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "xelab failed: $Test" }
$simOut = @(& (Join-Path $VivadoBin 'xsim.bat') $snapshot -runall 2>&1 | ForEach-Object { "$_" })
$simOut | Where-Object { $_ -notmatch '^(INFO|\*\*\*\*|  \*\*|source |#|Time resolution|run -all|exit)' -and $_ -ne '' }
if ($simOut -match '^(Fatal|Error):') { throw "simulation failed: $Test" }
if (-not ($simOut -match '_PASS')) { throw "no PASS marker: $Test" }
