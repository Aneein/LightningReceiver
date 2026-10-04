# S2 BD 悬空引脚核查

核查基于 `tools/fpga/_codex_validate_design.tcl` 在 Vivado 2021.1 中重新创建的 `system` BD。最终统计为：

- 悬空标量输入：**0**
- 悬空标量输出：**43**
- BD 校验：**0 ERROR / 0 CRITICAL WARNING**

所有未连接项都是未使用的输出，不能通过接常量来“消除”。将无消费者的输出随意互接会改变功能或制造多驱动，因此按用途逐项保留如下。

## AD9361 接口核（26）

- RX2/第二接收通道未启用（6）：`adc_data_i1`、`adc_data_q1`、`adc_enable_i1`、`adc_enable_q1`、`adc_valid_i1`、`adc_valid_q1`。
- 本设计为 RX-only，TX 数据面未启用（16）：`dac_enable_i0/i1/q0/q1`、`dac_valid_i0/i1/q0/q1`、`dac_r1_mode`、`dac_sync_out`、`tx_clk_out_p/n`、`tx_data_out_p/n`、`tx_frame_out_p/n`。AD9361 外部 `txnrx` 已固定为 RX 状态，不能把这些输出回接到 RX 路径。
- 可选状态/扩展输出（4）：`gps_pps_irq`、`tdd_sync_cntr`、`up_adc_gpio_out`、`up_dac_gpio_out`。当前 LR 接收模式不使用 GPS PPS、TDD 或 ADI 内部 GPIO 扩展。

说明：实际报告中 AD9361 项共 26 个，以 `unconnected_bd_pins.rpt` 为精确清单；上面的功能分类覆盖全部这些端口。RX0 的 I/Q/valid/enable、SPI、复位、时钟和 RX 方向控制均已连接。

## CMAC 可选观测输出（4）

- `gt_ref_clk_out`、`gt_rxrecclkout`：可选恢复/转发时钟，当前设计不以它们驱动任何逻辑。
- `rx_preambleout`：接收报文前导信息未用于当前 RX 监测路径。
- `user_reg0`：CMAC 可选用户寄存器输出，当前控制面通过 AXI-Lite 访问 CMAC。

CMAC RX AXIS 已接异步 FIFO并持续排空，链路、对齐、故障、复位和收发事件均已同步到 telemetry；CMAC TX 由 packetizer 驱动。

## MIG 调试输出（2）

- `dbg_bus`、`dbg_clk`：MIG 可选调试端口；功能设计不需要消费者。DDR AXI、校准状态、UI 时钟和复位均已连接。

## Processor System Reset 未使用输出（8）

- `rst_cmac_100/bus_struct_reset`、`rst_cmac_100/mb_reset`
- `rst_fabric/bus_struct_reset`、`rst_fabric/mb_reset`、`rst_fabric/peripheral_reset`
- `rst_mig_ui/bus_struct_reset`、`rst_mig_ui/mb_reset`、`rst_mig_ui/peripheral_reset`

设计没有 MicroBlaze，也不需要这些 active-high 复位副本。各域实际使用的 `peripheral_aresetn` / `interconnect_aresetn` 已连接，不能把不同极性的复位输出互接。

## LR 寄存器影子值（3）

- `u_reg/reg_rf_freq`
- `u_reg/reg_rf_gain`
- `u_reg/reg_rf_bw_rate`

这些是软件可读写的 RF 目标值影子寄存器。AD9361 的 LO、增益和采样率设置必须按器件要求执行一组有序 SPI/no-OS 寄存器事务，不能把 32-bit 数值直接连到 `axi_ad9361` 数据通道。可工作的原始 SPI 命令/状态寄存器和物理 SPI 主机已经连接，RF 影子值保留给上位机事务层使用。

## 时序相关结论

旧报告中 `rst_fabric/peripheral_aresetn`（225 MHz 域）直接驱动 `axi_ad9361/up_enable`（100 MHz up/AXI 域）的路径已删除；`up_enable` 现由静态 `const_one` 驱动，AD9361 AXI 逻辑仍由本域 `s_axi_aresetn` 复位。所有真正跨域的数据/事件分别使用 AXIS Clock Converter、AXI Clock Converter、Gray-pointer async FIFO、双触发器电平同步或事件锁存同步。

该报告是源级/BD 审计，不替代用户随后运行的 post-route `report_timing_summary`。FMC DQ-1 的板级物理映射也必须由原理图和实物确认。
