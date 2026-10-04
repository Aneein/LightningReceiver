import re

rpt = r"D:\workspace\.lr_scratch4\rpt_synth_timing.rpt"
lines = open(rpt, encoding="utf-8", errors="replace").read().splitlines()

# capture blocks: From Clock: mmcm_clkout0 -> To Clock: clk_out1_system_clk_fabric_0
capture = False
for i, line in enumerate(lines):
    if line.startswith("From Clock:") and "mmcm_clkout0" in line:
        nxt = lines[i+1] if i+1 < len(lines) else ""
        if "clk_out1_system_clk_fabric_0" in nxt:
            capture = True
            continue
    if capture and line.startswith("Slack (VIOLATED)"):
        # print this path block header + source/dest
        for k in range(i, min(i+6, len(lines))):
            print(lines[k].strip())
        print()
    if capture and line.startswith("From Clock:") and "mmcm_clkout0" not in line:
        capture = False
