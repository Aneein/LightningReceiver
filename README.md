# Lightning Receiver (LR)

基于 **KU5P FPGA + AD-FMCOMMS2 (AD9361) + 100GbE + Windows 11** 的可扩展 FPGA SDR 接收与实时信号分析平台。

> 总纲文档：`D:\workspace\doc_file\Lightning_Receiver\Lightning_Receiver_Master_Spec_Rev0.1.md`
> 当前阶段：S2 全量设计已实现收敛（2026-08-31）→ **FM 收音机 Phase-1 源级完成（RTL + BD 已核验），待综合/实现**（2026-10-04）
> README 更新：2026-10-04

## 当前状态（2026-10-05）

| 项 | 状态 |
|---|---|
| S2 全量 BD + RTL | ✅ 源级核验通过（BD 0 ERROR / 0 CRITICAL WARNING） |
| 综合 / 实现 / bitstream | ✅ 2026-08-31 完成，**时序收敛**：WNS 0.063 ns、WHS 0.010 ns、0 失败端点 |
| bitstream | `fpga/LightningReceiver/LightningReceiver.runs/impl_1/system_wrapper.bit`（**FM 改动之前**的版本，寄存器 ID = `0x4C52_0001`；副本在 `_backup_pre_fm/fpga/bitstream_20260831/`）。工程里的 BD 已按 FM 版本重建，所以 `synth_1`/`impl_1` 现在处于过期状态 |
| FM Phase-1 RTL | ✅ 完成：DDR 音频录制 + 网络传输分路、自动搜台、前面板按键/LED、NCO 时基修复、CORDIC 鉴频；RTL 回归 **22/22 通过** |
| FM Phase-1 BD | ✅ `lr_bd_s2.tcl` 已接线，Vivado 2021.1 批处理重建并通过 `validate_bd_design`（0 ERROR / 0 CRITICAL WARNING，悬空标量输入 0） |
| FM Phase-1 综合 / 实现 | ✅ 2026-10-05 修复版：ID `0x4C52_0003`，WNS +0.081 ns、WHS +0.010 ns，已上板验证（收到 89.1 MHz，`ERR_STATUS=0`） |
| 上板 bring-up | ✅ 0003 版已上板：AD9361 初始化、收台、实时播放、Flutter App 均验证通过 |
| 航空波段 AM（ID `0x4C52_0005`） | ✅ 2026-10-05 上板：IQ 实测 48 kS/s，持续读取 187 KiB/s 无积压；FM ⇄ 航空连续切换 6 次，每次约 4.1 s，无错误；扫描和静噪工作正常；App 1.2.0。⏳ 还没收到真实塔台通话（室内 FM 天线）；120.000 / 121.500 / 125.000 MHz 上有本机杂散 |
| 开放 JTAG 桥 | ✅ 2026-10-05 已上板：`lr_jtagd` 不依赖 Vivado，读写、突发读、SPI、AD9361 初始化（4.1 s）、10 s 录音零丢样、App 自检 7/7 全部通过。清除 IP 缓存后重新生成的 bit 读出 ID `0x4C52_0004`，已复测通过。注意：BD 模块引用的 OOC 综合走 IP 缓存，而缓存键不包含 include 文件；如果只改了 `.vh`，综合前要先执行 `config_ip_cache -clear_output_repo` |

### FM 收音机 Phase-1

目标：FM 解调后的 48 kHz 单声道 PCM 写入 DDR 音频环形缓冲，主机经 JTAG AXI 读取，不依赖 CMAC 网络；同时保留网络音频传输，两条路径互不影响；板上 4 个按键 / 4 个 LED 提供收音机式操作（自动搜台），并与 Windows GUI 协同。

改动前的完整快照：`_backup_pre_fm/`（2026-10-04 20:33，rtl/sim/tools/xdc；`fpga/bitstream_20260831/` 为 FM 改动前已时序收敛的 bitstream 与 .ltx）。

#### 数据通路

```
AD9361 → raw_iq_router → dsp_router.m0 → dc_correction → ddc_mixer(内置 NCO) → CIC ÷320
       → fm_signal_meter(直通测量) → fm_demod(CORDIC) → audio_pipeline(48 kHz)
       → axis_fanout2_nb ─┬─ m0 → audio_pcm_packer → 音频 ring_buffer → axi_ic_0/S03 → DDR 0xFF00_0000
                          └─ m1 → u_net_mux.s0 → packetizer → CMAC
```

- **录制与传输互不影响**：`axis_fanout2_nb` 输入恒为 ready，每路有独立的使能、一级缓存和丢弃计数。CMAC 链路不通时只丢弃网络支路，DDR 录制和 FM 链路不受影响。
- **DDR 布局**：音频 ring 位于 `0xFF00_0000`，长 16 MiB（`0x8_0000` 个 32 B 字，约 174 s）；原始 IQ ring 让出这 16 MiB（`ring_size = 0x3F8_0000`），两者不重叠。
- **录制会话**：由 `AUDIO_CFG[16]` 控制。停止时 packer 用静音补齐到 32 B 边界，所以每段录音都从一个新的 ring 字开始；`AUDIO_REC_START` 记录本段的起点（单位与 `AUDIO_WR_WORDS` 相同）。没接 GUI 时用按键录下的内容，之后也能准确下载。主机读出的是 int16 小端单声道 PCM。
- **NCO 时基修复**：原来的 `dds_0` 按 225 MHz fabric 时钟自由运行，相位跟随样本到达时刻，抖动会变成相位噪声，在 10 MHz 频偏时约 0.3 rad。现在 NCO 移进 `ddc_mixer`，每个样本推进一次；`nco_phase_control` 按采样率 61.44 MHz 计算 PINC；`dds_0` 已删除。混频器增益 ×8，输出饱和。
- **CORDIC 鉴频**：`fm_demod` 改为 atan2(x[n]·conj(x[n−1]))，在 ±π 范围内线性。原来的叉积鉴频器在 192 kHz 采样率下，频偏超过 48 kHz 就会折返失真。输出定标为 Δφ/π·32768，正值表示正频偏。

#### 航空波段 AM（窄带 IQ 模式，设计 ID `0x4C52_0005`）

`AUDIO_CFG[19]=1` 时，`fm_demod` 不做鉴频，把 `{I,Q}` 原样传下去；`audio_pipeline` 对 I、Q 两路并行做 191 阶 FIR 和 4:1 抽取，跳过去加重，输出 48 kS/s 复基带，通带 ±15 kHz。`audio_pcm_packer` 在录制会话开始时锁存格式（`AUDIO_STATUS[3]`），之后每个复样本写成一个 `{Q,I}` 字，主机读出的是交错的 int16 I、Q，数据率 192 KB/s。网络支路这时传输的也是 IQ。

App 端（`app/lr_radio/lib/air_dsp.dart`）负责全部 AM 处理：
1. 信道 FIR：127 阶 Blackman，带宽 ±3/±4/±6 kHz 可选。
2. 包络检波。
3. 载波归一化 AGC：输出 = 包络 / 载波 − 1，音量不随信号强弱变化。
4. 300–3000 Hz 语音带通。
5. 静噪：用 FFT 估计噪底（信道外频点的第 20 百分位），信道 (S+N)/N 达到门限就打开，带 2 dB 滞回，关闭前延时 0.5 s。

本振固定在 127.9625 MHz，与每个 25 kHz 信道都相距 12.5 kHz，所以不会有信道落在直流陷波上；DDC 覆盖 118–137 MHz。航空模式下自动锁定板上按键，防止硬件搜台改动 DDC。频道扫描每个频道约 50 ms，遇到通话就停留，静默 3 秒后继续扫。录音保存解调后的音频，也可以同时保存一份 IQ 双声道 WAV。

#### 自动搜台（`fm_signal_meter` + `fm_seek`）

- **有台判据**：包络平坦度 R = N·Σp²/(Σp)²（p=|x|²，N=1024 个样本，约 5.3 ms）。FM 信号包络恒定，R≈1；噪声 R≈2。阈值默认 1.25（约 8 dB CNR），不受增益和节目内容影响。另有可选的最小功率门限。
- **落点**：在栅格上要求功率为局部最大，所以会停在电台中心，而不是旁边一格。起点本身也会先测量，但不会被选为结果。
- **扫描**：以起点为基准按步进前进（默认 100 kHz，±10 MHz），到边界后回绕；转完一圈无台则回到起点。每个频点约 6 ms，扫完整个范围约 1.3 s。搜台期间两路音频都静音，送出全零，时间轴不中断。
- **抢占规则**：搜台中收到任何按键或命令都会取消搜台并回到起点；主机写 `DDC_FREQ` 会立即停止搜台，并保留主机写入的值（GUI 优先）。
- **GUI 约定**：搜台只改 DDC 频偏，收听频率 = LO + `DDC_FREQ`。GUI 负责 AD9361 初始化和 LO，下发频率时应对齐到 100 kHz 栅格；建议 LO 偏开电台约 50 kHz，避免电台载波落在直流上被 `dc_correction` 削掉。

#### 前面板（`ui_panel`，仅 FM 模式）

| 键 | 短按 | 长按（≥0.5 s） |
|---|---|---|
| KEY1 | 向下搜台 | 手动 −100 kHz，按住每 150 ms 连发 |
| KEY2 | 向上搜台 | 手动 +100 kHz，按住每 150 ms 连发 |
| KEY3 | DDR 录制开/停 | — |
| KEY4 | 网络音频开/停 | — |
| KEY1+KEY2 同时按住 1 s | 频偏归零（回到 LO 中心） | |

- 搜台中按任意键会取消搜台。
- 主机写 `CONTROL[1]` 可锁定面板；锁定时或不在 FM 模式时，按任何键 4 个 LED 一起闪一下，不执行动作。
- 每次按键生效后，对应的 LED 反相 80 ms 作为确认。

| LED | 灭 | 常亮 | 慢闪 1 Hz | 快闪 4 Hz |
|---|---|---|---|---|
| LED1 系统 | 时钟未起 | 就绪 | DDR 未校准 | 有未清除的错误（写 `CONTROL[2]` 清除） |
| LED2 调谐 | 无 AD9361 采样 | 当前频点有台 | 当前频点无台 | 正在搜台（无台或到达边界时快闪 3 次） |
| LED3 录制 | 未录 | 录制中 | — | 录制中出现丢样（持续 1 s） |
| LED4 网络 | 网络音频关闭 | 已开且链路通 | 已开但链路不通 | 链路通但支路有丢弃 |

#### 寄存器（相对 FM 改动前）

| 偏移 | 名称 | 说明 |
|---|---|---|
| `0x008` | CONTROL | [0] DC 校正旁路；[1] 面板锁定；[2] 写 1 清除遥测粘滞错误（自清零） |
| `0x038` | AUDIO_CFG | [15:0] 增益 Q0.15；[16] DDR 录制（默认 0）；[17] 网络音频（默认 1）。复位值 `0x0002_7FFF` |
| `0x068` | AUDIO_STATUS | [0] ring FIFO 满；[1] AXI 写错误；[2] 录制中；[7:4] 网络支路丢弃数；[15:8] packer 丢弃数；[31:16] ring 溢出数（取代原 CMAC_STATUS） |
| `0x06C` | AUDIO_WR_WORDS | 已写入的 32 B 字总数 |
| `0x070` / `0x074` | AUDIO_RING_BASE / WORDS | `0xFF00_0000` / `0x0008_0000` |
| `0x078` | AUDIO_REC_START | 最近一次开始录制时的 `AUDIO_WR_WORDS` |
| `0x07C` | UI_STATUS | [3:0] 按键电平；[7:4] 最近动作码；[15:8] 动作计数（GUI 轮询此项发现面板改动）；[19:16] LED；[20] 面板锁；[21] FM 模式；[22] 有 ADC 采样 |
| `0x080` | SEEK_CTRL | 写：1 向上搜、2 向下搜、3 取消；读：[0] 忙；[1] 方向；[3:2] 结果（1 找到 / 2 无台 / 3 取消）；[4] 到达边界 |
| `0x084` | SEEK_CFG | [15:0] 步进 kHz（默认 100）；[31:16] ±范围 kHz（默认 10000） |
| `0x088` | SIG_POWER | 当前信道平均功率 |
| `0x08C` | SIG_QUALITY | [15:0] 平坦度 Q8.8；[16] 有台；[31:24] 测量块计数 |
| `0x090` | SEEK_THR | [15:0] 平坦度阈值 Q8.8（默认 `0x140`）；[31:16] 最小功率高 16 位（默认 0，不启用） |

`LR_REG_ID_VALUE = 0x4C52_0002`。`reg_ddr_mode` 复位值改为 0，原始 IQ 录制默认关闭。原 `CMAC_STATUS` 寄存器及其 CMAC misc 同步器已删除。

#### 源级核验（2026-10-04）

- `run_rtl_regression.ps1`：**22/22 通过**。新增 `tb_ddc_nco`、`tb_fm_signal_meter`、`tb_fm_seek`、`tb_axis_fanout2_nb`、`tb_ui_panel`；`tb_fm_demod` 和 `tb_audio_pcm_packer` 已重写。
  - 修了脚本本身的两个问题：原来用 `rg` 列文件，本机没有这个命令；xsim 遇到 `$fatal` 时退出码仍为 0，原脚本只看退出码，会把失败当成通过。现在同时检查 `Fatal:`/`Error:` 和每个测试的 `_PASS` 标记。修好后才发现 `tb_spectrum_engine` 实际一直失败：08-31 时序收敛时 noise floor 改成取瞬时功率，testbench 的期望值没跟着改，现已修正。
  - 实测数据：混频器 RMS 误差 7.96 LSB / 16000（理论约 7.1）；平坦度实测为干净 FM 1.00、噪声 2.01、10 dB CNR 1.19（理论 1.17）。
- `tools/fpga/run_one_test.ps1 -Test <tb名>`：单独运行一个测试。
- BD：`_codex_validate_design.tcl` 批处理（日志 `reports/source_validation/vivado_validate_fm.log`）结果：0 ERROR / 0 CRITICAL WARNING，`CODEX_SOURCE_VALIDATION_PASS`，悬空标量输入 0、悬空输出 54（逐项见 `unconnected_bd_pins.rpt`）。地址映射：`u_aring/M_AXI` 看到的 DDR 位于 `0x8000_0000`（2 GiB），与 `u_ring` 一致。日志里两条 `skip connect cmac_0/ctl_tx_resend_pause / ctl_tx_pause_req` 在改动前就已存在：当前 CMAC 配置没有这两个引脚，跳过不影响。`_codex_validate_design.tcl` 现在会先清理工程中已不存在的 `rtl/` 源文件条目。

**上板发现（2026-10-04）：** 第一次烧写 FM 版 bit 后 LED 全灭，JTAG-AXI 读寄存器超时，但 MIG 校准全部通过。根因：`lr_bd_s2.tcl` 把三个 `proc_sys_reset` 的 `aux_reset_in` 接到了 GND，而它是低有效（`C_AUX_RESET_HIGH=0`），所以外设复位一直无法释放。这个问题自 S2 起就存在，08-31 的版本同样受影响。现已改为接 `const_one`，需要重新综合和实现。

**上板 bring-up（2026-10-05，修复 `aux_reset_in` 后的 bitstream）：**

- 基础功能：寄存器 ID 读到 `0x4C52_0002`；DDR 校准通过；100G 链路已建立（LED4 常亮）。
- AD9361 经 JTAG 完成初始化：用时约 18 s，3700 次 SPI 事务；芯片为 Rev 2，61.44 Msps，1R1T，LVDS 接口调谐窗口为延时 6–15 档。
- 实际收到电台：89.1 MHz，平坦度 1.13。录下 10 s 音频，与 DDR 的字数对得上，没有丢样；19 kHz 立体声导频比周围高 39.7 dB。

主机工具（`tools/hw/`）：

| 工具 | 用途 |
|---|---|
| **`lr_jtagd/`** | **自研 JTAG 守护进程（推荐，不需要 Vivado）**：经 FTDI D2XX（运行时加载 `ftd2xx.dll`）以 MPSSE 模式驱动 FT2232H A 口，访问 FPGA 内的 LR 开放 JTAG 桥（USER4），在 127.0.0.1:5555 上提供与 `lr_jtag_bridge.tcl` 相同的行协议，并新增 `I`（信息）命令。多个客户端轮流服务，每轮每个客户端只执行一条命令：App 流水线发出的突发读不会再挤占 `ad9361_jtag`，否则初始化会被拖到几分钟、看起来像卡死；`--trace` 可以记录每条命令。`lr_jtagd --probe` 做逐级诊断，退出码含义：0 正常、2 缺 `ftd2xx.dll`、3 没有下载器、4 下载器被占用（Vivado HW Manager / hw_server）、5 JTAG 链不通、6 bitstream 不含 LR 桥、7 AXI 无响应、8 不是 LR 设计。编译：`tools\hw\lr_jtagd\build.ps1` |
| `lr_jtag_bridge.tcl` | 常驻的 Vivado 进程，独占 JTAG-AXI；在 127.0.0.1:5555 上提供读、写、突发读、SPI 命令。旧版 bitstream（0002/0003）的备用方案 |
| `ad9361_jtag/` | 在 PC 上运行 ADI no-OS AD9361 驱动，SPI/AXI 访问都经桥转发。用 `build.ps1` 编译，编译器是 Vitis HLS 自带的 MinGW gcc |
| `lr_record_audio.py` | 调谐 → 录制到 DDR 音频环 → 读回并保存为 WAV |
| `lr_live_audio.py` | 实时收音：持续读取 DDR 音频环，经 ffplay 播放（实测延迟约 12 ms，零丢失）；按键 u/d 搜台、+/- 步进 100 kHz、0 回中心、q 退出 |
| `lr_radio_gui.py` / `LR_Radio.bat` | **收音机 GUI**（tkinter，双击 `LR_Radio.bat` 启动）：频率显示、硬件搜台（PgUp/PgDn）和 ±0.1 MHz 步进（←/→）、直接输入频率（超出 ±10 MHz 窗口时自动重设本振）、全波段扫描电台列表和收藏、信号质量（由平坦度换算 CNR）、信号电平和音频电平、实时播放、PC 端音量和静音、录音存 WAV（`tools/hw/recordings/`）、去加重 50/75 µs、搜台灵敏度、锁定板上按键、板上 LED 镜像和错误清除；会按需启动 JTAG 桥、初始化 AD9361 |
| **`app/lr_radio`（Flutter 桌面 App，推荐）** | 可安装的 Windows 应用 **Lightning Receiver FM**，功能与 Python GUI 一致。**启动自检**：依次检测 音频输出 → JTAG 链路 → FPGA 设计 ID → 时钟/DDR（UPTIME 递增、校准位）→ AD9361（SPI 读芯片 ID）→ 射频配置（未初始化则自动运行 `ad9361_jtag`）→ 网络（可选），全部通过才进入收音机界面；不通过时显示原因和处理办法，并每 5 秒自动重试；运行中链路断开会回到自检页。链路默认用 `lr_jtagd`，设置里可切换为 Vivado 桥（旧版 bitstream 用）。音频通过 dart:ffi 直接调用 winmm waveOut 播放；安装包附带 `lr_jtagd.exe`、`ad9361_jtag.exe` 和 `lr_jtag_bridge.tcl`。构建：`powershell -File app\lr_radio\installer\build_installer.ps1` → `installer\Output\LR_Radio_Setup_1.1.1.exe`（约 10 MB，默认按当前用户安装；打包前会自动重新编译 `ad9361_jtag` 和 `lr_jtagd`）。图标由 `app\lr_radio\tool\make_icon.py` 生成：输出 `assets\app_icon.png` 和多尺寸的 `windows\runner\resources\app_icon.ico`，程序本体和安装包共用这个 ico。目标电脑只需要 FTDI D2XX 驱动和 `0x4C52_0004` 及以上的 bitstream。工具链：Flutter 3.47.6（`D:\tools\flutter`）、VS 2026 C++ 与 CMake 组件、Inno Setup 6.7 |

```powershell
$env:PROCESSOR_ARCHITECTURE='AMD64'
D:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode batch -nojournal -nolog -source tools\hw\lr_jtag_bridge.tcl   # 另开一个窗口常驻
tools\hw\ad9361_jtag\ad9361_jtag.exe --tune-hz 89100000
python tools\hw\lr_record_audio.py --freq-mhz 89.1 --seconds 10 --out fm.wav
```

上板发现的问题：

1. ❗ **`dc_correction` 直流估计没有小数位**：`dc += (s-dc)>>>12` 只会往下漂，最后稳定在 −2048 到 −4096 附近，等于往信号里注入一个接近满幅的直流。表现为本振正中心出现一个"强电台"，AGC 也被它拉低。目前由 `ad9361_jtag` 写 `CONTROL[0]=1` 把它旁路，AD9361 自身的直流跟踪足够用；RTL 还需要修。
2. ❗ **两次调谐后 PRBS 被重新打开**：no-OS 驱动在 `ad9361_init` 之后再做一次接口调谐，会把 RX PRBS 写回开启状态。`ad9361_jtag` 已经在调谐后显式关闭 PRBS。
3. **音频发闷**：`audio_pipeline` 的低通是单极点 `>>4`，截止频率约 1.9 kHz；再加上去加重，99.6% 的能量都在 3 kHz 以下。
4. **`ERR_STATUS` 持续为 `0xA2`/`0xA6`**，所以 LED1 快闪。推断原因：`spectrum_engine` 每帧需要 16384 个周期，而每帧数据只间隔约 15000 个周期，处理不过来，导致 xfft 停顿、dsp_router 丢包；另外 CMAC TX 有发送错误，疑似 packetizer 逐样本输出时，在 CDC FIFO 处造成包内欠载。bit2 是录制原始 IQ 时 ring FIFO 满了，属于预期。
5. **只收到 1 个台**：接收灵敏度偏低，需要确认天线是否适合 FM 波段（约 75 cm）。
6. **搜台没有超时**：没有 ADC 采样时，搜台会一直停在测量状态。

**上板修复版（2026-10-05，ID `0x4C52_0003`，WNS +0.081 ns / WHS +0.010 ns）——上面问题 1、3、4、6 已在 RTL 中修复并经上板验证：**

| 问题 | 修复 | 上板结果 |
|---|---|---|
| 直流校正向下漂移 | `dc_correction` 增加 12 位小数并做舍入（新增 `tb_dc_correction`；旧版 RTL 在这个测试下会漂到 +2049） | FPGA 直流校正开启时，LO 中心的功率和噪声中位数处于同一水平 |
| 音频发闷 | `audio_pipeline`：191 阶 FIR（通带 15 kHz，19 kHz 以上衰减 ≥59.6 dB）+ 4:1 抽取；去加重默认 50 µs（国内标准），`AUDIO_CFG[18]=1` 切换为 75 µs | 3–8 kHz 能量占比从 0.38% 升到 4.38%，8–15 kHz 从 0.03% 升到 0.82%；19 kHz 导频残留从约 24.7 LSB 降到约 0.3 LSB（−41 dB） |
| 频谱支路丢包（ERR bit1） | 新增 `axis_frame_decim`，每 N 帧处理 1 帧（`FFT_CFG[15:8]`，小于 2 时取默认值 4） | 10 s 内 router 丢包为 0 |
| xfft 停顿被当成错误（bit5） | 输入、输出等待属于正常流控，不再计入错误，只保留状态通道停顿 | `ERR_STATUS` 保持为 0 |
| CMAC 错误清不掉（bit7） | 粘滞锁存器改为 `lr_pulse_cdc` 逐事件传递；TX CDC FIFO 改为 packet mode（`FIFO_MODE 2`） | `ERR_STATUS` 保持为 0，LED1 常亮 |
| 无采样时搜台卡住 | `fm_seek` 等待测量超过 25 ms 即放弃，回到起点，并置 `SEEK_CTRL[5]`（无信号） | 已有仿真覆盖 |

RTL 回归 24/24 通过。`ad9361_jtag` 会根据设计 ID 自动处理：`0002` 旁路直流校正，`0003` 启用直流校正，并按 `--deemph 50|75` 设置去加重。

**开放 JTAG 桥（ID `0x4C52_0004`，`rtl/control/lr_jtag_axi_bridge.v` + `lr_jtag_axi_core.v`）：** 为了让主机不依赖 Vivado，新增一个协议公开的 JTAG→AXI4-Lite 主机，挂在 `axi_ic_0/S04`（`clk_fabric` 域）。Xilinx `jtag_axi`（S00，debug hub 在 USER1）保持不变，供 Vivado 调试使用。

- `BSCANE2 JTAG_CHAIN=4`（USER4，IR=`6'h23`，IR 长度 6），TCK 经 BUFG，约束为 30 MHz 并与 fabric 时钟异步（`lr_jtag_tck`）。
- DR 为 72 位，LSB 先移。命令格式：`[1:0]` op（0 NOP / 1 WRITE / 2 READ / 3 CLEAR）、`[35:4]` 地址、`[67:36]` 写数据、`[71:68]` tag。
- 状态格式（Capture-DR 装入，即上一条命令的结果）：`[0]` valid、`[1]` busy、`[2]` overrun（粘滞）、`[4:3]` resp、`[36:5]` 读数据、`[40:37]` tag、`[47:44]` 版本=1、`[71:48]` 魔数 `"LRJ"`（`0x4C524A`）。
- 命令经翻转握手跨到 AXI 时钟域。bridge 忙时到达的命令会被丢弃，并置位粘滞 overrun，直到收到 CLEAR，所以一批命令中被执行的总是前缀部分。`lr_jtagd` 据此推断哪些命令已执行：读命令补读，写命令绝不重复执行。
- 仿真：`tb_lr_jtag_axi_core`（魔数、读写、16 条流水读、忙 / 溢出 / CLEAR / 重发、错误响应）。

**上板验证（2026-10-05，带桥的 bitstream）**：`--probe` 显示 `bridge=ok version=1`；200 次随机写读回无错误；突发读与单次读结果一致；单次读约 7300 次/s，256 字突发读约 417 KiB/s（实时音频约需 94 KiB/s）；`ad9361_jtag` 经 lr_jtagd 完成初始化，用时 4.1 s（Vivado 桥约 18 s）；89.1 MHz 录音 10 s，DDR 写入 30003 字，与预期一致，2.3 s 读完；App 启动时自动拉起 lr_jtagd，7 项自检全部通过，退出时守护进程一并结束。

更早在 0003 版板卡上的验证：FTDI 打开成功（序列号 0ABC01A，TCK 15 MHz），读到 IDCODE `0x04A62093`，`bridge=absent`（退出码 6，符合预期）；Vivado 占用下载器时正确报告退出码 4。App 自检已用 Vivado 桥测试通过（7 项全部通过），下载器被占用时显示对应提示并自动重试。

实现阶段 `opt_design` 生成 MIG PHY 的子进程，偶发打不开文件（`unimacro_vhdl.tcl`、`retarget_vhdl.tcl`、`u_mig_ddr4_phy_phy.xdc` 等，提示 `No error`），与设计本身无关。在 GUI 中改用 `source tools/fpga/impl_retry.tcl; lr_impl_with_retry`，只针对这一种错误自动重试。可疑原因：`D:\Xilinx` 下的文件带有 PINNED（`0x80000`）属性，系统中 `CldFlt` 云文件筛选驱动处于活动状态，尚未确认。

**待办：**

1. 改善天线（FM 波段约 75 cm），提高可收到的电台数；之后用 KEY1/KEY2 验证搜台。
2. （已完成）修复 `aux_reset_in` 后重新综合 / 实现（FM 版首次实现结果：WNS +0.047 ns、WHS +0.010 ns，时序收敛）。
2. 上板：AD9361 初始化须保证 `axi_ad9361` 输出 12 位符号扩展数据（混频器 ×8 增益按此设计）；验证搜台阈值。
3. 主机 GUI：AD9361 初始化与 LO 设置、经 JTAG AXI 读取音频环（int16 LE PCM）、搜台按钮（`SEEK_CTRL`）、信号强度显示（`SIG_POWER` / `SIG_QUALITY`），并轮询 `UI_STATUS` 同步面板改动。

## 开发环境与 AI 工具

- **Vivado 2021.1**：`D:\Xilinx\Vivado\2021.1\bin\vivado.bat`（本工程统一使用 2021.1，**不要**使用本机同时安装的 2026.1）
- **Vivado MCP Server**（AMD Ross Agentic AI Assistant 2026.9.1）：已在 Claude Code 中注册，作用域为 user，`VIVADO_PATH` 指向 2021.1：
  ```bash
  claude mcp add vivado-mcp --scope user --transport stdio --env VIVADO_PATH=D:/Xilinx/Vivado/2021.1/bin/vivado.bat -- D:/IDM_Download/Programs/vivado-mcp-server-windows-amd64-2026.9.1.exe --stdio-bridge
  ```
  - 用法：可以让 agent "启动 Vivado 会话"（`vivado_start`，Tcl 模式）；也可以在已打开的 Vivado Tcl 控制台执行 `webserver -start -port 8088 -key none`，再让 agent 连接 `http://localhost:8088`（`vivado_connect`）。
  - MCP 会话日志和 journal 写在 `.vivado-ai/`。
- Claude Code 插件：`amd-ross-agentic-ai-assistant`（技能：rtl-lint、simulate-rtl、timing-methodology-checks、ila/vio debug 等）

## 文档索引

| 文档 | 路径 | 状态 |
|---|---|---|
| 硬件接口规格 | `docs/hardware/LR_Hardware_Interface_Spec_Rev0.2.md` | Rev 0.2（板级条目已确认） |
| 硬件接口规格（草稿模板） | `docs/hardware/LR_Hardware_Interface_Spec_Rev0.1.md` | Rev 0.1（历史） |
| 厂商资料提取文本 | `docs/hardware/source/` | 手册/原理图/管脚定义/等长 纯文本 |
| 解析工具 | `tools/extract_vendor_pdfs.py`、`tools/extract_vendor_xls.py` | Python（pypdf / xlrd） |

## 资料来源（本机）

- 板卡出厂资料：`D:\Data\Baidu_disk_download\9.RK-XCKU5P-F开发板网盘资料`（RK-XCKU5P-F V1.2）
- FPGA 现有工程：`D:\workspace\xilinx\`（KU5P_DEMO、IBERT_100G、image_ku5p 出厂工程等）

## Git 仓库说明（不纳入版本库的内容）

本仓库只放源码、脚本和文档（见 `.gitignore`）。下面这些需要另外获取或重新生成：

| 内容 | 获取方式 |
|---|---|
| **ADI HDL 库** `fpga/vendor_reference/FMC_AD936X_PL/`（`lr_sources.tcl` 从其中的 `library/` 注册 `axi_ad9361` 等 IP） | FMC_AD936X 子卡厂商资料包中的 `FMC_AD936X_PL`，基于 ADI HDL，对应 Vivado 2021.1。也可以改用 [analogdevicesinc/hdl](https://github.com/analogdevicesinc/hdl) 的 `hdl_2021_r1` 分支。放到上面的路径后，需要先打包用到的 IP：在 `library/axi_ad9361` 等目录执行 `make`，或用 Vivado 2021.1 运行对应的 `*_ip.tcl`。`fpga/vendor_reference/FMC_AD936X_PS/` 只是参考工程，构建时用不到 |
| Vivado 工程生成物（`.srcs/.gen/.runs/.cache/.ip_user_files`） | 按下一节，用 `tools/fpga/*.tcl` 重建 |
| bitstream、App 安装包、`ad9361_jtag.exe`、`lr_jtagd.exe` | 从 GitHub Releases 下载，或者用 `build_installer.ps1` 和 `tools/hw/*/build.ps1` 本地编译 |
| 录音 WAV、本地设置、`_backup_pre_fm/` | 本机文件，不同步 |

## FPGA 工程构建（Vivado 驱动：手动建工程 + source 脚本）

`fpga/` 只放 **Vivado 生成的产物**（厂商参考 `fpga/vendor_reference/` 除外）。步骤：

1. **手动创建 Vivado 工程**：工程名 `LightningReceiver`，位置 `D:\workspace\LightningReceiver\fpga\LightningReceiver`，器件 `xcku5p-ffvb676-2-i`
2. 打开工程后，在 Tcl 控制台依次执行：
   ```tcl
   source D:/workspace/LightningReceiver/tools/fpga/lr_setup.tcl   ;# BD(时钟/复位/UART) + 约束 + wrapper
   source D:/workspace/LightningReceiver/tools/fpga/lr_build.tcl   ;# 综合 + 实现 + bitstream
   ```
   或分别 source：`lr_bd_s0.tcl` / `lr_constraints.tcl` / `lr_wrapper.tcl` / `lr_build.tcl`（`set RUN_IMPL 0` 只综合）

3. **S1（AD9361 RX + Stream Fabric）**，在 S0 基础上：
   ```tcl
   source D:/workspace/LightningReceiver/tools/fpga/lr_sources.tcl       ;# 自定义 RTL + ADI IP 库
   source D:/workspace/LightningReceiver/tools/fpga/lr_bd_s1.tcl         ;# axi_ad9361 + jtag_axi + raw_iq_router
   source D:/workspace/LightningReceiver/tools/fpga/lr_constraints_s1.tcl ;# FMC LVDS 引脚（DRAFT，DQ-1 待核对）
   ```

4. **S2（全量装配：MIG + CMAC + 完整时钟 + DSP 流水线）**——`lr_bd_s2.tcl` **重建整个 BD**（F_SMART 时钟拓扑：200M→MIG→UI 333.25M→clk_fabric→225/100；CMAC CAUI4 + QSFP refclk 156.25M；axi_ad9361 + stream fabric；控制面），取代 S0/S1 的 BD 脚本：
   ```tcl
   source D:/workspace/LightningReceiver/tools/fpga/lr_bd_s2.tcl          ;# 全量 BD（含 DSP/FFT/FM 流水线、DDR 环形缓冲、CMAC 网络 TX）
   source D:/workspace/LightningReceiver/tools/fpga/lr_constraints_s2.tcl ;# DDR4 引脚 + QSFP refclk
   source D:/workspace/LightningReceiver/tools/fpga/lr_wrapper.tcl
   set RUN_IMPL 0; source D:/workspace/LightningReceiver/tools/fpga/lr_build.tcl
   ```
   > 全量构建顺序：`lr_sources.tcl` → `lr_bd_s2.tcl` → `lr_constraints.tcl` → `lr_constraints_s1.tcl` → `lr_constraints_s2.tcl` → `lr_wrapper.tcl` → `lr_build.tcl`
   > S0/S1 的 BD 脚本仅用于增量 bring-up 验证，全量装配以 S2 为准。
   > S2 数据面：AD9361 RX → raw_iq_router → 四路独立 FIFO 的 dsp_router，其中 m0 为 FM/音频、m1 为 DDR 环形缓冲、m2 为 FFT 频谱、m3 为原始 IQ 网络流；FM 路径为 dc_correction→ddc_mixer（内置逐样本 NCO）→complex_cic_decimator→fm_signal_meter→fm_demod（CORDIC）→audio_pipeline→axis_fanout2_nb（分出 DDR 音频环和网络两路）；FFT 路径为 window_mult→xfft→spectrum_engine→signal_detector；音频/原始 IQ 经无毛刺模式复用后进入 packetizer，再以 512-bit AXIS 跨时钟送入 CMAC TX。控制面为 JTAG AXI（AD9361/CMAC/DDR/LR 寄存器）以及独立的物理 UART 8-N-1 命令解析器，UART 与 AXI 共享 register_bank 并带 CDC。

- 自定义 RTL 源码树：`rtl/`（fabric/DSP/control/telemetry/network/timing）。

## 源级核验（不运行综合/实现）

```powershell
# 25 个独立 RTL 功能测试：xvlog + xelab + xsim（日志：reports/source_validation/rtl_regression.log）
# 判定失败的条件：xvlog/xelab/xsim 退出码非 0、仿真输出出现 Fatal:/Error:，或缺少 _PASS 标记
# 单独运行一个测试：tools/fpga/run_one_test.ps1 -Test tb_xxx
tools/fpga/run_rtl_regression.ps1

# Vivado 批处理重建 S2 BD、validate_bd_design、生成 BD target/wrapper
$env:PROCESSOR_ARCHITECTURE='AMD64'
D:/Xilinx/Vivado/2021.1/bin/vivado.bat -mode batch -nolog -nojournal `
  -source tools/fpga/_codex_validate_design.tcl
```

最近一次源级核验是 2026-10-04（FM Phase-1 之后），结果保存在 `reports/source_validation/`：RTL 回归 22/22 通过；BD 校验 0 ERROR / 0 CRITICAL WARNING，悬空标量输入 0（日志 `vivado_validate_fm.log`）。`unconnected_bd_review.md` 是 2026-08-28 对悬空输出的逐项分类，FM 改动新增的悬空输出见 `unconnected_bd_pins.rpt`。

## 已确认板级基线（HWI L2）

- FPGA：XCKU5P-2FFVB676I（`xcku5p-ffvb676-2-i`）
- DDR4：2× MT40A512M16LY-062E，32-bit / 2GB / 2666 Mbps
- FMC：HPC（LA 34 对 + 8×GTY），VADJ1 = 1.8V（可改 1.2V）
- 100G：QSFP28 → GT BANK225 4×25G，refclk 156.25 MHz
- 控制面：FT2232HQ（UART+JTAG，单 USB-C）；板载 KEY1~4 / LED1~4
- **现成 100G 平台资产**：`D:\workspace\xilinx\F_smart_KU5P_stage3_100g_v1\`（CMAC CAUI4 100G + DDR4-2666 MIG，时序收敛、bitstream 已生成）
- **RF 子卡**：FMC_AD936X（第三方 AD936X 卡，FMC-LPC）——LVDS 6-bit 接口、REFCLK 板载 40MHz、VDD_INTERFACE=FMC_ADJ（1.8V 匹配）；参考工程已归档 `fpga/vendor_reference/FMC_AD936X_PL|PS/`
- 🟡 芯片型号：**AD9361 已确认**（用户确认；70M–6GHz，FM 可行）
- **主机网卡**：Mellanox **MCX455A-ECAT**（ConnectX-4 VPI，100GbE 单口 QSFP28）——与 FPGA QSFP28 直连（DAC/光模块）；Windows 需 WinOF-2 驱动
- ✅ FMCOMMS2 VADJ 兼容性已解决：VADJ1=1.8V 直接可用（ADI 官方 ZC706 同配置）

## 下一步（见 HIS §12 / 结论）

1. ✅ 全量 S2 源码、BD 接线、CDC/复位、控制面和 RTL 功能测试已完成源级核验。
2. ✅ 2026-08-31 完成综合与实现，时序收敛（WNS 0.063 / WHS 0.010 ns），bitstream 已生成。
3. 🟡 FM 收音机 Phase-1：RTL 与 BD 已完成源级核验，下一步是综合/实现并重新确认时序（见上文"当前状态"）。
4. 板级 bring-up：FMC LVDS 的 DQ-1 物理映射仍须按实际子卡原理图/实物复核；DDR4、QSFP refclk 和 AD9361 SPI 初始化需上板验证。
5. 主机侧：WinOF-2 驱动 + Mellanox MCX455A-ECAT 与 FPGA QSFP28 直连验证。
