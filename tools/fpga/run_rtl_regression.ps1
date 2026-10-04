param(
    [string]$VivadoBin = 'D:\Xilinx\Vivado\2021.1\bin',
    [string]$ProjectRoot = 'D:\workspace\LightningReceiver'
)

$ErrorActionPreference = 'Stop'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
Set-Location $ProjectRoot

$rtl = @(Get-ChildItem -Path rtl -Recurse -File |
    Where-Object { $_.Name -match '\.(v|sv)$' } |
    ForEach-Object { Resolve-Path -Relative $_.FullName })
$tests = @(
    'tb_lr_async_fifo',
    'tb_raw_iq_router',
    'tb_dsp_router',
    'tb_mode_and_mux',
    'tb_fm_demod',
    'tb_audio_pipeline',
    'tb_spectrum_engine',
    'tb_signal_detector',
    'tb_lr_packetizer',
    'tb_cmac_axil_init',
    'tb_ring_buffer',
    'tb_register_bank',
    'tb_command_parser',
    'tb_button_controller',
    'tb_uart_byte_phy',
    'tb_ad9361_spi_master',
    'tb_audio_pcm_packer',
    'tb_ddc_nco',
    'tb_fm_signal_meter',
    'tb_fm_seek',
    'tb_axis_fanout2_nb',
    'tb_ui_panel',
    'tb_dc_correction',
    'tb_axis_frame_decim',
    'tb_lr_jtag_axi_core'
)

$reportDir = Join-Path $ProjectRoot 'reports\source_validation'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$log = Join-Path $reportDir 'rtl_regression.log'
"LR RTL regression started $(Get-Date -Format o)" | Set-Content $log

foreach ($test in $tests) {
    $testFile = Join-Path 'sim' ($test + '.sv')
    $snapshot = $test + '_snapshot'
    "`n=== $test ===" | Add-Content $log

    & (Join-Path $VivadoBin 'xvlog.bat') -sv -i rtl/include @rtl $testFile 2>&1 |
        Add-Content $log
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $test" }

    & (Join-Path $VivadoBin 'xelab.bat') $test -s $snapshot 2>&1 |
        Add-Content $log
    if ($LASTEXITCODE -ne 0) { throw "xelab failed: $test" }

    $simOut = @(& (Join-Path $VivadoBin 'xsim.bat') $snapshot -runall 2>&1 |
        ForEach-Object { "$_" })
    $simOut | Add-Content $log
    if ($LASTEXITCODE -ne 0) { throw "xsim failed: $test" }
    # xsim exits 0 even after $fatal/$error, so check the transcript too.
    if ($simOut -match '^(Fatal|Error):') { throw "simulation failed: $test" }
    if (-not ($simOut -match '_PASS')) { throw "no PASS marker: $test" }
}

"`nRTL_REGRESSION_PASS ($($tests.Count) tests)" | Add-Content $log
Write-Output "RTL_REGRESSION_PASS ($($tests.Count) tests)"
