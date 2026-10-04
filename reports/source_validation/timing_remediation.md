# LR FPGA 时序整改记录（源级）

本记录只描述 RTL/BD/XDC 的源级整改。本轮按用户要求没有运行 synthesis 或 implementation，因此不伪造新的 WNS/TNS/WHS/THS 结论；最终收敛必须以用户生成的 post-route `report_timing_summary` 为准。

## 已处理的主要根因

1. **IDELAY 参考时钟脉宽违例**：旧设计用 200 MHz 驱动 UltraScale IDELAYCTRL，旧报告对应 `WPWS=-1.666 ns`。`clk_wiz_iodelay` 已改为 300 MHz，并保持与 225.014957 MHz 上游实际频率一致的 BD 元数据。
2. **AD9361 控制跨域路径**：旧设计把 225 MHz 的 `rst_fabric/peripheral_aresetn` 直接接到 100 MHz `axi_ad9361/up_enable`，旧报告中该路径同时出现 setup/hold 违例。现改为静态 `const_one`；AD9361 AXI 域仍由本域 `s_axi_aresetn` 复位。
3. **FM 解调组合除法器**：单周期宽除法已改为 41 周期恢复除法器。输入采样率约 192 ksample/s，处理吞吐有充分余量。
4. **音频长乘加路径**：增益、去加重和 DC 阻断运算已分级寄存，输出遵循 AXIS 停顿保持规则。
5. **DDC 复乘长路径**：四个乘积与加减分成流水级。
6. **频谱历史存储和平均**：平均/峰值历史改为 16-bit Block RAM；Q0.16 alpha 平均使用流水乘法，不再构造大规模寄存器/组合路径。
7. **DDR Gray 解码链**：32-bit/26-bit 串行 XOR 链改为并行前缀网络，组合深度由 O(N) 降为 O(log N)。
8. **异步 FIFO 实现**：通用 CDC FIFO 改成同步 show-ahead 读并显式指定 Block RAM，避免组合 RAM 读回退到大量 LUT；DDR 4096×32 CDC 存储也指定 Block RAM。
9. **Packetizer 宽 RMW 路径**：原 512-bit 每拍读改写改为每拍两个字节直接 lane 写，去掉宽动态 mux；理论有效采样吞吐约 68.4 Msps，可覆盖 61.44 Msps 原始 IQ。
10. **DSP 分发背压**：四个消费者使用独立 256 深度 FIFO；慢分支局部丢包并计数，不再反压并锁死全部数据面。
11. **配置切换毛刺**：音频/原始 IQ 网络 mux 在时钟域内寄存选择和使能，避免组合配置跨越 AXIS 事务。
12. **跨时钟状态/事件**：AXI/AXIS 使用对应 Clock Converter；自定义数据使用 Gray-pointer async FIFO；CMAC 电平使用双触发器同步，短事件先在源域锁存再同步。

## 约束审计

- MIG 输入时钟由 MIG 生成约束；AD9361 RX 时钟为 250 MHz；QSFP refclk 为 156.25 MHz。
- 三个独立来源时钟组明确声明为 asynchronous；实际跨域均经过 CDC 结构，而不是直接传输多位数据。
- 没有为掩盖普通同步逻辑而添加宽泛的 `set_false_path` 或虚构 multicycle path。
- `CLOCK_DEDICATED_ROUTE BACKBONE` 仅用于已知的 `clk_fabric -> clk_wiz_iodelay` 时钟级联网络。

## 最终源级判据

- Vivado 2021.1：BD 重建、`validate_bd_design`、target/wrapper 生成成功。
- 验证日志：0 ERROR，0 CRITICAL WARNING。
- 悬空：0 标量输入、0 接口；43 个未使用输出均已分类审计。
- RTL：15/15 个独立 xvlog/xelab/xsim 测试通过。

## 用户后续实现时的硬判据

运行 implementation 后至少检查：

- `report_timing_summary -delay_type min_max`：WNS/TNS/WHS/THS 均不违例；
- pulse-width 检查不再出现 IDELAY 200 MHz 根因；
- `report_cdc` 中不存在未识别的多位数据跨域；
- DRC 中不存在未约束端口、非法 I/O bank 或时钟专用路由错误；
- 若仍有 IP 内部负裕量，应按新的实际最差路径区分 CMAC/MIG 厂商核路径和 LR 自定义逻辑路径，不沿用旧报告结论。
