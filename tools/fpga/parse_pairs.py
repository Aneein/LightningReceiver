import re

rpt = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\all_violated.rpt"
lines = open(rpt, encoding="utf-8", errors="replace").read().splitlines()

# table rows: endpoint line then 4 number lines; we only have endpoint names here
# Instead: use the timing_debug.rpt which has full blocks. Parse From/To clock pairs.
rpt2 = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\timing_debug.rpt"
lines2 = open(rpt2, encoding="utf-8", errors="replace").read().splitlines()

pairs = {}
i = 0
n = len(lines2)
while i < n:
    if lines2[i].startswith("From Clock:"):
        fc = lines2[i].split(":",1)[1].strip()
        if i+1 < n and lines2[i+1].startswith("  To Clock:"):
            tc = lines2[i+1].split(":",1)[1].strip()
            key = (fc, tc)
            # find setup failing count in following lines
            j = i+2
            while j < n and not lines2[j].startswith("From Clock:"):
                if "Failing Endpoints" in lines2[j] and "Setup" in lines2[j]:
                    m = re.search(r"Setup\s*:\s+(\d+)\s+Failing", lines2[j])
                    if m:
                        pairs[key] = int(m.group(1))
                    break
                j += 1
    i += 1

print("=== failing path pairs (From -> To) ===")
for (fc, tc), cnt in sorted(pairs.items(), key=lambda kv: -kv[1]):
    if cnt > 0:
        print(f"  {fc:<50} -> {tc:<50} {cnt}")
