import re

rpt = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\all_violated.rpt"
lines = open(rpt, encoding="utf-8", errors="replace").read().splitlines()

# report_timing -path_type end: one block per endpoint, "Slack (VIOLATED)" header
src_mod = {}
src_clock = {}
cur = False
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    if "Slack (VIOLATED)" in line:
        cur = True
    elif cur and line.startswith("  Source:"):
        m = re.search(r"system_i/([a-z0-9_]+)/", line)
        if m:
            src_mod[m.group(1)] = src_mod.get(m.group(1), 0) + 1
        c = re.search(r"clocked by ([^ ]+)", line)
        if c:
            src_clock[c.group(1)] = src_clock.get(c.group(1), 0) + 1
    elif cur and line.startswith("  Destination:"):
        cur = False
    i += 1

print("=== VIOLATED source modules ===")
for k, v in sorted(src_mod.items(), key=lambda kv: -kv[1]):
    print(f"  {k:<22} {v}")
print("total:", sum(src_mod.values()))
print()
print("=== VIOLATED source clocks ===")
for k, v in sorted(src_clock.items(), key=lambda kv: -kv[1]):
    print(f"  {k:<50} {v}")
