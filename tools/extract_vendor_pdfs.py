# Extract text from the RK-XCKU5P-F vendor PDFs for the LR hardware freeze.
import sys, os
sys.path.insert(0, r"D:\workspace\.pylibs")
from pypdf import PdfReader

SRC = r"D:\Data\Baidu_disk_download\9.RK-XCKU5P-F开发板网盘资料"
OUT = r"D:\workspace\LightningReceiver\docs\hardware\source"

os.makedirs(OUT, exist_ok=True)

jobs = [
    ("1_用户手册\\RK-XCKU5P-F V1.2 开发板用户手册.pdf", "RK-XCKU5P-F_V1.2_user_manual.txt"),
    ("2_硬件资料\\RK-XCKU5P-F V1.2原理图.pdf", "RK-XCKU5P-F_V1.2_schematic.txt"),
    ("2_硬件资料\\RK-XCKU5P-F V1.2位号&尺寸图.pdf", "RK-XCKU5P-F_V1.2_silkscreen.txt"),
]

for rel, outname in jobs:
    path = os.path.join(SRC, rel)
    print(f"== {rel}", flush=True)
    try:
        r = PdfReader(path)
        n = len(r.pages)
        print(f"   pages: {n}", flush=True)
        with open(os.path.join(OUT, outname), "w", encoding="utf-8") as f:
            for i, page in enumerate(r.pages):
                try:
                    t = page.extract_text() or ""
                except Exception as e:
                    t = f"[extract error: {e}]"
                f.write(f"\n===== PAGE {i+1} =====\n")
                f.write(t)
        print(f"   -> {outname}", flush=True)
    except Exception as e:
        print(f"   FAILED: {e}", flush=True)
print("DONE", flush=True)
