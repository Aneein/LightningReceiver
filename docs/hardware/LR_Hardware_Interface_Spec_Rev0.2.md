# LR Hardware Interface Specification Rev 0.2

> **Project:** Lightning Receiver
> **Abbreviation:** LR
> **Document Type:** Hardware Interface Specification (HIS)
> **Revision:** Rev 0.2 — Vendor Board Baseline（板级接口已用厂商资料与现有工程确认）
> **Status:** PARTIALLY CONFIRMED（KU5P 板级条目 L2 CONFIRMED；FMCOMMS2/AD9361 与主机侧条目仍 OPEN）
> **Date:** 2026-08-27
> **Parent Document:** `Lightning_Receiver_Master_Spec_Rev0.1`
> **Gate Dependency:** Gate A / B / C / D 的前置输入文档
> **Filing Path:** `docs/hardware/`
> **Source Material:** 厂商网盘资料（`D:\Data\Baidu_disk_download\9.RK-XCKU5P-F开发板网盘资料`）+ 现有工程（`D:\workspace\xilinx`）；提取文本见 `docs/hardware/source/`

---

# 1. 目的与范围

按 `Lightning_Receiver_Master_Spec_Rev0.1` §37 冻结 LR 第一版 bitstream 所依赖的全部板级硬件接口。本文档只登记「来自官方资料或实测」的数据，禁止猜测。

**本版变更（Rev 0.1 → 0.2）**：已取得 RK-XCKU5P-F V1.2 开发板出厂资料（用户手册、原理图、管脚定义、等长说明、KU5P_DEMO 源码）并解析归档；KU5P 板级条目（HWI-01~04/08~13）升级为 **L2 CONFIRMED**。

**与 Master Spec 的差异说明（重要）**：

| Master Spec 假设 | 板卡实际 | 影响 |
|---|---|---|
| FMC-LPC | **FMC HPC**（LA 34 对 + 8 路 GTY） | HPC 连接器完全包含 LPC 信号子集，FMCOMMS2（LPC 子卡）可插入；FMC 高速 GTY 侧另有 25G 能力可用 |
| 100GbE 光口/GT | **QSFP28 ×1，GT BANK225 4×25G** | 与假设一致，参考时钟 156.25MHz |
| DDR4 约 2 GB | **2 GB（2× Micron 1GB，32-bit）** | 一致，2666 Mbps |
| RF 子卡 = AD-FMCOMMS2（ADI 官方） | **FMC_AD936X（第三方 AD936X 卡，FMC-LPC）** | 引脚与 ADI FMCOMMS2 LVDS 接口兼容（商家用 ADI hdl fmcomms2/zc706 工程测试）；**具体芯片型号（AD9361/9363/9364）待确认，决定 FM 频段可行性（OQ-9）** |

---

# 2. 冻结状态定义与条目汇总

| Level | 名称 | 含义 |
|---|---|---|
| L0 | OPEN | 信息缺失，禁止用于实现 |
| L1 | DRAFT | 已有数据，未与官方文档/实测核对 |
| L2 | CONFIRMED | 已与厂商文档、原理图或实测结果一致 |
| L3 | FROZEN | 已写入 XDC/约束/驱动/软件，变更需走 revision |

| 条目 | 内容 | 状态 | 依据 |
|---|---|---|---|
| HWI-01 | 板卡型号与原理图版本 | **L2** | 用户手册 / 原理图 |
| HWI-02 | FPGA exact part | **L2** | 用户手册 + 全部 .xpr |
| HWI-03 | FMC 引脚映射 | **L2** | 管脚定义.xls + 工作 XDC |
| HWI-04 | FMC VADJ / IO bank 电压 | **L2** | 用户手册 §1.16 / 原理图 |
| HWI-05 | FMCOMMS2 原理图 / user guide | **L2** | FMC_AD936X 原理图（5 页）+ ADI hdl fmcomms2/zc706 工程 |
| HWI-06 | AD9361 数字接口模式 | **L2** | 原理图：LVDS 6-bit DDR（DATA_CLK/FB_CLK/RX_D0~5/TX_D0~5/FRAME） |
| HWI-07 | AD9361 参考时钟 | **L2** | 板载 40 MHz 晶振（Y1） |
| HWI-08 | KU5P 板级时钟 | **L2** | 用户手册 + 管脚定义 |
| HWI-09 | DDR4 拓扑 | **L2** | 用户手册 + 原理图 + MIG |
| HWI-10 | 100G GT 参考（IBERT） | **L2** | IBERT 4×25G 工程 |
| HWI-11 | CMAC/GT 配置 | **L2** | 用户工程 F_SMART KU5P stage3 100G（CAUI4，时序收敛+bitstream） |
| HWI-12 | UART 实现 | **L2** | 用户手册 + 管脚定义 |
| HWI-13 | 板载按键 pinout | **L2** | 管脚定义 + demo XDC |
| HWI-14 | ConnectX-4 驱动/配置 | **L2** | 用户确认：MCX455A-ECAT（ConnectX-4 VPI，100GbE/EDR IB，单口 QSFP28，PCIe3.0 x16） |
| HWI-15 | 天线型号/频率/连接器 | L0 | 需实物确认 |
| HWI-16 | 同轴线/转接头 | L0 | 需实物确认 |

---

# 3. 硬件清单（Inventory）

| 项目 | 型号/规格 | 状态 |
|---|---|---|
| FPGA 开发板 | **RIGUKE RK-XCKU5P-F V1.2**（板载 FT2232HQ 下载器/USB Type-C） | L2 |
| FPGA | **XCKU5P-2FFVB676I**（Vivado part: `xcku5p-ffvb676-2-i`，工业级） | L2 |
| DDR4 | **2 × Micron MT40A512M16LY-062E**（1GB×2，32-bit，2GB） | L2 |
| QSPI | MX25U51245GZ4I00（512 Mbit，1.8V CMOS） | L2 |
| 千兆以太网 | RTL8211F-CG（RGMII，10/100/1000） | L2 |
| 100G 光口 | **QSFP28 ×1**（BANK225 GTY，4×25G） | L2 |
| PCIe | PCIe 3.0 x4（x8 槽型，BANK224 GTY） | L2 |
| RF 子卡 | **FMC_AD936X**（第三方 AD936X 卡，FMC-LPC）`[芯片型号待确认：AD9361/9363/9364]` | L2（板）/ L0（型号） |
| 主机网卡 | **Mellanox ConnectX-4 VPI MCX455A-ECAT**（100GbE/EDR IB，单口 QSFP28，PCIe3.0 x16） | L2 |
| 天线 | `[待确认]`（FM 频段 88–108 MHz 能力待验证） | L0 |
| 同轴线/转接头 | `[待确认]` | L0 |
| 主机 | Windows 11 x64 `[待确认 build]` | L0 |

---

# 4. 待收集资料状态（映射 Master Spec §37）

| # | 资料 | 状态 | 备注 |
|---|---|---|---|
| 1 | KU5P 板卡型号与 schematic | ✅ 已收集 | V1.2 手册+原理图，见 source/ |
| 2 | FPGA exact part | ✅ 已确认 | xcku5p-ffvb676-2-i |
| 3 | FMC-LPC pin mapping | ✅ 已确认 | 实为 FMC-HPC，管脚定义.xls |
| 4 | FMC VADJ 与 IO bank voltage | ✅ 已确认 | VADJ1 默认 1.8V（可改 1.2V） |
| 5 | FMCOMMS2 schematic / user guide | ✅ 已收集 | **FMC_AD936X** 原理图 PDF（`D:\Baidu_disk_download\FMC_AD936X资料\`）+ ADI hdl fmcomms2/zc706 工程 |
| 6 | AD9361 digital interface mode | ✅ 已确认 | LVDS 6-bit DDR（原理图） |
| 7 | AD9361 reference clock | ✅ 已确认 | 板载 40 MHz 晶振（Y1） |
| 8 | KU5P board clocks | ✅ 已确认 | 见 §5.2 |
| 9 | DDR4 exact topology | ✅ 已确认 | 见 §5.3 |
| 10 | 原厂 100G reference project | ✅ 已确认 | IBERT 4×25G（2021.1 / 2023.1）；无 CMAC 示例 |
| 11 | 100G CMAC/GT configuration | 🟡 部分确认 | GT 侧 IBERT 已验；CMAC 待自建 |
| 12 | UART implementation | ✅ 已确认 | FT2232HQ |
| 13 | board button pinout | ✅ 已确认 | KEY1-4 |
| 14 | ConnectX-4 驱动/配置 | ⏳ 待收集 | 需主机实测 |
| 15 | 天线型号、频率、连接器 | ⏳ 待收集 | 需实物 |
| 16 | 同轴线/转接头 | ⏳ 待收集 | 需实物 |

---

# 5. KU5P 开发板接口（L2 CONFIRMED）

## 5.1 FPGA Exact Part（HWI-02）

| 字段 | 值 | 依据 |
|---|---|---|
| 器件 | Kintex UltraScale+ **XCKU5P** | 手册 / 全部 demo .xpr |
| Vivado Part | **`xcku5p-ffvb676-2-i`** | 各工程 .xpr `Part=` |
| 速度等级 | -2 | 同上 |
| 封装 | FFVB676 | 同上 |
| 等级 | I（工业） | 同上 |
| 配置 | QSPI x1（MX25U51245GZ4I00，1.8V） | 手册 |

## 5.2 板级时钟（HWI-08）

| 用途 | 频率 | 引脚（P/N） | 标准 | 说明 |
|---|---|---|---|---|
| 系统主时钟 SYS_CLK | **200 MHz 差分** | T24 / U24 | DIFF_SSTL12 | 手册确认；DDR4 参考与用户逻辑共用；bank 65 |
| HD bank 单端晶振（预留） | `[原理图确认频率]` | `[待确认]` | — | 手册 §1.12 |
| QSFP28 GT refclk | **156.25 MHz 差分** | V7 / V6（GT_CLK156P25） | 差分 | BANK225 REFCLK0（MGTREFCLK0_225） |
| PCIe refclk | **100 MHz 差分** | AB7 / AB6 | 差分 | BANK224 REFCLK0 |
| FMC GBTCLK0 / 1（M2C） | 由子卡提供 | P7/P6（226）、K7/K6（227） | 差分 | FMC 高速参考时钟 |

## 5.3 DDR4（HWI-09）

| 字段 | 值 |
|---|---|
| 器件 | **2 × Micron MT40A512M16LY-062E**（512M×16，1GB 每片） |
| 容量 | **2 GB**（2 片 16-bit = 32-bit 总线，单 CS） |
| 位宽 | 32-bit（DQ[0:31]，4×DQS，4×DM） |
| 最大数据速率 | **2666 Mbps**（DDR4-2666；MIG UI 时钟 333 MHz，见 XDMA 工程 `rst_ddr4_0_333M`） |
| FPGA Bank | HP **BANK64 / BANK65**（IO 名后缀 `_64/_65`） |
| 地址 | A[0:16]，BA[0:1]，BG[0]，ACT_B，ALERT_B，PARITY，RAS/CAS/WE，CS_B，CKE，ODT，CLK_P/N，RST |
| 管脚明细 | 见 `source/RK-XCKU5P-F_V1.2_pin_definition.txt`（DDR4 页）与 KU5P_DEMO 06 DDR_AXI `Phy_Pin.xdc` |
| 可用 MIG 工程参考 | `D:\workspace\xilinx\ku5p\KU5P_DEMO\06_DDR_AXI\`；XDMA 工程 DDR4 配置（2666） |

## 5.4 FMC 连接器（HWI-03 / HWI-04）— 实为 FMC HPC

| 字段 | 值 |
|---|---|
| 连接器 | **FMC HPC**（Master Spec 假设 LPC，HPC 兼容 LPC 子卡） |
| LA 信号 | **FMC_LA00_CC ~ LA33**（34 对差分）→ HP **BANK66 / BANK67** |
| FMC_CLK0 | H23/H24（BANK66） |
| FMC_CLK1 | B19/B20（BANK67） |
| FMC 管理 | FMC_SCL F10、FMC_SDA F9、PWRGD G10（BANK86） |
| 高速 GTY | **FMC_DP0~DP7（8 路，25 Gbps 级）** → GTY **BANK226 / BANK227** |
| GBTCLK | FMC_GBTCLK0_M2C（BANK226 REFCLK0）、FMC_GBTCLK1_M2C（BANK227 REFCLK0） |
| **VADJ1** | **默认 1.8V**；可改 RA 电阻为 1.2V（手册 §1.16） |
| 等长 | LA 全组 ~2137 mil 等长；DP 成对等长（见等长说明.xls） |
| 出厂测试约束参考 | `image_ku5p.srcs\constrs_1\new\FMC.xdc`（LVCMOS18 72 pin） |

> ✅ **Gate A 关键检查项已通过研判**：FMCOMMS2 与 VADJ1=1.8V 匹配（见 §6.2 / OQ-1），实物上电时复核。

## 5.5 UART（HWI-12）

| 字段 | 值 |
|---|---|
| 实现 | **FT2232HQ**（双通道：UART + JTAG，单 USB Type-C 线） |
| FPGA 引脚 | RX **AD13** / TX **AC14**（BANK84，LVCMOS33） |
| 波特率 | 待冻结（FT2232 灵活；demo 常用 115200） |
| 参考 | KU5P_DEMO `04_UART\Constraint\Phy_Pin.xdc`；出厂工具 image_ku5p 回环测试 |

## 5.6 板载按键与 LED（HWI-13）

| 按键 | 引脚 | 电平 | 建议映射（待体验后冻结） |
|---|---|---|---|
| KEY1 | **K9** | LVCMOS33 | Previous Station（注：部分 demo 用作复位输入） |
| KEY2 | **K10** | LVCMOS33 | Next Station |
| KEY3 | **J10** | LVCMOS33 | Play/Pause |
| KEY4 | **J11** | LVCMOS33 | Scan/Mode |

| LED | 引脚 | 说明 |
|---|---|---|
| LED1~LED4 | **H9 / J9 / G11 / H11** | 用户 LED（BANK86，LVCMOS33） |
| FAN | G9 | 两线风扇（无 PWM，手册 §1.13） |

## 5.7 100G 光口（HWI-10 / HWI-11）

| 字段 | 值 |
|---|---|
| 连接器 | **QSFP28 ×1**（100G 光模块，如 Intel CWDM4 + LC 光纤） |
| GT | **BANK225 GTY**：QSFP1~4 RX/TX（每路 25 Gbps） |
| GT refclk | **156.25 MHz**（GT_CLK156P25，MGTREFCLK0_225，V7/V6） |
| 控制/I2C | QSFP_SCL AE15、SDA AE13、INTL Y13、LPMODE W14、MODPRSL AA13、MODSELL W13、RESETL W12（BANK84） |
| 厂商 GT 参考 | **IBERT 4×25G**：`D:\workspace\xilinx\ku5p\IBERT_100G_2021_1\`（Vivado 2021.1）、`IBERT_100G_ADV_2023_1\`（2023.1）、KU5P_DEMO `08_IBERT\` |
| IBERT 关键参数 | QUAD 225，4 ch，**25 Gbps**，QPLL0，refclk 156.25 MHz（见 `reports\ibert_config.txt`） |
| CMAC 100G 参考 | ✅ **用户自有工程 `F_smart_KU5P_stage3_100g_v1`**：cmac_usplus 3.1（Vivado 2021.1），CAUI4（4×25G），CMACE4_X0Y0，refclk 156.25MHz，usrclk 322.27MHz；**已实现完成、时序收敛（WNS>0、TNS=0）、生成 bitstream**（见 §8.1） |

## 5.8 板载其他接口（供平台扩展参考）

| 接口 | 器件/规格 | FPGA 连接 |
|---|---|---|
| 千兆以太网 | RTL8211F-CG，RGMII | PHY1_MDC/MDIO + RXD/TXD[3:0]、RXCK/TXCK、RXCTL/TXCTL（BANK66，LVCMOS18） |
| SD 卡 | MicroSD（SPI + SD 模式） | SD_CD/CLK/CMD/D0~D3（BANK84） |
| MIPI CSI | 4-lane（IMX415 摄像头） | MIPI_CLK + LAN0~3（BANK65/66） |
| 40PIN | 2.54mm 40 针，IO 34 路 | BANK86/87（**3.3V 固定**，17 对差分全等长 2880 mil） |
| PCIe | 3.0 x4（x8 槽型） | GTY BANK224（4×RX/TX），REFCLK 100MHz |
| 电源 | 12V（10–14V）输入 / PCIe 供电可选 | 过流/防反接/TVS；按键开关 |

---

# 6. FMCOMMS2 / AD9361 接口

## 6.1 文档与参考工程（HWI-05）— L2

| 文档 | 版本/内容 | 位置 | 状态 |
|---|---|---|---|
| FMC_AD936X 硬件手册（原理图 5 页） | 2025-05-13 | `D:\Baidu_disk_download\FMC_AD936X资料\硬件资料\FMC_AD936X.pdf`（提取文本 `docs/hardware/source/FMC_AD936X_hardware.txt`） | ✅ |
| 参考 PL 工程（ADI HDL fmcomms2/zc706） | Vivado 2021.1 | `D:\Baidu_disk_download\FMC_AD936X资料\ZC706-LPC-Vivado2021.1历程\FMC_AD936X_PL.zip`（已解压至 `fpga/vendor_reference/FMC_AD936X_PL/`） | ✅ |
| 参考 PS 工程（Vitis，Zynq PS 应用） | Vitis/SDK | `FMC_AD936X_PS.zip`（已解压至 `fpga/vendor_reference/FMC_AD936X_PS/`） | ✅ |
| AD9361 datasheet / register map | `[待下载 ADI 官方文档]` | ADI | 待收集 |

> 🟡 **芯片型号（OQ-9，高置信度待复核）**：原理图标注 **AD936X**，未标具体型号；但商家参考工程配置为 **AD9361**（PS 工程 `AD936X/src/app_config.h`：`AD9361_DEVICE=1`，`AD9364_DEVICE=0`，`AD9363A_DEVICE=0`；`main.c` 默认 RX 合成器起始频率 70 MHz）→ 高度疑似 **AD9361（70 MHz–6 GHz，FM 可用）**。建议开盖看丝印最终确认。

## 6.2 FMC 引脚使用与电源兼容（HWI-03 / HWI-04）— L2

载板侧 FMC 资源（§5.4）与 FMC_AD936X（LPC 子卡）的对应关系：

- FMC_AD936X 为 **FMC-LPC** 子卡 → 插入本板 **FMC-HPC** 连接器（物理兼容，HPC 包含 LPC 信号）。
- 子卡使用 LA 信号（DATA_CLK/FB_CLK/RX_D0~5/TX_D0~5/FRAME 等差分）+ SPI + 控制（ENABLE/EN_AGC/TXNRX/CTRL_IN~OUT）+ I2C（FMC_SCL/SDA）→ 对应载板 BANK66/67（VADJ1）。RESETB 单独位于 J1-D31/FMC-TDO，载板未作为 FPGA GPIO 引出，依靠子卡 10 kΩ 上拉。
- ✅ **VADJ 兼容性（OQ-1 已解决，原理图直接证据）**：子卡原理图显示 **VDD_INTERFACE 直接连接 FMC_ADJ（即 FMC VADJ）**，数字接口电平随 VADJ。本板 **VADJ1=1.8V** → LVDS/控制信号用 **LVDS_18 / LVCMOS18** 约束即可（LVDS 为标准差分电平，1.8V VCCO 完全支持）。参考实现差异：ADI 官方 ZC706 参考约束用 **LVDS_25**（其 LPC VADJ=2.5V），移植到本板时需改为 **LVDS_18**。仅当 VADJ1 被改为 1.2V 时不可用（低于 AD936X 接口供电下限约 1.71V）。
- 子卡电源：12V（VCC_12V）→ TPS82130 → 1.6V 中间轨 → 2× TPS7A9201 → **1V3_A / 1V3_B**（AD936X 模拟/数字 1.3V）；3.3V 供 PGA 放大器（VCC_3V3）。
- FMC_AD936X 不需要载板 GTY → 8 路 FMC GTY 本阶段闲置。

## 6.3 AD936X 数字接口模式（HWI-06）— L2

| 字段 | 值（原理图） |
|---|---|
| 接口标准 | **LVDS（全差分）** |
| 数据线 | **RX_D0~5（P/N）、TX_D0~5（P/N）**（6 位宽，与 ADI hdl LVDS 6-bit 模式一致） |
| 时钟 | DATA_CLK_P/N、FB_CLK_P/N（FB 时钟用于采样对齐） |
| 帧信号 | RX_FRAME_P/N、TX_FRAME_P/N |
| 数据速率模式 | DDR（ADI hdl zc706 fmcomms2 工程默认配置，采样率以寄存器冻结） |
| 采样率（第一阶段） | `[候选：20 / 40 / 61.44 MSPS，待冻结]` |
| I/Q 位宽 | 12 bit（AD936X 原生） |
| 逻辑电平 | **1.8V 域**（VDD_INTERFACE = FMC_ADJ = 载板 VADJ1 1.8V；约束用 LVDS_18/LVCMOS18；ADI ZC706 参考为 LVDS_25，移植时改） |
| 引脚兼容性 | 与 ADI 官方 FMCOMMS2 LVDS 接口兼容（商家即用 ADI hdl fmcomms2/zc706 工程验证；参考 `system_constr.xdc`：rx/tx_data[0..5]、rx_clk、rx_frame、tx_clk、tx_frame 全差分） |

## 6.4 参考时钟（HWI-07）— L2

| 字段 | 值 |
|---|---|
| AD936X REFCLK | **板载 40 MHz 晶振（Y1，40M）→ CLK_IN**（原理图页 4） |
| 载板 FMC_CLK0/1 | **不需要**（子卡自带晶振）；FMC_CLK0/1（H23/H24、B19/B20）保留未用 |
| 备选 | 如需外部参考（未来同步扩展），可评估改用 FMC_CLK 驱动 |

## 6.5 SPI 控制

- AD936X SPI（SPI_DI/DO/CLK/ENB）经 FMC 连接（原理图页 4：SPI_DI J4、SPI_CLK J5、SPI_EN# K6、SPI_DO L6 脚位）。
- SPI 时序固定为 **Mode 1（CPOL=0、CPHA=1）**、MSB first、SCLK ≤ 10 MHz，与 ADI no-OS 驱动一致。
- FMC 针位：SPI_ENB/CLK = J1-D26/D27 = LA26 P/N（FPGA A19/A20）；SPI_DI/DO = J1-C26/C27 = LA27 P/N（FPGA F18/F19）。
- 初始化脚本来源：ADI no-OS / 官方参考驱动（Master Spec §34）；商家 PS 工程（Vitis）可作参考。
- FPGA UART 控制面提供 `SPI_TX <decimal24>`、`SPI_GO`、`SPI_RX` 原始事务命令，
  供主机侧 no-OS 初始化/轮询使用；禁止以未经实物读回验证的固定写表替代官方流程。

## 6.6 RX/TX 安全（Master Spec §2.2）

- TX1 / TX2 硬件保留但**本版本禁用**；
- AD936X 初始化默认关闭 TX chain（寄存器配置冻结项，见 §13）；
- FPGA 控制逻辑不接受普通模式下的 TX enable（子卡 TXNRX/ENABLE 控制线默认置 RX 态）；
- 上电默认状态必须为 RX-only。

## 6.7 RF 前端资格（HWI-15 / HWI-16，Gate D）

| 检查项 | 值/结果 | 状态 |
|---|---|---|
| 芯片型号确认（AD9361/9364 支持 70M–6GHz；**AD9363 不支持 FM**） | 🟡 商家工程配置 **AD9361**（app_config.h + main.c 70MHz 起始）→ FM 可行；**建议实物丝印复核** | L2（配置证据）/ 待实物 |
| 前端拓扑 | 4× TC1-1-13M+ balun（4.5M–3GHz）+ 2× PGA-102+ 放大器 + 330nH/18pF 匹配，RX1A/RX2A SMA 输入 | L2（拓扑）/ L0（实测） |
| FM 频段 88–108 MHz 实际灵敏度/噪声底 | `[待 RF qualification]` | L0 |
| 是否需要外部 LNA / 滤波器 / balun | `[待评估]` | L0 |
| 天线频率范围覆盖 FM | `[待确认]` | L0 |
| 连接器与线缆匹配 | `[待确认]` | L0 |

> RF 前端适配问题不允许推翻数字后端架构（Master Spec §4.2）。

---

# 7. 时钟体系汇总（Master Spec §28）

| 时钟域 | 来源 | 频率 | 用途 | 状态 |
|---|---|---|---|---|
| FPGA 系统时钟 | SYS_CLK（T24/U24） | **200 MHz 差分** | 主逻辑 / DDR 参考 | L2 |
| DDR4 时钟 | MIG（由 200MHz 生成） | **2666 Mbps**（UI 333 MHz） | DDR4 | L2 |
| QSFP28 GT 时钟 | GT_CLK156P25（V7/V6） | **156.25 MHz** | 100G（4×25G） | L2 |
| PCIe GT 时钟 | PCIE_CLK（AB7/AB6） | **100 MHz** | PCIe x4 | L2 |
| FMC GT 时钟 | FMC_GBTCLK0/1（M2C） | 子卡提供 | FMC GTY（本阶段闲置） | L2 |
| HD 单端晶振 | 板载（预留） | `[待确认]` | 备用 | L1 |
| AD936X REFCLK | 板载 40 MHz 晶振（Y1） | **40 MHz** | AD936X 参考时钟 | L2 |
| AD936X data clock | 子卡 DATA_CLK（LVDS，由 40MHz 倍频产生） | 由采样率决定 | IQ 采集 | L2 |
| UART/控制时钟 | FT2232 / 逻辑 | 待冻结 | 控制面 | L1 |

CDC 登记：每个跨域桥接在实现阶段于附录 A 登记。

---

# 8. 100GbE 数据面（HWI-10 / HWI-11 / HWI-14）

| 项 | 值 |
|---|---|
| 硬件路径 | QSFP28 光模块（如 Intel CWDM4）→ GT BANK225 4×25G |
| GT 参考验证 | IBERT 4×25G（Vivado 2021.1 / 2023.1 两版均通过） |
| CMAC | ✅ **用户自有参考：`F_smart_KU5P_stage3_100g_v1`**（cmac_usplus 3.1，CAUI4 4×25G，CMACE4_X0Y0） |
| 1G RGMII 参考 | KU5P_DEMO `07_UDP_STACK`（可作以太网协议栈开发参考） |
| 主机 ConnectX-4 | **MCX455A-ECAT**（ConnectX-4 VPI，100GbE 单口 QSFP28，PCIe3.0 x16）——与 FPGA QSFP28 **直连（DAC/光模块）** |
| 对接链路 | FPGA QSFP28 ↔ ConnectX-4 QSFP28：**100G QSFP28 DAC 铜缆** 或 100GBASE-SR4/CWDM4 光模块 + 光纤 |
| 主机驱动 | Windows 11 需 **WinOF-2**（mlx5）驱动；VPI 卡需 `mlxconfig` 设 **LinkType=Ethernet**（若当前为 IB 模式）；固件版本 `[待主机实测]` |
| 测试 IP / MAC | `[待冻结]`（出厂 ETH 默认 IP 192.168.1.10 仅用于 1G 回环） |
| 带宽评估 | 61.44 MSPS×16bit×2 ≈ 246 MB/s ≪ 100G 链路（Master Spec §10.2） |

Gate B 验收：原厂 IBERT 已验证 GT；**用户 CMAC 100G 工程已时序收敛并出 bitstream**，进一步要求 100G Ethernet 端到端（与 ConnectX-4 实测）。

## 8.1 现成平台资产：F_SMART KU5P Stage3 100G（用户工程）

`D:\workspace\xilinx\F_smart_KU5P_stage3_100g_v1\`（另有 `_fusion` 变体）是用户已有的 **KU5P 完整基座工程**，对 LR 的 DDR4 / 100G / AXI 骨架可直接复用：

| 项 | 值 |
|---|---|
| 器件 | xcku5p-ffvb676-2-i（Vivado 2021.1） |
| CMAC | cmac_usplus 3.1，**CAUI4（100G 4×25G）**，CMACE4_X0Y0，refclk 156.25 MHz（QSFP28 GT225），usrclk 322.27 MHz |
| AXIS 数据面 | **512-bit TDATA（64B tkeep）@ 322.27 MHz**，tlast/tuser=1（LR 网络包封装需在此位宽上打包） |
| DDR4 | MIG，DDR4-2666（UI 333 MHz，PHY 2666.7 MHz），32-bit，2GB |
| 数据通路 | AXI fabric（实际 225 MHz）+ MIG 时钟转换 + CMAC TX/RX CDC FIFO |
| 控制 | JTAG AXI（`jtag_axi`）+ 板载 LED/按键 + QSFP 控制（RESETL W12 / LPMODE W14 / MODSELL W13） |
| 实现状态 | **impl 完成，bitstream 已生成（`runs\impl_1\system_wrapper.bit`）；时序收敛（WNS>0、TNS=0，见 `system_wrapper_timing_summary_routed.rpt`）** |
| 约束文件 | `srcs\constrs_1\new\`：`stage3_100g_board_io.xdc`（QSFP refclk/控制）、`board_ddr4_pins.xdc`（DDR4 全引脚）、`board_io.xdc`（PCIe PERST/LED） |
| 硬件测试 | `jtag_tests\`（fsmart_cmac_restore.tcl 等 JTAG 硬件测试脚本） |
| 对 LR 的意义 | 100G 数据面 + DDR4 ring 的**已验证起点**；LR 只需在其上替换/挂接 RF 采集与 DSP 流 |

> ⚠️ 备注：DDR4 注释处型号写 MT40A512M16HA-075E，手册 V1.2 为 MT40A512M16LY-062E——以手册为准，实现时以 MIG 实测为准。

---

# 9. DDR4 接口细则（HWI-09）

| 项 | 值 |
|---|---|
| MIG 参考 | KU5P_DEMO `06_DDR_AXI`（ddr4_0 IP）；XDMA 工程 DDR4 2666 配置 |
| 拓扑 | 2×16-bit 单 rank，32-bit 总线，2GB |
| 数据速率 | 2666 Mbps（MIG UI 333 MHz） |
| 地址映射/保留区 | `[待 MIG 生成后冻结]` |
| Ring buffer 可用容量 | 约 2GB 减保留区（Master Spec §9.3 量级估算适用） |
| 与 100G 数据面带宽余量 | 充足（见 §8） |

---

# 10. 电源与 Gate A 安全检查

| 检查项 | 结果 | 状态 |
|---|---|---|
| 载板供电 | 12V（10–14V）/ PCIe 供电可选；过流/防反接/TVS | L2 |
| FMC VADJ1 与 FMCOMMS2 IO 电平匹配 | ✅ **1.8V 匹配（OQ-1 已解决）**：ADI 官方 ZC706 配置即 VADJ=1.8V+FMCOMMS2 | **L2** |
| 上电顺序符合 FMCOMMS2 要求 | `[待确认]` | L0 |
| TX 通路无使能路径（默认断开） | `[待冻结]` | L1 |
| FMC GTY（8 路）本阶段不使用 | 闲置、不约束 | — |
| 散热 | 板载散热片 + 两线风扇（无 PWM） | L2 |

> Gate A 通过条件：上表全部 CONFIRMED 且完成一次安全上电验证（含 FMCOMMS2 挂载）。

---

# 11. 门禁映射

| Gate | 内容 | 依赖条目 | 前置文档 |
|---|---|---|---|
| Gate A | Board Safety | HWI-01/03/04/05 + §10 | 本文档 |
| Gate B | 100G Baseline | HWI-10/11/14（IBERT 已过；CMAC 自建后端到端） | 本文档 |
| Gate C | FMCOMMS2 Baseline | HWI-05/06/07 + §6 | 本文档 |
| Gate D | RF FM Qualification | HWI-15/16 + §6.7 | 本文档 + RF 测试记录 |
| Gate E | Stream Baseline | 协议层文档（后续 Rev） | LR Protocol Spec |

---

# 12. 开放问题与风险

| ID | 问题/风险 | 影响 | 处置 |
|---|---|---|---|
| OQ-1 | ~~FMCOMMS2 VADJ 兼容性~~ → **已解决：VADJ1=1.8V 直接可用**（ADI 官方 ZC706 同配置；KC705 用 2.5V 亦可改 1.8V） | 风险解除 | 保持 VADJ1=1.8V；实物上电时复核 FMCOMMS2 数字接口 |
| OQ-2 | FMC_AD936X（LPC）插入 HPC 连接器的机械兼容 | 物理装配 | 确认导向/插针后实物试插 |
| OQ-3 | AD936X 板级匹配与 FM 频段不一致 | Gate D | RF 前端适配（§6.7） |
| OQ-4 | ~~无 CMAC 100G Ethernet 参考~~ → **已解决：用户 F_SMART KU5P stage3 100G 工程可直接复用** | Gate B 风险解除 | 以该工程为起点，替换为 LR 数据面 |
| OQ-5 | ~~ConnectX-4 驱动/配置未确认~~ → **已解决：MCX455A-ECAT（ConnectX-4 VPI 100GbE 单口 QSFP28）** | 风险解除 | Windows 需 WinOF-2 驱动；VPI 卡确认 LinkType=Ethernet；固件版本待主机实测 |
| OQ-6 | ~~AD9361 REFCLK 来源~~ → **已解决：板载 40 MHz 晶振（Y1）** | — | 无需载板时钟 |
| OQ-7 | DDR4 MIG IP 版本与参数 | 实现细节 | 以 KU5P_DEMO 工程为起点生成 |
| OQ-8 | 板载 4 键中 KEY1 与 demo 复位脚复用 | 按键功能设计 | 按键映射冻结时避开复位需求或确认电平 |
| **OQ-9** | ~~FMC_AD936X 芯片具体型号~~ → **已解决：用户确认 AD9361**（70M–6GHz，FM 可行） | 关闭 | — |

---

# 13. 冻结记录（Sign-off Log）

| 日期 | Rev | 冻结/确认条目 | 依据 | 签字 |
|---|---|---|---|---|
| 2026-08-27 | 0.2 | HWI-01~04/08~13 确认（L2） | 厂商资料 + 现有工程 | — |
| 2026-08-27 | 0.2 | HWI-10/11 确认（L2）：100G GT/CMAC 参考 | IBERT 4×25G + F_SMART stage3 100G 工程（时序收敛） | — |
| 2026-08-27 | 0.2 | OQ-1 解决：VADJ1=1.8V 与 FMCOMMS2 匹配 | 子卡原理图 VDD_INTERFACE=FMC_ADJ + ADI 载板支持矩阵（ZC706=LVDS_25 / 1.8V 亦支持） | — |
| 2026-08-27 | 0.2 | HWI-05/06/07 确认（L2）：RF 子卡 FMC_AD936X 资料与接口 | 商家原理图 + ADI hdl fmcomms2/zc706 工程（LVDS 6-bit，REFCLK 40MHz 板载） | — |
| 2026-08-27 | 0.2 | HWI-14 确认（L2）：MCX455A-ECAT（ConnectX-4 VPI 100GbE 单口 QSFP28） | 用户确认 + Mellanox 规格 | — |
| 2026-08-27 | 0.2 | OQ-9 关闭：用户确认芯片为 AD9361 | 用户确认 | — |
| — | — | TX 禁用寄存器配置 | 待 AD9361 文档 | — |

（L3 FROZEN 条目在此登记；任何变更需新增记录并升 Rev。）

---

# 14. 参考文档

**厂商资料（RK-XCKU5P-F V1.2，位于 `D:\Data\Baidu_disk_download\9.RK-XCKU5P-F开发板网盘资料`）**
- `1_用户手册\RK-XCKU5P-F V1.2 开发板用户手册.pdf`
- `2_硬件资料\RK-XCKU5P-F V1.2原理图.pdf`、`RK-XCKU5P-F V1.2管脚定义.xls`、`RK-XCKU5P-F V1.2等长说明.xls`、`位号&尺寸图.pdf`
- `3_source_code\KU5P_DEMO.zip`（本机已解压至 `D:\workspace\xilinx\ku5p\KU5P_DEMO\`）
- `5_出场相关\`（出厂 bit、IBERT、测试工具）

**现有工程（`D:\workspace\xilinx`）**
- `ku5p\KU5P_DEMO\01_LED ~ 13_IMX415_FH1159`（引脚约束见各 `Constraint\Phy_Pin.xdc`）
- `ku5p\IBERT_100G_2021_1\`、`ku5p\IBERT_100G_ADV_2023_1\`（100G GT 验证）
- `ku5p\image_ku5p\`（出厂工程，整板约束 `srcs\constrs_1\new\`）
- `ku5p\KU5P_DEMO\06_DDR_AXI\`（DDR4 2666 MIG 参考）
- **`F_smart_KU5P_stage3_100g_v1\`（100G CMAC CAUI4 完整平台，时序收敛 + bitstream；`_fusion` 为变体）**

**RF 子卡资料（FMC_AD936X，商家提供，`D:\Baidu_disk_download\FMC_AD936X资料\`）**
- `硬件资料\FMC_AD936X.pdf`（原理图 5 页，提取文本见 `docs/hardware/source/FMC_AD936X_hardware.txt`）
- `ZC706-LPC-Vivado2021.1历程\FMC_AD936X_PL.zip`（ADI HDL fmcomms2/zc706，Vivado 2021.1；已解压至 `fpga/vendor_reference/FMC_AD936X_PL/`）
- `ZC706-LPC-Vivado2021.1历程\FMC_AD936X_PS.zip`（Vitis PS 应用；已解压至 `fpga/vendor_reference/FMC_AD936X_PS/`）

**ADI（待收集）**
- AD9361 datasheet / register map（官方文档）
- 已核实结论（供参考）：[FMCOMMS2 wiki hardware](https://wiki.analog.com/resources/eval/user-guides/ad-fmcomms2-ebz/hardware) · [EZ Q&A 80335（IO Voltage）](https://ez.analog.com/rf/wide-band-rf-transceivers/design-support/f/q-a/80335/ad-fmcomms2-ebz-ad9361-io-voltage) · [AD9361 datasheet](https://www.jakelectronics.com/pdf/datasheets/analogdevicesinc-ad9361bbcz-datasheets-7810) · [社区：rk-xcku5p-f-v1.2 + AD9361](https://github.com/tommythorn/rk-xcku5p-f-v1.2)

**提取文本（本文档配套，`docs/hardware/source/`）**
- `RK-XCKU5P-F_V1.2_user_manual.txt`、`_schematic.txt`、`_pin_definition.txt`、`_length_matching.txt`、`_silkscreen.txt`

---

# 附录 A：XDC 约束登记表（实现阶段维护）

| 网络/接口 | 约束类型 | 值 | 状态 |
|---|---|---|---|
| SYS_CLK（T24/U24） | create_clock | 200 MHz，DIFF_SSTL12 | 参考 demo 已用 |
| GT_CLK156P25（V7/V6） | create_clock | 156.25 MHz | 参考 IBERT |
| PCIE_CLK（AB7/AB6） | create_clock | 100 MHz | 参考出厂约束 |
| FPGA_UART_RX/TX（AD13/AC14） | PACKAGE_PIN/IOSTANDARD | LVCMOS33 | 参考 demo |
| LED1~4 / KEY1~4 | PACKAGE_PIN/IOSTANDARD | LVCMOS33 | 参考 demo |
| FMC LA（BANK66/67） | IOSTANDARD | LVCMOS18（VADJ1=1.8V） | 参考出厂 FMC.xdc |
| DDR4（BANK64/65） | MIG 生成 | 2666 Mbps | 参考 06_DDR_AXI |

# 附录 B：版本历史

| Rev | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-08-27 | 草稿模板；全部条目 L0 |
| 0.2 | 2026-08-27 | 取得厂商资料并解析归档；板级条目升 L2；新增与 Master Spec 差异说明、OQ-1 VADJ 风险、IBERT/CMAC 现状 |
| 0.2b | 2026-08-27 | 新增 FMC_AD936X 子卡资料（HWI-05/06/07 升 L2：LVDS 6-bit、REFCLK 40MHz 板载、VDD_INTERFACE=FMC_ADJ）；OQ-1 解决；新增 OQ-9（芯片型号确认）；登记 F_SMART 100G 平台资产 |
| 0.2c | 2026-08-27 | HWI-14 升 L2（ConnectX-4 VPI MCX455A-ECAT，100GbE 单口 QSFP28，与 FPGA 直连）；OQ-5 关闭；OQ-9 关闭（用户确认 AD9361） |

---

> **本版结论**：KU5P 板级接口已全部确认（L2），100G CMAC 数据面 + DDR4 已有用户工程基座（时序收敛），FMCOMMS2 VADJ 兼容性（OQ-1）已解决，RF 子卡 FMC_AD936X 资料已归档且芯片确认为 **AD9361**（OQ-9 关闭），主机侧 ConnectX-4 = **MCX455A-ECAT（100GbE 单口 QSFP28）**（HWI-14 / OQ-5 关闭）→ **FPGA QSFP28 与主机卡 QSFP28 直连**。剩余开放：OQ-2（LPC 卡插 HPC 实物试插）、HWI-15/16（天线/线缆）。下一步：① 实物上电验证 Gate A/C；② 100G 端到端（Gate B）；③ 发布 Rev 0.3；④ 起草 LR Protocol Spec。
