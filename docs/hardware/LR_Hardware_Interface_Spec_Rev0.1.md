# LR Hardware Interface Specification Rev 0.1

> **Project:** Lightning Receiver
> **Abbreviation:** LR
> **Document Type:** Hardware Interface Specification (HIS)
> **Revision:** Rev 0.1 — Draft for Input Collection
> **Status:** OPEN（本版仅为模板与占位，所有条目尚未 FROZEN）
> **Date:** 2026-08-27
> **Parent Document:** `Lightning_Receiver_Master_Spec_Rev0.1`
> **Gate Dependency:** 本文档是 Gate A（Board Safety）、Gate B（100G Baseline）、Gate C（FMCOMMS2 Baseline）、Gate D（RF Qualification）的前置输入文档
> **Filing Path:** `docs/hardware/`

---

# 1. 目的与范围

本文档按 `Lightning_Receiver_Master_Spec_Rev0.1` §37 的清单，冻结 LR 第一版 bitstream 与 Windows Host 所依赖的**全部板级硬件接口**，包括：

- KU5P 开发板（FPGA part、板级时钟、DDR4、FMC-LPC、UART、按键、100G GT）；
- AD-FMCOMMS2 / AD9361（FMC 引脚、数字接口模式、参考时钟、SPI、RX/TX 安全）；
- 100GbE 数据面（CMAC/GT 配置、ConnectX-4 主机侧环境）；
- 天线与 RF 前端链路（FM 频段资格）。

**冻结规则**：本文档只登记「来自官方资料或实测」的数据，禁止猜测。任何条目进入 FROZEN 后，变更必须走 revision，不允许隐式修改。

---

# 2. 冻结状态定义

| Level | 名称 | 含义 |
|---|---|---|
| L0 | OPEN | 信息缺失，无法定稿，禁止用于实现 |
| L1 | DRAFT | 已有数据，但未与官方文档/实测核对 |
| L2 | CONFIRMED | 已与厂商文档、原理图或实测结果一致 |
| L3 | FROZEN | 已写入 XDC / 约束 / 驱动 / 软件，变更需走 revision |

条目状态汇总表（随资料输入持续更新）：

| 条目 | 内容 | 当前状态 |
|---|---|---|
| HWI-01 | KU5P 板卡型号与原理图版本 | L0 OPEN |
| HWI-02 | FPGA exact part | L0 OPEN |
| HWI-03 | FMC-LPC 引脚映射 | L0 OPEN |
| HWI-04 | FMC VADJ / IO bank 电压 | L0 OPEN |
| HWI-05 | FMCOMMS2 原理图 / user guide | L0 OPEN |
| HWI-06 | AD9361 数字接口模式 | L0 OPEN |
| HWI-07 | AD9361 参考时钟 | L0 OPEN |
| HWI-08 | KU5P 板级时钟 | L0 OPEN |
| HWI-09 | DDR4 拓扑 | L0 OPEN |
| HWI-10 | 原厂 100G reference project | L0 OPEN |
| HWI-11 | CMAC/GT 配置 | L0 OPEN |
| HWI-12 | UART 实现 | L0 OPEN |
| HWI-13 | 板载按键 pinout | L0 OPEN |
| HWI-14 | ConnectX-4 驱动/配置 | L0 OPEN |
| HWI-15 | 天线型号/频率/连接器 | L0 OPEN |
| HWI-16 | 同轴线/转接头 | L0 OPEN |

---

# 3. 硬件清单（Inventory）

| 项目 | 型号/规格 | 序列号/版本 | 来源 | 状态 |
|---|---|---|---|---|
| FPGA 开发板 | `[TODO: 厂商与型号]` | `[TODO]` | 原厂资料 | L0 |
| RF 子卡 | AD-FMCOMMS2 | `[TODO]` | ADI | L0 |
| 主机网卡 | Mellanox ConnectX-4 100G | `[TODO: 型号/固件版本]` | 主机 `mlxfwmanager -q` | L0 |
| 天线 | `[TODO: 型号、频率范围、连接器]` | `[TODO]` | 实物 | L0 |
| 同轴线/转接头 | `[TODO]` | `[TODO]` | 实物 | L0 |
| 主机 | Windows 11 x64 `[TODO: build/version]` | — | — | L0 |

---

# 4. 待收集资料清单（映射 Master Spec §37）

| # | 资料 | 目的 | 来源 | 状态 |
|---|---|---|---|---|
| 1 | KU5P 板卡准确型号与 schematic | HWI-01 | 原厂/卖家 | 待收集 |
| 2 | FPGA exact part | HWI-02 | 原厂 | 待收集 |
| 3 | FMC-LPC pin mapping | HWI-03 | 原厂 schematic / 板卡 user guide | 待收集 |
| 4 | FMC VADJ 与 IO bank voltage | HWI-04 | 原厂 schematic | 待收集 |
| 5 | FMCOMMS2 schematic / user guide | HWI-05 | ADI (analog.com) | 待收集 |
| 6 | AD9361 digital interface mode | HWI-06 | ADI / 设计文件 | 待收集 |
| 7 | AD9361 reference clock | HWI-07 | ADI / 板卡 | 待收集 |
| 8 | KU5P board clocks | HWI-08 | 原厂 schematic | 待收集 |
| 9 | DDR4 exact topology | HWI-09 | 原厂 schematic / MIG 参考 | 待收集 |
| 10 | 原厂 100G reference project | HWI-10 | 原厂 | 待收集 |
| 11 | 100G CMAC/GT configuration | HWI-11 | 原厂参考工程 | 待收集 |
| 12 | UART implementation | HWI-12 | 原厂 schematic | 待收集 |
| 13 | board button pinout | HWI-13 | 原厂 schematic | 待收集 |
| 14 | ConnectX-4 驱动/配置 | HWI-14 | 主机实测 | 待收集 |
| 15 | 天线型号、频率范围、连接器 | HWI-15 | 实物/规格书 | 待收集 |
| 16 | 同轴线/转接头 | HWI-16 | 实物 | 待收集 |

> 收集到资料后，逐项填写下文 §5–§10，并将状态提升为 L1/L2。

---

# 5. KU5P 开发板接口

## 5.1 FPGA Exact Part（HWI-02）

| 字段 | 值 |
|---|---|
| Part Number | `[TODO: 例如 XCKU5P-2FFVA676E]`（禁止猜测，以原厂为准） |
| Speed Grade | `[TODO]` |
| Package | `[TODO]` |
| 状态 | L0 |

## 5.2 板级时钟（HWI-08）

| 用途 | 频率 | 引脚/网络 | 来源 | 状态 |
|---|---|---|---|---|
| FPGA 主时钟 | `[TODO]` | `[TODO]` | schematic | L0 |
| 100G GT refclk | `[TODO]` | `[TODO]` | schematic | L0 |
| DDR 参考（若有） | `[TODO]` | `[TODO]` | schematic | L0 |
| 其他 | `[TODO]` | `[TODO]` | schematic | L0 |

## 5.3 DDR4（HWI-09）

| 字段 | 值 |
|---|---|
| 控制器 | MIG / 原厂参考（待定） |
| 拓扑 | `[TODO: 单 rank/双 rank、片选、地址映射]` |
| 容量 | 约 2 GB（需确认） |
| 数据位宽 | `[TODO]` |
| 速率等级 | `[TODO: DDR4-2400 等]` |
| ECC | `[TODO: 有/无]` |
| 状态 | L0 |

## 5.4 FMC-LPC 电气（HWI-03 / HWI-04）

| 字段 | 值 |
|---|---|
| FMC VADJ | `[TODO: 例如 1.8V / 2.5V]` |
| 相关 IO bank | `[TODO]` |
| FMC_CLK0 / FMC_CLK1 方向与频率 | `[TODO]` |
| FMC-LPC 引脚映射表 | `[TODO: 附原厂 FMC 引脚对照表]` |
| 状态 | L0 |

> Gate A 要求：VADJ 与 FMCOMMS2 的 IO 电平必须完全匹配后方可上电。

## 5.5 UART（HWI-12）

| 字段 | 值 |
|---|---|
| 板载实现 | `[TODO: USB-UART 桥芯片型号]` |
| 主机侧设备名/VID-PID | `[TODO]` |
| 波特率 | `[TODO: 默认 115200?]` |
| 流控 | `[TODO]` |
| FPGA 侧引脚/网络 | `[TODO]` |
| 状态 | L0 |

## 5.6 板载按键与 LED（HWI-13）

| 按键 | 原理图网络 | 有效电平 | 建议映射（待体验后冻结） |
|---|---|---|---|
| 按键 1 | `[TODO]` | `[TODO]` | Previous Station |
| 按键 2 | `[TODO]` | `[TODO]` | Next Station |
| 按键 3 | `[TODO]` | `[TODO]` | Play/Pause |
| 按键 4 | `[TODO]` | `[TODO]` | Scan/Mode |

| LED | 网络 | 含义 | 状态 |
|---|---|---|---|
| `[TODO]` | `[TODO]` | 状态指示（可选） | L0 |

## 5.7 100G 光口 / GT（HWI-10 / HWI-11）

| 字段 | 值 |
|---|---|
| 连接器 | `[TODO: QSFP28 / SFP28 / 光纤类型]` |
| GT 位置 | `[TODO]` |
| GT reference clock | `[TODO]` |
| 原厂 reference project 名称/版本 | `[TODO]` |
| CMAC 配置（100G 单通道 / 4×25G） | `[TODO]` |
| 回环/测试模式 | `[TODO]` |
| 状态 | L0 |

---

# 6. FMCOMMS2 / AD9361 接口

## 6.1 文档版本（HWI-05）

| 文档 | 版本 | 获取方式 | 状态 |
|---|---|---|---|
| FMCOMMS2 user guide | `[TODO]` | ADI | L0 |
| FMCOMMS2 schematic / design files | `[TODO]` | ADI | L0 |
| AD9361 datasheet / register map | `[TODO]` | ADI | L0 |

## 6.2 FMC-LPC 引脚使用（HWI-03）

| FMCOMMS2 信号 | FMC 引脚 | KU5P FPGA 引脚 | 方向 | 备注 |
|---|---|---|---|---|
| DATA_CLK | `[TODO]` | `[TODO]` | in | |
| RX_FRAME | `[TODO]` | `[TODO]` | in | |
| RX1_I / RX1_Q 数据线 | `[TODO]` | `[TODO]` | in | |
| TX_FRAME / TX 数据（预留） | `[TODO]` | `[TODO]` | out | TX 禁用 |
| SPI_CS / SPI_CLK / SPI_MOSI / SPI_MISO | `[TODO]` | `[TODO]` | — | |
| ENABLE / RESETB / ENSM 等 | `[TODO]` | `[TODO]` | — | |
| FMC_CLK0 / FMC_CLK1 | `[TODO]` | `[TODO]` | — | |

## 6.3 AD9361 数字接口模式（HWI-06）

| 字段 | 值 |
|---|---|
| 接口标准 | `[TODO: CMOS 或 LVDS]` |
| 数据速率模式 | `[TODO: SDR / DDR]` |
| 采样率（第一阶段） | `[TODO: 例 20 / 40 / 61.44 MSPS]` |
| I/Q 位宽 | `[TODO: 12 bit 原生]` |
| 数据/帧时序 | `[TODO]` |
| 状态 | L0 |

## 6.4 参考时钟与时钟域（HWI-07）

| 字段 | 值 |
|---|---|
| AD9361 REFCLK | `[TODO: 典型 40 MHz]` |
| 来源（板载 XO / FMC） | `[TODO]` |
| DATA_CLK 频率 | `[TODO]` |
| 状态 | L0 |

## 6.5 SPI 控制

| 字段 | 值 |
|---|---|
| SPI 模式 | `[TODO: 四线 / 参数见 ADI 参考]` |
| 地址位宽 | 寄存器 map 确认后冻结 |
| 初始化脚本来源 | ADI no-OS / 参考驱动 |

## 6.6 RX/TX 安全（Master Spec §2.2）

- TX1 / TX2：硬件连线保留但**本版本禁用**；
- AD9361 初始化默认关闭 TX chain（写入寄存器冻结项，见 §13 冻结记录）；
- FPGA 控制逻辑不接受普通模式下的 TX enable 命令；
- 上电默认状态必须为 RX-only。

## 6.7 RF 前端资格（HWI-15 / HWI-16，对应 Gate D）

| 检查项 | 值/结果 | 状态 |
|---|---|---|
| FMCOMMS2 在 88–108 MHz 的实际灵敏度/噪声底 | `[TODO: 待 RF qualification]` | L0 |
| 是否需要外部 LNA / 滤波器 / balun | `[TODO]` | L0 |
| 天线频率范围是否覆盖 FM | `[TODO]` | L0 |
| 连接器与线缆匹配 | `[TODO]` | L0 |

> RF 前端适配问题不允许推翻数字后端架构（Master Spec §4.2）。

---

# 7. 时钟体系汇总（Master Spec §28）

| 时钟域 | 来源 | 频率 | 用途 | 状态 |
|---|---|---|---|---|
| AD9361 data clock | FMCOMMS2 | `[TODO]` | IQ 采集 | L0 |
| FPGA fabric 主时钟 | 板载 | `[TODO]` | 逻辑 | L0 |
| DDR UI 时钟 | MIG | `[TODO]` | DDR4 | L0 |
| CMAC/100G 时钟 | GT refclk | `[TODO]` | 网络 | L0 |
| UART/控制时钟 | 板载/逻辑 | `[TODO]` | 控制面 | L0 |
| 外部参考（预留） | 10 MHz / PPS | — | 未来同步 | L0 |

CDC 登记：每个跨域桥接（async FIFO / 同步器 / 握手）在实现阶段在本文档附录 A 登记。

---

# 8. 100GbE 数据面接口（HWI-10 / HWI-11 / HWI-14）

| 项 | 值 |
|---|---|
| 原厂 reference project | `[TODO]` |
| CMAC / GT 配置 | `[TODO]` |
| AXIS 位宽与时钟 | `[TODO]` |
| 主机 ConnectX-4 型号 | `[TODO]` |
| 驱动版本 | `[TODO: 主机实测]` |
| 测试 IP / MAC 分配 | `[TODO]` |
| MTU 等参数 | `[TODO]` |
| 状态 | L0 |

Gate B 验收：原厂 reference bitstream 在现有 ConnectX-4 环境下可重复通信。

---

# 9. DDR4 接口细则（HWI-09）

| 项 | 值 |
|---|---|
| MIG IP 版本 / 配置 | `[TODO]` |
| 地址映射与保留区域 | `[TODO]` |
| Ring buffer 可用容量 | `[TODO]` |
| 与 100G 数据面的带宽余量 | `[TODO]` |
| 状态 | L0 |

---

# 10. 电源与 Gate A 安全检查

| 检查项 | 结果 | 状态 |
|---|---|---|
| FMC VADJ 与 FMCOMMS2 IO 电平匹配 | `[TODO]` | L0 |
| 上电顺序符合 FMCOMMS2 要求 | `[TODO]` | L0 |
| TX 通路无使能路径（默认断开） | `[TODO]` | L0 |
| 板卡供电裕量（100G + FMC） | `[TODO]` | L0 |
| 散热/温度监控（可获取时） | `[TODO]` | L0 |

> Gate A 通过条件：上表全部为 CONFIRMED 且完成一次安全上电验证。

---

# 11. 门禁映射

| Gate | 内容 | 依赖条目 | 前置文档 |
|---|---|---|---|
| Gate A | Board Safety | HWI-01/03/04/05 + §10 | 本文档 |
| Gate B | Vendor 100G Baseline | HWI-10/11/14 | 本文档 |
| Gate C | FMCOMMS2 Baseline | HWI-05/06/07 | 本文档 |
| Gate D | RF FM Qualification | HWI-15/16 + §6.7 | 本文档 + RF 测试记录 |
| Gate E | Stream Baseline | 协议层文档（后续 Rev） | LR Protocol Spec |

---

# 12. 开放问题与风险

| ID | 问题/风险 | 影响 | 处置 |
|---|---|---|---|
| OQ-1 | FMCOMMS2 板级匹配与 FM 频段不一致 | Gate D 可能受阻 | RF 前端适配方案（§6.7） |
| OQ-2 | 原厂 100G reference 与本板差异 | Gate B 周期 | 取得 reference project 后审计 |
| OQ-3 | DDR 拓扑资料缺失 | Ring buffer 容量不实 | 按原厂 schematic 冻结 |
| OQ-4 | ConnectX-4 驱动/配置不明确 | Host 接收不可靠 | 主机实测记录 |

---

# 13. 冻结记录（Sign-off Log）

| 日期 | Rev | 冻结条目 | 依据 | 签字 |
|---|---|---|---|---|
| — | — | — | — | — |

（FROZEN 条目在此登记；任何变更需新增记录并升 Rev。）

---

# 14. 参考文档

- `Lightning_Receiver_Master_Spec_Rev0.1`（本项目 Master Spec）
- ADI：FMCOMMS2 user guide / schematic / design files（版本待收）
- ADI：AD9361 datasheet / register map（版本待收）
- KU5P 开发板原厂：schematic / user guide / 100G reference project（待收）
- Mellanox：ConnectX-4 文档 / 驱动（待收）

---

# 附录 A：XDC 约束登记表（实现阶段维护）

| 网络/接口 | 约束类型（pin / clock / false path / async） | 状态 |
|---|---|---|
| `[TODO]` | | |

# 附录 B：版本历史

| Rev | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-08-27 | 草稿模板建立；全部条目 L0 OPEN，等待厂商资料输入 |

---

> **本版结论**：LR Hardware Interface Spec Rev 0.1 为「资料收集模板」。下一动作是取得 §4 所列 16 项资料，逐项填写并升状态，达到 Gate A–D 前置条件后发布 Rev 0.2（FROZEN baseline）。
