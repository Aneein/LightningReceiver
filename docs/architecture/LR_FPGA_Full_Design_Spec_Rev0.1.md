# LR FPGA Full Design Specification Rev 0.1

> **Project:** Lightning Receiver
> **Abbreviation:** LR
> **Document Type:** FPGA Full Design Specification（一次性完整设计图纸）
> **Revision:** Rev 0.1 — Architecture Freeze for Full Implementation
> **Status:** DRAFT（随实现冻结；变更需 revision）
> **Date:** 2026-08-27
> **Parent Documents:** `Lightning_Receiver_Master_Spec_Rev0.1` · `LR_Hardware_Interface_Spec_Rev0.2c`
> **Design Philosophy:** 一次性冻结全部设计 → 一次性实现全部 RTL → 集成收敛，不做推翻式迭代（Master Spec §2.1 的彻底执行）

---

# 1. 目的与原则

本规格把 LR 的 **全部 FPGA 设计** 冻结为可施工图纸：模块全集、每个模块的接口、Stream Fabric、寄存器地图、时钟/CDC、IP 选型、XDC 规划、一次性施工顺序与分层验证策略。RTL 实现严格按本图纸施工，**不允许边做边改架构**。

**一次性设计原则**
1. 全部模块接口在本版冻结（端口名/位宽/协议）；
2. Stream Fabric 是唯一内部数据契约，任何模块不得直连其他模块的数据线；
3. 时钟域与 CDC 方案冻结（§7），实现阶段只允许登记新 CDC，不允许绕过；
4. 寄存器地址映射冻结（§6），后续只加不减；
5. IP 选型冻结（§9），以复用现有已验证配置为优先；
6. 施工顺序（§11）是"装配顺序"，不是"迭代轮次"。

**工程管理原则（用户冻结）**
- `fpga/` 目录**只允许 Vivado 生成的产物**（工程文件、BD、IP、runs、bitstream）；
- 所有标准件（时钟/复位/UART/FIFO/FFT/FIR/CIC/DDS/CMAC/MIG）一律使用 **Xilinx IP，由 Vivado 生成**；
- 自定义逻辑（Stream Fabric、DSP 胶水、packetizer、寄存器、模式、遥测）作为 RTL 源文件通过 Vivado `add_files` 加入工程；
- 工程构建全程由 Vivado 批量 Tcl 驱动（`tools/fpga/*.tcl`），禁止手工创建工程工作文件。

**可复用资产（不重复造轮子）**

| 资产 | 位置 | 复用内容 |
|---|---|---|
| F_SMART KU5P stage3 100G | `D:\workspace\xilinx\F_smart_KU5P_stage3_100g_v1\` | clk_fabric（200→225/100）、MIG DDR4-2666、CMAC CAUI4、CMAC CDC FIFO、JTAG AXI、整板约束 |
| ADI HDL fmcomms2/zc706 | `fpga/vendor_reference/FMC_AD936X_PL/` | axi_ad9361 IP（LVDS 接口）、系统级集成参考 |
| ADI no-OS / Vitis PS | `fpga/vendor_reference/FMC_AD936X_PS/` | AD9361 初始化/寄存器配置参考（app_config.h 已确认 AD9361） |
| KU5P_DEMO | `D:\workspace\xilinx\ku5p\KU5P_DEMO\` | UART/按键/DDR/100G 引脚约束参考 |

---

# 2. 模块全集（设计冻结范围）

```text
lr_top
│
├── clock_reset_subsystem
│   ├── clk_fabric           (clk_wiz 200MHz → 225MHz / 100MHz)
│   ├── rst_fabric           (proc_sys_reset)
│   └── rst_sync             (各域复位同步，F_SMART 复用)
│
├── fmcomms2_subsystem
│   ├── axi_ad9361           (ADI IP：LVDS 6-bit DDR 数据接口)
│   ├── ad9361_spi_ctrl      (SPI 初始化/控制，寄存器驱动)
│   ├── rf_status            (lock/AGC/RSSI 状态采样)
│   └── (TX 路径禁用：TX 数据恒零 + ENABLE/TXNRX 默认 RX)
│
├── timing_subsystem
│   ├── timestamp_counter    (64-bit，225MHz 自由运行)
│   ├── sample_counter       (64-bit，跟随 AD9361 样本)
│   └── sync_reserved        (外部 10M/PPS 预留端口，未启用)
│
├── lr_stream_fabric
│   ├── raw_iq_router        (AD9361 → 流 0/1)
│   ├── dsp_router           (流分发到 DSP 插槽)
│   ├── stream_metadata      (TUSER/timestamp 打包)
│   └── stream_mux           (Host 使能选通，§5.4)
│
├── dsp_subsystem
│   ├── dc_correction
│   ├── ddc_nco              (dds_compiler + complex mixer)
│   ├── cic_decimator        (cic_compiler)
│   ├── fir_filter           (fir_compiler：通道 LPF/整形)
│   ├── fft_engine           (xfft：1024/2048/4096 可配)
│   ├── spectrum_engine      (window→|X|²→scale→avg→peak)
│   ├── signal_detector      (候选信号检测)
│   ├── fm_demod             (WFM 解调)
│   └── audio_pipeline       (de-emphasis→LPF→resample→PCM)
│
├── ddr_subsystem
│   ├── mig_ddr4             (复用 F_SMART MIG 配置，2666)
│   ├── ring_buffer          (循环写/读，占用/溢出计数)
│   ├── capture_buffer       (触发冻结窗口)
│   └── buffer_manager       (地址/模式控制)
│
├── network_subsystem
│   ├── cmac_100g            (cmac_usplus CAUI4，复用)
│   ├── lr_packetizer        (Stream → LR 帧 → 以太网帧)
│   ├── stream_mux           (多流合路，流 ID 标记)
│   └── net_counters         (包/字节/丢包统计)
│
├── control_subsystem
│   ├── uart_rx / uart_tx    (自研，115200/可配)
│   ├── command_parser       (UART 命令 → 寄存器读写)
│   ├── register_bank        (AXI-Lite 从，全部控制/状态寄存器)
│   ├── mode_manager         (FM/General SDR 模式状态机)
│   └── button_controller    (4 键去抖/映射)
│
└── telemetry_subsystem      (计数器汇总 + 错误聚合 + 可查询)
```

---

# 3. 顶层架构 lr_top

## 3.1 顶层端口

| 端口 | 方向 | 约束/引脚 | 说明 |
|---|---|---|---|
| sys_clk_p/n | in | T24/U24，200MHz DIFF_SSTL12 | 系统主时钟 |
| fpga_rst | in | K9（KEY1，LVCMOS33） | 全局复位（按键复用，见 OQ-8 决议：KEY1 兼作复位输入） |
| ad9361_data_clk_p/n | in | FMC LA（BANK66/67 按 §3.2 映射） | AD9361 LVDS DATA_CLK |
| ad9361_rx_frame_p/n | in | FMC LA | RX_FRAME |
| ad9361_rx_data_p/n[5:0] | in | FMC LA | RX_D0~5 |
| ad9361_tx_frame_p/n | out | FMC LA | TX_FRAME（恒零帧，TX 禁用） |
| ad9361_tx_data_p/n[5:0] | out | FMC LA | TX_D0~5（恒零） |
| ad9361_fb_clk_p/n | in | FMC LA | FB_CLK（采样对齐） |
| ad9361_spi_* | out | FMC LA（SPI_DI/DO/CLK/ENB） | AD9361 SPI |
| ad9361_enable / txnrx | out | FMC LA16 P/N | 控制线（默认 RX-only） |
| ad9361_resetb | — | FMC J1-D31/TDO | 子卡 10 kΩ 上拉；载板未作为 FPGA GPIO 引出 |
| qsfp_refclk_p/n | in | V7/V6，156.25MHz | CMAC GT refclk |
| cmac_gt_* | — | GT BANK225 | CMAC GT（IP 内部） |
| ddr4_* | — | BANK64/65 | MIG（IP 内部，约束由 MIG 生成） |
| uart_rx / uart_tx | in/out | AD13 / AC14，LVCMOS33 | 控制面 |
| key[3:0] | in | K9/K10/J10/J11 | 按键（KEY1 兼复位） |
| led[3:0] | out | H9/J9/G11/H11 | 用户 LED + 状态 |
| (预留) ext_ref_10m / pps | in | 未分配 | 外部同步预留 |

## 3.2 FMC 引脚映射（AD9361 ↔ KU5P FMC LA）

> 依据：FMC_AD936X 原理图（信号语义）+ RK-XCKU5P-F 管脚定义（BANK66/67）。**具体引脚级映射在实现装配时用 Vivado 按 LA 对序号与 IOSTANDARD=LVDS_18 生成 XDC，此处冻结信号→FMC LA 通道对应关系**（LA00 起按序分配，见附录 A）。ADI zc706 参考的 LVDS_25 全部改为 **LVDS_18**。

| AD9361 信号 | FMC LA 分配 | 说明 |
|---|---|---|
| DATA_CLK_P/N | LA00_CC（G24/G25） | 差分时钟 |
| RX_FRAME_P/N | LA01_CC（J23/J24） | |
| RX_D0~5 (P/N) | LA02~LA07 | 6 对 |
| FB_CLK_P/N | LA08 | |
| TX_FRAME_P/N | LA09 | TX 禁用 |
| TX_D3/D0/D1/D2/D4/D5 | LA10~LA15 | 子卡实际布线；TX 禁用 |
| ENABLE/TXNRX | LA16 P/N | LVCMOS18 |
| EN_AGC/SYNC_IN | LA19 P/N | LVCMOS18，当前未用 |
| CTRL_OUT0~7 | LA20~LA23 | AD9361 输出，FPGA 不得驱动 |
| CTRL_IN0~3 | LA24~LA25 | 当前未用 |
| SPI_ENB/CLK | LA26 P/N | LVCMOS18 |
| SPI_DI/DO | LA27 P/N | LVCMOS18 |
| RESETB | J1-D31（FMC TDO） | 子卡上拉；载板未作为 FPGA GPIO 引出 |

---

# 4. Lightning Stream Fabric（内部数据契约）

所有内部模块只通过 Stream Fabric 交换数据。契约如下：

## 4.1 流格式（AXI4-Stream 兼容）

```text
TDATA [31:0]  = { i_data[15:0], q_data[15:0] }     // 复数样本，Q1.14/有符号
TUSER [15:0]  = { flags[5:0], channel_id[1:0], sample_index[7:0] }
TVALID/TREADY/TLAST                                // tlast=1 表示帧/包边界
TSIDE_CHANNEL: timestamp[63:0]                     // 64-bit 时间戳（随首样本锁存）
```

- 每拍 1 个复样本（32-bit）；带宽充裕（225MHz × 4B ≫ 61.44MSPS×4B）。
- `channel_id`：0=RX1，1=RX2（本版仅 0 有效）。
- `sample_index`：样本计数低 8 位（连续性校验用，完整 64-bit 在 side channel）。
- `flags`：bit0 overflow、bit1 drop、bit2 saturation、bit3 gain_change、bit4 sync、bit5 reserved。

## 4.2 流 ID（与 Master Spec §11 一致）

| 流 ID | 名称 | 内容 | 默认使能 |
|---|---|---|---|
| 0 | RAW_IQ_CH0 | 原始 IQ（AD9361 RX1，12bit 符号扩展 16bit） | ON |
| 1 | RAW_IQ_CH1 | 原始 IQ（RX2 预留） | OFF |
| 2 | SPECTRUM | PSD 帧流（每帧=FFT 结果，tlast 帧边界） | ON |
| 3 | AUDIO_PCM | 音频 PCM（48kHz×16bit 立体声/单声道） | ON |
| 4 | DETECT_EVENTS | 信号检测事件（频率/功率/时间戳） | ON |
| 5 | TELEMETRY | 遥测帧（周期发送） | ON |
| 6+ | RESERVED | — | OFF |

## 4.3 路由规则

- `raw_iq_router`：AD9361 RX 数据 → 流 0（raw IQ 直通 + 侧信道 timestamp）。
- `dsp_router`：从流 0 扇出到 DDC（FM 通道）与 FFT 引擎（频谱），扇出带独立 FIFO，任一消费者 backpressure 不影响其他路径（Master Spec §2.3 观测性）。
- `stream_mux`（网络侧）：按流 ID 打包进 LR 帧（§8 network 子系统），每流独立 enable。
- 所有流可独立 enable/disable（寄存器控制），禁用流在 fabric 内丢弃并计数（不占用网络带宽）。

---

# 5. 子系统详细设计

## 5.1 clock_reset_subsystem

| 项 | 值 |
|---|---|
| clk_fabric | clk_wiz：200MHz 差分输入 → **225MHz**（主 fabric）/ **100MHz**（AXI 控制），复用 F_SMART 配置 |
| rst_fabric | proc_sys_reset，异步复位同步释放；各域独立复位（cmac_rst 322MHz 域、mig_rst 333MHz 域、ad9361_rst DATA_CLK 域） |
| 复位源 | 板载复位（KEY1）+ 寄存器软复位（RESET_SUBSYSTEM） |

## 5.2 fmcomms2_subsystem

| 模块 | 设计 |
|---|---|
| axi_ad9361 | **复用 ADI IP**（zc706 工程导出），LVDS 6-bit DDR 模式；AXI-Lite 配置接口 + RX 数据 AXIS 输出 + TX AXIS 输入（恒零） |
| ad9361_spi_ctrl | 寄存器驱动的 SPI 引擎（SPI_CLK ≤ 10MHz），写入 ADI 官方初始化序列（参考 no-OS `ad9361_init` 参数，参数表冻结于附录 B） |
| rf_status | 采样 AD9361 状态（LO lock、AGC、RSSI 读回）→ 遥测 |
| TX 安全 | TX 数据通路恒零；ENABLE=1、TXNRX=RX 态（0）；初始化后写入 TX 关闭寄存器；FPGA 不接受 TX enable 命令 |

**AD9361 初始化关键参数（冻结草案，参考商家 no-OS 配置）**

| 参数 | 值 |
|---|---|
| 器件 | AD9361（ID_AD9361） |
| RX 起始频率 | 98.0 MHz（FM 中心，可调） |
| RX 采样率 | **61.44 MSPS**（LVDS 6-bit DDR，DATA_CLK=61.44MHz） |
| RX 带宽 | 28 MHz（射频滤波器） |
| 增益模式 | 慢 AGC（FM 广播） |
| 接口 | LVDS，单端口 6-bit，DDR |
| TX | 禁用 |

## 5.3 timing_subsystem

| 模块 | 端口/功能 |
|---|---|
| timestamp_counter | 64-bit 自由运行 @225MHz；`timestamp_tick` 节拍；可清零（寄存器） |
| sample_counter | 64-bit，每 AD9361 样本 +1；与 timestamp 一起锁存进每个 stream 首样本 |
| sync_reserved | 外部 10MHz/PPS 端口预留（未约束，不占引脚） |

## 5.4 lr_stream_fabric

| 模块 | 接口 | 说明 |
|---|---|---|
| raw_iq_router | 输入：axi_ad9361 RX AXIS；输出：流 0 AXIS + side timestamp | 12→16 bit 符号扩展，附加 channel_id=0 |
| dsp_router | 输入：流 0；输出：DDC 输入、FFT 输入 | 两路扇出各带 async FIFO（跨 DATA_CLK→225MHz 域） |
| stream_metadata | 旁路插入 timestamp/sample_index/flags 到 TUSER/side channel | 实现为 AXIS 寄存器级 |
| stream_mux（fabric 内使能） | 各流 enable 掩码 | 禁用流丢弃并计数 |

## 5.5 dsp_subsystem（全部参数可配，寄存器驱动）

### 5.5.1 dc_correction
- 一阶 IIR 直流估计（α 可配），减去直流分量；旁路可选。

### 5.5.2 ddc_nco
- dds_compiler（相位累加器，freq 可配）→ complex mixer（自研 4 乘法器）。
- 用途：FM 通道选择（本振 = 目标台频 - 中心频）。

### 5.5.3 cic_decimator
- cic_compiler，可配 decimation（默认 FM：61.44M → 192kHz 链）。
- 补偿 FIR 在 fir_filter 中。

### 5.5.4 fir_filter
- fir_compiler：通道 LPF（可变系数装载）、CIC 补偿、音频 LPF。
- 采用多实例或系数重载（实现时冻结）。

### 5.5.5 fft_engine
- xfft 9.1：**1024/2048/4096 可配**，forward，scaled。
- 输入：流 0（或 DDC 后）加窗；输出：复数频域流。

### 5.5.6 spectrum_engine
- 流水线：window（hanning/blackman/hamming 可选）→ |X|²（自研 2 乘法+加法）→ scale（log2 近似或查表）→ averaging（指数平均，α 可配）→ peak/max hold → PSD 帧流（流 2，tlast=帧尾）。
- 噪声估计：频带平均，输出 noise_floor。

### 5.5.7 signal_detector
- 输入：PSD 流；阈值/带宽可配；输出：DETECT_EVENTS 流（流 4）：{frequency[31:0], power[15:0], timestamp[63:0]}。
- 供 Host 扫描候选台（Master Spec §20.2）。

### 5.5.8 fm_demod
- WFM：CORDIC 相位差（atan2 差分）或 complex discriminator（I·dQ−Q·dI）；输出音频基带。

### 5.5.9 audio_pipeline
- de-emphasis（一阶，τ=75µs 可配）→ 音频 LPF（fir）→ resample（61.44M 链 → 48kHz，fir+线性插值）→ PCM 16-bit 帧流（流 3，按帧打包 tlast）。

## 5.6 ddr_subsystem

| 模块 | 设计 |
|---|---|
| mig_ddr4 | 复用 F_SMART MIG（DDR4-2666，32-bit，2GB，UI 333MHz） |
| ring_buffer | AXI 写（流 0 raw IQ 经 AXI writer）/ 读（Host 触发）；写指针循环；occupancy/overflow/drop 计数 |
| capture_buffer | 触发（事件或命令）冻结 N 样本前触发后 M 样本（pre/post trigger） |
| buffer_manager | 地址空间：ring 区 + capture 区 + 保留区；寄存器控制 |

> DDR 数据通路与 100G 数据通路的关系：DDR 是旁路缓冲（Master Spec §9），不插入实时音频路径。

## 5.7 network_subsystem

| 模块 | 设计 |
|---|---|
| cmac_100g | 复用 cmac_usplus 3.1 CAUI4（512-bit @322.27MHz），QSFP28 GT225 |
| lr_packetizer | 输入：fabric 各流（225MHz）；输出：CMAC AXIS（512-bit @322.27MHz）。打包流程：流 → LR 帧（头部 §8.2）→ 以太网帧（MAC+IP+UDP）→ 512-bit AXIS（带 tkeep/tlast） |
| stream_mux（网络） | 多流合路 + 流 ID 标记 + 每流独立 enable（寄存器） |
| net_counters | 包/字节/丢包/seq 检查统计 |

**LR 帧头（二进制布局草案，最终以 Protocol Spec 为准）**

```text
[63:0]  Magic + Version        (0x4C52_0001)
[15:0]  Header Length          (32)
[7:0]   Stream Type            (0..5)
[7:0]   Channel ID
[31:0]  Sequence Number
[63:0]  Timestamp
[63:0]  First Sample Index
[31:0]  Center Frequency
[31:0]  Sample Rate
[15:0]  Payload Format
[31:0]  Payload Length
[15:0]  Flags
[31:0]  Integrity (CRC32)
Payload...
```

## 5.8 control_subsystem

| 模块 | 设计 |
|---|---|
| uart_rx / uart_tx | 自研 UART（默认 115200-8N1，波特率寄存器可配），fabric 域采样 |
| command_parser | 文本命令（GET/SET 风格，Master Spec §14.2 类别）→ 寄存器读写；无效命令计数 |
| register_bank | **AXI-Lite 从**（225MHz/100MHz），地址映射见 §6；接 F_SMART 既有 AXI 互联（可同时被 JTAG AXI 访问） |
| mode_manager | 状态机：IDLE→FM→GENERAL_SDR（本版实现 FM + General SDR）；模式决定 RF/DSP/流配置 |
| button_controller | 4 键去抖（10ms）+ 边沿 → 命令队列（Prev/Next/PlayPause/Scan，映射可配） |

## 5.9 telemetry_subsystem

- 计数器聚合（读寄存器或周期帧，Master Spec §23 全集）：
  RX samples/frames、IQ FIFO overflow、DSP saturation、FFT frames、detected signals、DDR writes/reads/overflow、net packets/bytes/dropped、audio samples、UART commands/errors、reset reason、uptime。
- 错误聚合：任一 error 置位 → error_code 寄存器 + LED 指示。
- 周期遥测帧（流 5，默认 1Hz）发送到 Host。

---

# 6. 寄存器地图（冻结草案）

> AXI-Lite 基地址：挂在 F_SMART 既有地址空间（如 0x44A0_0000 起，随工程冻结）。偏移如下，实现时以 Protocol Spec 最终 opcode 对齐。

| 偏移 | 名称 | 属性 | 说明 |
|---|---|---|---|
| 0x00 | ID/版本 | RO | magic=0x4C52、firmware ver、protocol ver |
| 0x04 | STATUS | RO | lock/init/calib/模式/错误汇总 |
| 0x08 | CONTROL | RW | reset 子系统、清除计数 |
| 0x0C | MODE | RW | 模式选择（0=FM,1=GENERAL_SDR） |
| 0x10 | RF_FREQ | RW | 中心频率 Hz（AD9361 LO） |
| 0x14 | RF_GAIN | RW | 增益/AGC 模式 |
| 0x18 | RF_BW / RF_RATE | RW | 带宽/采样率 |
| 0x1C | RF_STATUS | RO | LO lock/AGC/RSSI |
| 0x20 | STREAM_EN | RW | 流 0..5 使能掩码 |
| 0x24 | DSP_DDC_FREQ | RW | DDC NCO 频率 |
| 0x28 | DSP_DECIM | RW | CIC decimation |
| 0x2C | FFT_SIZE / WINDOW | RW | 1024/2048/4096；window 选择 |
| 0x30 | SPEC_AVG / PEAK | RW | 平均 α、peak hold 开关 |
| 0x34 | DET_THRESH / BW | RW | 检测阈值/带宽 |
| 0x38 | AUDIO_GAIN / DEEMP | RW | 音频增益/de-emphasis τ |
| 0x3C | DDR_MODE | RW | ring/capture、pre/post 长度 |
| 0x40 | DDR_STATUS | RO | occupancy/overflow/drop |
| 0x44 | NET_STATUS | RO | CMAC link/包计数 |
| 0x48 | ERR_STATUS | RO | 错误寄存器 |
| 0x4C | UPTIME | RO | 秒 |
| 0x50 | SPI_TX | RW | AD9361 原始 24-bit SPI 事务 |
| 0x54 | SPI_RX | RO | 最近一次 24-bit SPI 返回值 |
| 0x58 | SPI_STATUS | RO | bit0 busy、bit1 done |
| 0x5C | SPI_CONTROL | WO | 写 bit0=1 启动事务 |
| 0x60/0x64 | DET_EVENT LO/HI | RO | 最近检测事件 64-bit |
| 0x68 | CMAC_STATUS | RO | CMAC 初始化/链路状态 |
| 0x6C..0xFF | 保留 | — | — |

UART 调试命令额外支持 `SPI_TX <decimal24>`、`SPI_GO`、`SPI_RX`，使板载
FT2232 串口可以承载 ADI no-OS 的读写/轮询流程，不依赖 JTAG AXI。`RF_FREQ`、
`RF_GAIN`、`RF_BW_RATE` 当前是软件期望值寄存器；必须由 no-OS 控制程序转换为
AD9361 寄存器事务后才会改变射频芯片，不能把写入这些寄存器等同于 RF 已配置。

---

# 7. 时钟与 CDC 清单

| 时钟域 | 频率 | 来源 | 用途 |
|---|---|---|---|
| clk_fabric | 225 MHz | clk_wiz（200MHz 输入） | 主逻辑/控制/寄存器 |
| clk_ctrl | 100 MHz | clk_wiz | AXI 控制互联（F_SMART 复用） |
| ad9361_clk | 61.44 MHz | DATA_CLK（LVDS IBUFDS→BUFG） | AD9361 接口 |
| mig_ui_clk | 333 MHz | MIG | DDR4 UI |
| cmac_usrclk | 322.27 MHz | CMAC GT | CMAC AXIS |
| uart 采样 | 225 MHz 域 | 过采样 | UART |

**CDC 登记（实现时逐项落实，全部 async FIFO/同步器/握手）**

| # | 跨域 | 信号 | 方法 |
|---|---|---|---|
| 1 | ad9361 → fabric | RX 数据/帧 | async FIFO（axi_ad9361 内部/外部） |
| 2 | fabric → ad9361 | TX（恒零）/控制 | async FIFO |
| 3 | fabric → mig_ui | AXI 写/读 | F_SMART 既有时钟转换 |
| 4 | fabric → cmac_usrclk | AXIS 打包数据 | axis_data_fifo（复用 F_SMART cmac CDC） |
| 5 | cmac_usrclk → fabric | RX 状态/计数 | 同步器/CDC FIFO |
| 6 | 外部（预留）→ fabric | 10M/PPS | 同步器 |

---

# 8. 数据流与带宽预算

| 路径 | 速率 | 带宽 |
|---|---|---|
| AD9361 RX1 → fabric | 61.44 MSPS × 32-bit | 245.8 MB/s |
| fabric → DDR ring（流 0 可选） | 同上 | 245.8 MB/s |
| DDR ring 容量 | 2 GB | ≈8.1 s raw IQ @61.44M |
| FM 通道（DDC 后） | 192 kSPS × 32-bit | 0.77 MB/s |
| Audio PCM | 48 kHz × 16-bit × 2 | 192 KB/s |
| PSD 帧 | 4096 点 × 32-bit × ~15k 帧/s | ≈246 MB/s（突发，可节流） |
| 100G 链路 | 100 Gbps | 12.5 GB/s ≫ 总和 |

**结论**：链路带宽充裕，瓶颈在 DDR ring 写入与 PSD 帧节流策略（spectrum 帧可降帧率/降分辨率以匹配 DDR/网络）。

---

# 9. IP 选型清单（冻结）

| IP | 版本 | 用途 | 来源 |
|---|---|---|---|
| clk_wiz | 6.0 | 200→225/100 | Xilinx（Vivado 生成） |
| proc_sys_reset | 5.0 | 复位 | Xilinx（Vivado 生成） |
| axi_uartlite | 2.0 | 控制面 UART（替代自研） | Xilinx（Vivado 生成） |
| axi_ad9361 | ADI | LVDS 接口 | ADI hdl（Vivado 导入生成） |
| ddr4 (MIG) | 2.2 | DDR4-2666 32-bit | F_SMART 复用 |
| cmac_usplus | 3.1 | 100G CAUI4 | F_SMART 复用 |
| xfft | 9.1 | FFT | Xilinx（Vivado 生成） |
| dds_compiler | — | NCO | Xilinx（Vivado 生成） |
| cic_compiler | — | 抽取 | Xilinx（Vivado 生成） |
| fir_compiler | — | 滤波 | Xilinx（Vivado 生成） |
| axis_data_fifo / fifo_generator | — | CDC/缓冲（替代自研） | Xilinx（Vivado 生成） |

---

# 10. XDC 规划

| 组 | 内容 | 来源 |
|---|---|---|
| 时钟 | 200MHz（T24）、156.25MHz（V7）、PCIe 100M（AB7，如保留）、MIG/CMAC 生成时钟 | 现有约束复用 |
| FMC/AD9361 | LVDS_18 差分约束 + DIFF_TERM + 引脚映射（§3.2/附录 A） | 新写（LVDS_25→LVDS_18） |
| 控制/按键/LED/UART | LVCMOS33 | KU5P_DEMO 复用 |
| CDC | §7 各跨域 false_path / set_clock_groups | 新写（参照 F_SMART stage3_cdc） |
| 配置 | BITSTREAM COMPRESS / CONFIGRATE 63.8 | 复用 |

---

# 11. 一次性施工顺序（装配顺序，非迭代）

> 全部步骤在同一 LR Vivado 工程内完成；每步结束以"可综合 + 时序检查"为检查点，架构不回退。

| 步骤 | 内容 | 检查点 |
|---|---|---|
| S0 | 复制 F_SMART stage3 基座 → 建 LR 工程；lr_top 例化空壳 + clock/reset + telemetry；替换板级约束 | 综合通过，WNS 基线 |
| S1 | fmcomms2_subsystem（axi_ad9361 + SPI + rf_status）+ timing + raw_iq_router → 流 0 | 综合/仿真：合成 IQ 进 fabric |
| S2 | stream fabric 全量 + DDR ring + network（packetizer/CMAC）→ 流 0 端到端（合成数据） | 仿真 + 板上回环，Gate E 等效 |
| S3 | DSP 流水线（DDC→FFT/PSD→detector→FM→audio）挂到流 0 | 仿真 golden 对比（Python 参考） |
| S4 | 控制面（UART/寄存器/模式/按键）+ 遥测全量 | 命令级仿真 |
| S5 | 全集成：时序收敛（WNS≥0）、bitstream、片上验证（真实 RF） | Gate C/D/E 验收 |

---

# 12. 分层验证策略（Master Spec §26 落地）

| 层 | 内容 | 方法 |
|---|---|---|
| L0 板级 | 时钟/复位/UART/按键/LED/DDR/100G | 出厂 demo 已验证基线 |
| L1 RF 接口 | AD9361 SPI/LO lock/RX IQ 已知音 | 复用商家 zc706 工程验证流程 |
| L2 流完整性 | sample/timestamp/FIFO/CDC/合成 pattern | SystemVerilog TB + 断言 |
| L3 DSP | NCO/FIR/CIC/FFT/FM 与 **Python golden** 对比 | 仿真向量 + 参考脚本（tools/iq_analyzer） |
| L4 DDR | 持续写读/回绕/pre-trigger/溢出 | TB + 板上自检 |
| L5 网络 | 序列号/吞吐/丢包/长稳 | 合成发生器 + Host 校验 |
| L6 端到端 | 天线→AD9361→FPGA→100G→Host→扬声器 | 实物验收（FM V1 标准，Master Spec §25） |

---

# 13. 与现有资产的关系

- **基座**：F_SMART KU5P stage3 100G（clk/MIG/CMAC/AXI/JTAG）→ 复制为 LR 工程起点，**不重写已验证部分**。
- **RF 接口**：ADI hdl axi_ad9361（zc706）→ 复用 IP，重映射引脚与电平（LVDS_18）。
- **软件参考**：商家 no-OS 参数表 → 冻结为附录 B；PC Golden DSP 后续在 host/ 实现。

---

# 14. 开放问题（实现前冻结）

| ID | 问题 | 处置 |
|---|---|---|
| DQ-1 | axi_ad9361 IP 在 KU5P（UltraScale+）与 zc706（7 系）的资源/时序差异 | 装配 S1 时验证；必要时用自研 LVDS 捕获替代 |
| DQ-2 | FM 采样率 61.44M vs 通道链 decimation 组合 | 用 golden 仿真冻结系数（L3） |
| DQ-3 | PSD 帧节流策略（帧率 vs 带宽） | 按带宽预算设计 rate limiter |
| DQ-4 | DDR ring 与 100G 的地址/仲裁复用 | S2 装配时按 F_SMART 既有 AXI 拓扑挂接 |
| DQ-5 | UART 协议最终 opcode（与 Protocol Spec 对齐） | 协议文档冻结后回填 |

---

# 附录 A：FMC LA 引脚映射表（实现时生成 XDC 依据）

> 载板侧引脚号以 `RK-XCKU5P-F_V1.2_pin_definition.txt`（FMC 页）为准；信号对应关系已按 `FMC_AD936X.pdf` 第 1 页 J1 连接器与 FMC LPC 标准交叉核对并冻结。

| FMC 通道 | P 引脚 | N 引脚 | AD9361 信号 | IOSTANDARD |
|---|---|---|---|---|
| LA00_CC | G24 | G25 | DATA_CLK | LVDS_18 |
| LA01_CC | J23 | J24 | RX_FRAME | LVDS_18 |
| LA02 | H21 | H22 | RX_D0 | LVDS_18 |
| LA03 | J19 | J20 | RX_D1 | LVDS_18 |
| LA04 | H26 | G26 | RX_D2 | LVDS_18 |
| LA05 | F24 | F25 | RX_D3 | LVDS_18 |
| LA06 | G20 | G21 | RX_D4 | LVDS_18 |
| LA07 | D24 | D25 | RX_D5 | LVDS_18 |
| LA08 | D26 | C26 | FB_CLK | LVDS_18 |
| LA09 | E25 | E26 | TX_FRAME | LVDS_18 |
| LA10 | B25 | B26 | TX_D3 | LVDS_18 |
| LA11 | A24 | A25 | TX_D0 | LVDS_18 |
| LA12 | D23 | C24 | TX_D1 | LVDS_18 |
| LA13 | F23 | E23 | TX_D2 | LVDS_18 |
| LA14 | C23 | B24 | TX_D4 | LVDS_18 |
| LA15 | H18 | H19 | TX_D5 | LVDS_18 |
| LA16 | E21 | D21 | ENABLE / TXNRX | LVCMOS18 |
| LA17_CC | C18 | C19 | 未用 | LVCMOS18 |
| LA18_CC | D19 | D20 | 未用 | LVCMOS18 |
| LA19 | A22 | A23 | EN_AGC / SYNC_IN | LVCMOS18 |
| LA20 | F20 | E20 | CTRL_OUT0 / CTRL_OUT1 | LVCMOS18（AD9361→FPGA） |
| LA21 | C21 | B21 | CTRL_OUT2 / CTRL_OUT3 | LVCMOS18（AD9361→FPGA） |
| LA22 | H16 | G16 | CTRL_OUT4 / CTRL_OUT5 | LVCMOS18（AD9361→FPGA） |
| LA23 | C22 | B22 | CTRL_OUT6 / CTRL_OUT7 | LVCMOS18（AD9361→FPGA） |
| LA24 | A17 | A18 | CTRL_IN0 / CTRL_IN1 | LVCMOS18 |
| LA25 | E18 | D18 | CTRL_IN2 / CTRL_IN3 | LVCMOS18 |
| LA26 | A19 | A20 | SPI_ENB / SPI_CLK | LVCMOS18 |
| LA27 | F18 | F19 | SPI_DI / SPI_DO | LVCMOS18 |
| LA28~LA33 | — | — | 未用 | — |

> RESETB 位于子卡 J1-D31（FMC TDO），不属于 LA；RK-XCKU5P-F 载板没有把它作为 FPGA GPIO 引出。子卡 R11=10 kΩ 将 RESETB 上拉到 VDD_INTERFACE，因此本设计不创建或约束 `gpio_resetb` 顶层输出。

# 附录 B：AD9361 初始化参数（冻结草案，参考商家 no-OS）

| 参数 | 值 | 备注 |
|---|---|---|
| dev_sel | ID_AD9361 | 已确认 |
| rx_synthesizer_frequency_hz | 98,000,000 | FM 中心（可调） |
| rx_path_clock_frequencies | 61.44M 链 | [61.44M, 30.72M, 15.36M, 7.68M, 3.84M, 1.92M] 参考 |
| 接口模式 | LVDS 6-bit DDR | DATA_CLK 61.44MHz |
| 增益 | slow_attack AGC | FM |
| TX | 禁用（TX 关闭寄存器 + 数据恒零） | RX-only 安全 |

# 附录 C：版本历史

| Rev | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-08-27 | 全模块图纸冻结（接口/流/寄存器/时钟/IP/XDC/施工/验证） |

---

> **本版结论**：LR FPGA 全部设计已冻结为图纸。下一步按 §11 施工顺序，在复制 F_SMART stage3 基座的 LR 工程内一次性装配实现，每步以"可综合+时序检查"为检查点，直至 bitstream 与 Gate C/D/E 验收。
