import re

rpt = r"D:\workspace\.lr_scratch4\rpt_synth_timing.rpt"
lines = open(rpt, encoding="utf-8", errors="replace").read().splitlines()

# find setup violations (Path Type: Setup) with negative slack
for i, line in enumerate(lines):
    if "Slack (VIOLATED)" in line and i+1 < len(lines):
        m = re.search(r"Slack \(VIOLATED\)\s*:\s*(-?[\d.]+)ns", line)
        if not m: continue
        slack = float(m.group(1))
        # look ahead for Path Type
        j = i
        ptype = ""
        while j < min(i+8, len(lines)):
            if "Path Type:" in lines[j]:
                ptype = lines[j]
                break
            j += 1
        if "Setup" in ptype and slack < 0:
            print(f"slack {slack}  line {i+1}")
            for k in range(i, min(i+6, len(lines))):
                print("   ", lines[k].strip())
            print()
