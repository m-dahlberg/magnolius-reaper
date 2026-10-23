#!/usr/bin/env python3
"""Render gui_kit/meter_face.png: the static face of the gain-reduction meter.

A backlit blue/black display.  The scale runs 20 ... 0 left to right, so the
needle rests at the right and gain reduction swings it to the left.  The plugin
draws the live parts (needle, hold tick, readout) on top with gfx primitives;
everything here is chrome.

The geometry constants are mirrored in Magnolius_BusCompressor.jsfx (the
FACE_*, M_* names in @gfx).  Change them in both places.

    python3 tools/make_meter_face.py [out.png]

Needs Pillow.  Output is 2x: 376 x 176 for the 188 x 88 logical face.
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "gui_kit", "meter_face.png")

# ---- geometry, logical px, origin = top-left of the face --------------------
FW, FH = 188, 88
PX, PY = 94.0, 132.0          # needle pivot, below the face
R0 = 112.0                    # scale radius
SWEEP = 41.0                  # degrees either side of straight up
HUB_R = 58.0                  # the dark hub the needle comes out of
MAXG = 15.0                   # dB at the far left of the scale
SPLIT_G = 5.0                  # 0..SPLIT_G takes half the travel: that is where bus work happens
SCALE = (0, 1, 2, 3, 4, 5, 7, 10, 15)
RED_FROM = 10

S = 2                         # output scale
SS = 4                        # supersampling on top of that
K = S * SS

FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
FONT_B = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"


def travel(g):
    """0..1 position along the scale: 0..SPLIT_G dB fills the first half."""
    g = min(max(g, 0.0), MAXG)
    return 0.5 * g / SPLIT_G if g <= SPLIT_G else 0.5 + 0.5 * (g - SPLIT_G) / (MAXG - SPLIT_G)


def ang(g):
    """Needle angle in radians from straight up, positive = right. 0 dB is right."""
    return math.radians(SWEEP - 2 * SWEEP * travel(g))


def pt(r, g, cx=PX, cy=PY):
    a = ang(g)
    return (cx + r * math.sin(a)) * K, (cy - r * math.cos(a)) * K


def backlight():
    """Navy/black with a soft blue glow behind the scale and a vignette."""
    w, h = FW * K, FH * K
    g = Image.radial_gradient("L")                      # 0 centre .. 255 edge
    g = g.resize((int(w * 1.9), int(h * 2.3)), Image.BICUBIC)
    cx, cy = g.size[0] // 2, g.size[1] // 2
    gx, gy = int(PX * K), int(60 * K)                   # glow centre in face coords
    g = g.crop((cx - gx, cy - gy, cx - gx + w, cy - gy + h))
    glow = g.point(lambda v: int(255 * max(0.0, 1 - v / 255.0) ** 1.7))
    edge = Image.new("RGB", (w, h), (3, 6, 13))
    mid = Image.new("RGB", (w, h), (12, 38, 72))
    core = Image.new("RGB", (w, h), (46, 118, 190))
    base = Image.composite(mid, edge, glow)
    hot = glow.point(lambda v: int(v * v / 255 * 0.55))
    return Image.composite(core, base, hot)


def main():
    w, h = FW * K, FH * K
    img = backlight().convert("RGBA")

    # lower third darkens a little, as the display recedes towards the hub
    shade = Image.new("L", (w, h), 0)
    sd = ImageDraw.Draw(shade)
    for y in range(int(h * 0.55), h):
        sd.line((0, y, w, y), fill=int(150 * max(0.0, (y - h * 0.55) / (h * 0.45)) ** 1.4))
    img.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", (w, h), (2, 4, 9)).split(), shade)))

    # ---- scale layer (drawn once, then blurred under itself for the glow)
    ink = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(ink)
    pale = (205, 233, 255, 255)
    red = (255, 122, 108, 255)

    ticks = [i / 2.0 for i in range(0, 11)] + [float(v) for v in range(6, int(MAXG) + 1)]
    for g in ticks:
        big = g in SCALE
        r_in = R0 - (7 if big else 4 if g == int(g) else 2.5)
        col = red if g >= RED_FROM else pale
        d.line((*pt(r_in, g), *pt(R0, g)), fill=col, width=int(K * (1.1 if big else 0.7)))
    # arc along the outside of the ticks
    a0, a1 = -SWEEP, SWEEP
    d.arc(((PX - R0) * K, (PY - R0) * K, (PX + R0) * K, (PY + R0) * K),
          -90 + a0, -90 + a1, fill=(120, 170, 215, 150), width=int(K * 0.6))

    fnt = ImageFont.truetype(FONT, int(K * 8.5))
    for g in SCALE:
        x, y = pt(R0 - 15, g)
        d.text((x, y), str(g), font=fnt, fill=red if g >= RED_FROM else pale, anchor="mm")

    # red zone band along the arc
    steps = 60
    outer = [pt(R0 + 1.0, RED_FROM + (MAXG - RED_FROM) * i / steps) for i in range(steps + 1)]
    inner = [pt(R0 + 3.6, RED_FROM + (MAXG - RED_FROM) * i / steps) for i in range(steps + 1)]
    d.polygon(outer + inner[::-1], fill=(214, 66, 56, 255))

    # unit labels
    lab = ImageFont.truetype(FONT_B, int(K * 11))
    sub = ImageFont.truetype(FONT, int(K * 8))
    d.text((PX * K, 55 * K), "GR", font=lab, fill=(150, 200, 245, 255), anchor="mm")
    d.text((PX * K, 65.5 * K), "dB", font=sub, fill=(105, 150, 200, 255), anchor="mm")

    glow = ink.filter(ImageFilter.GaussianBlur(K * 2.2))
    glow = Image.merge("RGBA", (*glow.split()[:3], glow.split()[3].point(lambda v: min(255, int(v * 1.6)))))
    img.alpha_composite(glow)
    img.alpha_composite(ink)

    # ---- hub, centred on the pivot, cut by the bottom edge of the face
    hub = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hub)
    hd.ellipse(((PX - HUB_R) * K, (PY - HUB_R) * K, (PX + HUB_R) * K, (PY + HUB_R) * K),
               fill=(2, 4, 9, 255), outline=(38, 84, 132, 255), width=int(K * 1.2))
    inner_r = HUB_R - 3
    hd.ellipse(((PX - inner_r) * K, (PY - inner_r) * K, (PX + inner_r) * K, (PY + inner_r) * K),
               outline=(14, 30, 52, 255), width=int(K * 0.8))
    img.alpha_composite(hub)

    # ---- glass sheen: a soft diagonal highlight, top left
    sheen = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.polygon([(0, 0), (w * 0.62, 0), (w * 0.30, h), (0, h)], fill=(190, 225, 255, 14))
    sd.line((0, int(K * 0.6), w, int(K * 0.6)), fill=(200, 230, 255, 36), width=int(K * 0.8))
    img.alpha_composite(sheen)

    # ---- bezel: rounded mask, dark outline, faint inner highlight
    rad = int(K * 4)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=rad, fill=255)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    od = ImageDraw.Draw(out)
    od.rounded_rectangle((0, 0, w - 1, h - 1), radius=rad, outline=(1, 3, 7, 255), width=int(K * 1.2))
    od.rounded_rectangle((int(K * 1.2), int(K * 1.2), w - 1 - int(K * 1.2), h - 1 - int(K * 1.2)),
                         radius=rad - int(K * 1.2), outline=(70, 130, 190, 70), width=int(K * 0.6))

    out = out.resize((FW * S, FH * S), Image.LANCZOS)
    out.save(OUT, optimize=True)
    print(OUT, out.size)


if __name__ == "__main__":
    main()
