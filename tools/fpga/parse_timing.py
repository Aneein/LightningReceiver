import re, sys

rpt = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\timing_debug.rpt"
lines = open(rpt, encoding="utf-8", errors="replace").read().splitlines()

# Each path block starts with "Slack (VIOLATED)" ; the Source line follows.
src_mod = {}
src_clock = {}
cur_viol = False
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    if "Slack (VIOLATED)" in line:
        cur_viol = True
    elif cur_viol and line.startswith("  Source:"):
        m = re.search(r"system_i/([a-z0-9_]+)/", line)
        if m:
            src_mod[m.group(1)] = src_mod.get(m.group(1), 0) + 1
        # clock info on next continuation lines
    elif cur_viol and line.startswith("  Destination:"):
        cur_viol = False
    i += 1

print("=== VIOLATED path source modules (by path block) ===")
for k, v in sorted(src_mod.items(), key=lambda kv: -kv[1]):
    print(f"  {k:<22} {v}")
print("total blocks:", sum(src_mod.values()))
