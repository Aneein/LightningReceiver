"""Render the Lightning Receiver FM app icon (orange radio on a white
rounded square) and write windows/runner/resources/app_icon.ico plus a
1024 px PNG master in assets/.

Geometry is taken from the 1254 px reference design; everything is drawn
4x supersampled and downscaled for clean edges.
Run:  python tool/make_icon.py
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SS = 4                      # supersampling factor
OUT = 1024                  # master size
ORANGE = (253, 130, 38, 255)
WHITE = (255, 255, 255, 255)
EDGE = (226, 226, 226, 255)

# reference design: rounded square spans x 100..1150, y 105..1155
REF_X0, REF_Y0, REF_W = 100.0, 105.0, 1050.0
K = OUT * SS / REF_W


def P(x, y):
    return ((x - REF_X0) * K, (y - REF_Y0) * K)


def L(v):
    return v * K


def render():
    n = OUT * SS
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # white rounded-square plate with a faint edge
    r = L(190)
    d.rounded_rectangle((0, 0, n - 1, n - 1), radius=r, fill=EDGE)
    e = L(5)
    d.rounded_rectangle((e, e, n - 1 - e, n - 1 - e), radius=r - e, fill=WHITE)

    # antenna: stroke from the body's top-left to the ball
    ax0, ay0 = P(369, 512)
    ax1, ay1 = P(845, 357)
    w = L(30)
    ang = math.atan2(ay1 - ay0, ax1 - ax0)
    nx, ny = -math.sin(ang) * w / 2, math.cos(ang) * w / 2
    d.polygon([(ax0 + nx, ay0 + ny), (ax1 + nx, ay1 + ny),
               (ax1 - nx, ay1 - ny), (ax0 - nx, ay0 - ny)], fill=ORANGE)
    bx, by = ax1, ay1
    br = L(47)
    d.ellipse((bx - br, by - br, bx + br, by + br), fill=ORANGE)

    # body
    x0, y0 = P(275, 497)
    x1, y1 = P(976, 922)
    d.rounded_rectangle((x0, y0, x1, y1), radius=L(78), fill=ORANGE)

    # three grille bars
    for cy in (626, 715, 805):
        bx0, by0 = P(333, cy - 22)
        bx1, by1 = P(631, cy + 22)
        d.rounded_rectangle((bx0, by0, bx1, by1), radius=L(22), fill=WHITE)

    # speaker ring
    cx, cy = P(810, 717)
    ro, ri = L(125), L(81)
    d.ellipse((cx - ro, cy - ro, cx + ro, cy + ro), fill=WHITE)
    d.ellipse((cx - ri, cy - ri, cx + ri, cy + ri), fill=ORANGE)

    return im.resize((OUT, OUT), Image.LANCZOS)


def main():
    im = render()
    assets = ROOT / "assets"
    assets.mkdir(exist_ok=True)
    im.save(assets / "app_icon.png")
    ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    sizes = [(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)]
    im.save(ico, sizes=sizes)
    print("ICON_OK", assets / "app_icon.png", ico)


if __name__ == "__main__":
    main()
