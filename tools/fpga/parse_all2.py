import re

rpt = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\all_violated.rpt"
lines = open(rpt, encoding="utf-8", errors="replace").read().splitlines()

end_mod = {}
end_clock = {}
cur_end = None
for line in lines:
    if line.startswith("system_i/"):
        m = re.match(r"system_i/([a-z0-9_]+)/", line)
        if m:
            end_mod[m.group(1)] = end_mod.get(m.group(1), 0) + 1
    elif line.startswith("                                ") and cur_end and re.match(r"^\s+[\d.]+\s+[\d.]+\s+", line):
        pass

print("=== VIOLATED endpoints by module ===")
for k, v in sorted(end_mod.items(), key=lambda kv: -kv[1]):
    print(f"  {k:<22} {v}")
print("total:", sum(end_mod.values()))
