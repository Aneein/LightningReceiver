# LightningReceiver presynthesis readiness

Checked on 2026-08-31 with the project open in Vivado 2021.1.

## Ready for manual synthesis

- `validate_bd_design` passed.
- All block-design output products were regenerated.
- Project compile order was refreshed in automatic source-management mode.
- The changed `lr_button_controller` module reference was refreshed through
  its active `system_u_btn_0` proxy XCI; Vivado no longer reports stale module
  references.
- No project file has `IS_MISSING == 1`.
- Active `u_cmac_init` proxy XCI is resolved and its AXI-Lite master is connected.
- Active `u_pkt` proxy XCI contains broadcast bring-up destinations:
  - destination MAC `FF:FF:FF:FF:FF:FF`
  - destination IPv4 `255.255.255.255`
- Block-design audit result:
  - open scalar input pins: 0
  - open top-level input ports: 0
  - open top-level output ports: 0
  - open top-level slave/master interface ports: 0
- RTL regression result: `RTL_REGRESSION_PASS (16 tests)`.
- Neither `synth_1` nor `impl_1` was launched or reset by the finalization scripts.
- Static timing-constraint audit corrected two errors proven by the prior
  implementation log: the unsupported XDC `foreach` construct was replaced by
  explicit first-stage synchronizer exceptions, and the CMAC reference clock
  group now uses the actual `qsfp_refclk_p` clock object. Button synchronizers
  are also marked `ASYNC_REG`. Both updated XDC files were parsed against the
  existing synthesized checkpoint with `LR_TIMING_XDC_PARSE_PASS`; no run was
  launched or reset for that check.
- FMC electrical mapping was cross-checked against both hardware sources:
  `FMC_AD936X.pdf` supplies the J1 signal assignment and
  `RK-XCKU5P-F_V1.2_pin_definition.txt` supplies the carrier package pins.
  RX DATA_CLK/RX_FRAME/RX_D0..5 map to LA00..LA07, ENABLE/TXNRX to LA16,
  and SPI_ENB/CLK/DI/DO to LA26/LA27. The resulting package pins in
  `lr_fmc_ad9361.xdc` match exactly. The carrier manual confirms VADJ1 defaults
  to 1.8 V, so LVDS/LVCMOS18 is the applicable bank standard. Exact mapping,
  P/N polarity, I/O standard, and RX termination are now frozen by the
  presynthesis finalizer.
- AD936X RESETB is J1-D31/FMC-TDO, not H31 or an LA signal. The carrier
  schematic does not route that TDO pin to FPGA user I/O, while the card has a
  10 kOhm pull-up to VDD_INTERFACE. Therefore no FPGA RESETB boundary port is
  present; the earlier LA23/CTRL_OUT6 drive was electrically invalid and stays
  prohibited by the finalizer.

The detailed connectivity listing is in `bd_connectivity_audit.txt`. Unconnected
cell outputs in that report are producer/status outputs or unused optional data
paths; they do not leave a consumer input floating and therefore require no
tie-off. The eight unconsumed master interfaces are CMAC optional monitoring,
unused DDS/CMAC-RX paths, and internal event/config buses reserved for future
consumers.

## Functional boundary still requiring hardware closure

The AD9361 electrical pin map and Mode-1 SPI transaction engine are corrected,
and raw 24-bit SPI transactions are available through the command path. The
`RF_FREQ`, `RF_GAIN`, and `RF_BW_RATE` registers are currently storage/status
registers; a complete AD9361 no-OS initialization/calibration sequence is not
implemented autonomously in PL. RF hardware acceptance therefore requires the
external no-OS/host sequence (including read/poll/calibration steps) or a later
integration of an equivalent controller.

Timing closure and placed/routed functional checks are intentionally deferred
until the user runs synthesis and implementation.
