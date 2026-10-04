# Dump all sheets of the RK-XCKU5P-F pin definition / length-matching XLS files.
import sys, os
sys.path.insert(0, r"D:\workspace\.pylibs")
import xlrd

SRC = r"D:\Data\Baidu_disk_download\9.RK-XCKU5P-F开发板网盘资料\2_硬件资料"
OUT = r"D:\workspace\LightningReceiver\docs\hardware\source"
os.makedirs(OUT, exist_ok=True)

jobs = [
    ("RK-XCKU5P-F V1.2管脚定义.xls", "RK-XCKU5P-F_V1.2_pin_definition.txt"),
    ("RK-XCKU5P-F V1.2等长说明.xls", "RK-XCKU5P-F_V1.2_length_matching.txt"),
]

for name, outname in jobs:
    path = os.path.join(SRC, name)
    print(f"== {name}", flush=True)
    try:
        wb = xlrd.open_workbook(path)
        with open(os.path.join(OUT, outname), "w", encoding="utf-8") as f:
            for sh in wb.sheets():
                f.write(f"\n===== SHEET: {sh.name} ({sh.nrows}x{sh.ncols}) =====\n")
                for r in range(sh.nrows):
                    row = []
                    for c in range(sh.ncols):
                        v = sh.cell_value(r, c)
                        if isinstance(v, float) and v == int(v):
                            v = int(v)
                        row.append(str(v))
                    f.write(" | ".join(row) + "\n")
        print(f"   -> {outname}", flush=True)
    except Exception as e:
        print(f"   FAILED: {e}", flush=True)
print("DONE", flush=True)
