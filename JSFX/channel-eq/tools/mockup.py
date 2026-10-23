#!/usr/bin/env python3
"""Panel mockup for Magnolius_ChannelEQ.jsfx, rendered from the real kit PNGs.

    python3 tools/mockup.py [outdir]

Writes three PNGs: curve shown, curve hidden, and a "played" state with
boosts and cuts.  Coordinates are the plugin's logical pixels; everything is
drawn at 2x like the kit's artwork.  Edit the layout constants here first,
look at the result, then carry them into the .jsfx.  Fonts: Arial, as the kit
sets gk_font.

The curve is a rough sketch (a plain RBJ-style bell / shelf per band), only
there to show how the graph looks; it is not the plugin's DSP.

Knob markers: a ring of ticks outside each gain and frequency knob.  The knob
sweeps -135..+135 degrees from straight up, like the kit's artwork.  Gain
knobs get "-  0  +" and a tick every quarter turn.  Frequency knobs get a tick
at every printed legend value, placed on the knob's own scale, and a label on
as many of them as fit.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, "..", "gui_kit")
X = 2                                   # artwork scale
BG = (38, 40, 43)
FG = (217, 220, 224)
DIM = (153, 158, 168)
TICK = (112, 117, 126)
ACC = {"cyan": (38, 200, 230), "green": (61, 220, 132), "orange": (240, 150, 40)}

W = 2 * 10 + 6 * 104 + 5 * 10
COL_W, GAP, MARGIN = 104, 10, 10
GRAPH_Y, GRAPH_H = 40, 136
BAND_H = 276
FOOT = 32
ROW0, ROW1, ROW2 = 42, 122, 202         # knob tops, relative to the panel top
H_CURVE = GRAPH_Y + GRAPH_H + 10 + BAND_H + FOOT
H_HIDE = GRAPH_Y + BAND_H + FOOT
KX, CX = (104 - 64) / 2, 104 / 2          # knob left edge and column centre
SWEEP = 135.0                           # degrees either side of straight up


def font(px, bold=False):
    name = "Arial_Bold.ttf" if bold else "Arial.ttf"
    for d in ("/usr/share/fonts/truetype/msttcorefonts/",
              "/usr/share/fonts/truetype/liberation/"):
        p = d + name
        if os.path.exists(p):
            return ImageFont.truetype(p, int(round(px * X)))
    return ImageFont.load_default()


F1, F2, F3 = font(11), font(13, True), font(9)


def load(name):
    return Image.open(os.path.join(KIT, name)).convert("RGBA")


IMG = {n: load(n + ".png") for n in
       ("panel_tile", "header_bar", "value_field", "dropdown",
        "button_cyan", "button_green", "button_orange",
        "knob_cyan_grid", "knob_cyan_bipolar_grid", "knob_green_grid",
        "knob_orange_grid", "logo_magnolius_grey")}


class Canvas:
    def __init__(self, w, h):
        self.im = Image.new("RGBA", (w * X, h * X), BG + (255,))
        self.d = ImageDraw.Draw(self.im)

    def paste(self, img, x, y, w, h):
        img = img.resize((int(round(w * X)), int(round(h * X))), Image.LANCZOS)
        self.im.alpha_composite(img, (int(round(x * X)), int(round(y * X))))

    def nine(self, img, b, bl, x, y, w, h):
        """9-slice: b = source border px, bl = destination border (logical)."""
        sw, sh = img.size
        D = int(round(bl * X))
        X0, Y0 = int(round(x * X)), int(round(y * X))
        X3, Y3 = int(round((x + w) * X)), int(round((y + h) * X))
        X1, X2, Y1, Y2 = X0 + D, X3 - D, Y0 + D, Y3 - D
        src = [0, b, sw - b, sw], [0, b, sh - b, sh]
        dst = [X0, X1, X2, X3], [Y0, Y1, Y2, Y3]
        for j in range(3):
            for i in range(3):
                box = (src[0][i], src[1][j], src[0][i + 1], src[1][j + 1])
                dw, dh = dst[0][i + 1] - dst[0][i], dst[1][j + 1] - dst[1][j]
                if dw > 0 and dh > 0:
                    self.im.alpha_composite(
                        img.crop(box).resize((dw, dh), Image.LANCZOS),
                        (dst[0][i], dst[1][j]))

    def text(self, x, y, s, f=F1, col=FG):
        self.d.text((x * X, y * X), s, font=f, fill=col)

    def text_c(self, cx, y, s, f=F1, col=FG):
        w = self.d.textlength(s, font=f)
        self.d.text((cx * X - w / 2, y * X), s, font=f, fill=col)

    def text_mid(self, cx, cy, s, f=F3, col=DIM):
        """Text centred on a point (the marker labels)."""
        w = self.d.textlength(s, font=f)
        bb = f.getbbox("0")
        self.d.text((cx * X - w / 2, cy * X - (bb[1] + bb[3]) / 2), s, font=f, fill=col)

    def text_box(self, x, y, w, h, s, f=F1, col=FG, align="c", pad=0):
        """Text vertically centred in a box (like gfx_drawstr with flags)."""
        tw = self.d.textlength(s, font=f)
        bb = f.getbbox("Ag")
        ty = y * X + (h * X - (bb[3] - bb[1])) / 2 - bb[1]
        tx = {"c": (x + w / 2) * X - tw / 2, "l": (x + pad) * X,
              "r": (x + w - pad) * X - tw}[align]
        self.d.text((tx, ty), s, font=f, fill=col)

    def rect(self, x, y, w, h, col):
        self.d.rectangle([x * X, y * X, (x + w) * X - 1, (y + h) * X - 1], fill=col)

    def line(self, x0, y0, x1, y1, col, wpx=1):
        self.d.line([x0 * X, y0 * X, x1 * X, y1 * X], fill=col, width=max(1, int(wpx * X)))


def panel(c, x, y, w, h, title):
    c.nine(IMG["panel_tile"], 8, 4, x, y, w, h)
    header(c, x, y, w, 22, title)


def header(c, x, y, w, h, title):
    c.paste(IMG["header_bar"], x, y, w, h)
    c.text_box(x + 8, y, w - 8, h, title, F2, FG, "l")


def knob(c, x, y, t, bipolar=False, accent="cyan"):
    img = IMG["knob_cyan_bipolar_grid" if bipolar else "knob_%s_grid" % accent]
    n, cols = 64, 8
    fw = img.size[0] // cols
    i = max(0, min(n - 1, int(round(t * (n - 1)))))
    fr = img.crop(((i % cols) * fw, (i // cols) * fw, (i % cols) * fw + fw,
                   (i // cols) * fw + fw))
    c.paste(fr, x, y, 64, 64)


def field(c, x, y, w, h, s):
    c.nine(IMG["value_field"], 8, 4, x, y, w, h)
    c.text_box(x, y, w, h, s, F1, FG, "c")


def button(c, x, y, w, h, label, state, accent="cyan"):
    img = IMG["button_" + accent]
    fh = img.size[1] // 3
    fr = img.crop((0, state * fh, img.size[0], (state + 1) * fh))
    c.paste(fr, x, y, w, h)
    c.text_box(x, y, w, h, label, F1, (20, 23, 26) if state == 2 else FG, "c")


def dropdown(c, x, y, w, h, label):
    img = IMG["dropdown"]
    sw, sh = img.size
    L, R = 12, 32
    c.paste(img.crop((0, 0, L, sh)), x, y, L / 2, h)
    c.paste(img.crop((L, 0, sw - R, sh)), x + L / 2, y, w - L / 2 - R / 2, h)
    c.paste(img.crop((sw - R, 0, sw, sh)), x + w - R / 2, y, R / 2, h)
    c.text_box(x, y, w - 16, h, label, F1, FG, "l", 6)


# ---------------------------------------------------------------- knob markers
# Numbers only, spread evenly round the knob's 270 degree sweep, no tick lines.
# Each label sits a fixed gap outside the knob art: the radius grows with the
# label's own extent along its direction, so wide numbers at 3 and 9 o'clock
# clear the knob as well as narrow ones at the top.
R_GAP = 33.0
CAP_H = 6.5                             # cap height of the 9 px marker font


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.sin(a), cy - r * math.cos(a)


def ang(t):
    return -SWEEP + 2 * SWEEP * t


REACH = [0.0]                           # widest label extent seen, for the layout check


def ring(c, cx, cy, labels):
    n = len(labels)
    for k, lab in enumerate(labels):
        a = ang(k / (n - 1))
        w = c.d.textlength(lab, font=F3) / X
        s, co = abs(math.sin(math.radians(a))), abs(math.cos(math.radians(a)))
        r = R_GAP + s * w / 2 + co * CAP_H / 2
        tx, ty = polar(cx, cy, r, a)
        REACH[0] = max(REACH[0], abs(tx - cx) + w / 2)
        c.text_mid(tx, ty, lab)


# printed legends, evenly spread; the knob law is a piecewise curve through them
LEG_GAIN = ["-", "0", "+"]
LEG_HF = ["1.5", "2", "5", "8", "10", "11", "16"]
LEG_HMF = [".6", ".8", "1.5", "3", "4.5", "6", "7"]
LEG_LMF = [".2", ".3", ".8", "1", "1.5", "2", "2.5"]
LEG_Q = [".5", "1", "1.5", "2", "3"]
LEG_LF = ["30", "50", "100", "200", "300", "450"]
LEG_HPF = ["OUT", "20", "70", "120", "200", "300", "350"]
LEG_LPF = ["3", "3.5", "4", "5", "8", "12", "OUT"]      # OUT at the clockwise stop


# ---------------------------------------------------------------- curve sketch
def bell(f, f0, q, g):
    A = 10 ** (g / 40)
    x = f / f0
    num = complex(1 - x * x, x * A / q)
    den = complex(1 - x * x, x / (A * q))
    return 20 * math.log10(abs(num / den))


def hshelf(f, f0, g):
    A = 10 ** (g / 40)
    s = complex(0, f / f0)
    num = A * (A * s * s + math.sqrt(A) * s / 0.72 + 1)
    den = (A + math.sqrt(A) * s / 0.72 * 1 + s * s)
    return 20 * math.log10(abs(num / den)) if den else 0


def lshelf(f, f0, g):
    A = 10 ** (g / 40)
    s = complex(0, f / f0)
    num = A * (s * s + math.sqrt(A) * s / 0.72 + A)
    den = (A * s * s + math.sqrt(A) * s / 0.72 + 1)
    return 20 * math.log10(abs(num / den))


def curve(c, x, y, w, h, st):
    c.rect(x, y, w, h, (26, 27, 30))
    lo, hi = 20.0, 20000.0

    def fx(f):
        return x + w * math.log(f / lo) / math.log(hi / lo)

    def dy(db):
        return y + h / 2 - db * (h / 2) / 24

    for db in (-18, -12, -6, 0, 6, 12, 18):
        col = (74, 78, 86) if db == 0 else (46, 48, 53)
        c.rect(x, dy(db), w, 1, col)
        c.text(x + 3, dy(db) - 11, "%+d" % db if db else "0", F3, DIM)
    for f in (50, 100, 200, 500, 1000, 2000, 5000, 10000):
        c.rect(fx(f), y, 1, h, (46, 48, 53))
        c.text(fx(f) + 3, y + h - 12, ("%dk" % (f // 1000)) if f >= 1000 else str(f), F3, DIM)
    pts, bands = [], []
    n = int(w) * 2
    for i in range(n + 1):
        f = lo * (hi / lo) ** (i / n)
        db = 0.0
        parts = []
        for kind, f0, q, g in st["bands"]:
            v = {"hs": lambda: hshelf(f, f0, g), "ls": lambda: lshelf(f, f0, g),
                 "b": lambda: bell(f, f0, q, g)}[kind]() if abs(g) > 0.01 else 0.0
            parts.append(v)
            db += v
        if st["hpf"]:
            db += -10 * math.log10(1 + (st["hpf"] / f) ** 6)
        if st["lpf"]:
            db += -10 * math.log10(1 + (f / st["lpf"]) ** 4)
        pts.append((fx(f) * X, dy(max(-24, min(24, db))) * X))
        bands.append(parts)
    for k in range(4):
        if abs(st["bands"][k][3]) < 0.01:
            continue
        line = [(p[0], dy(max(-24, min(24, b[k]))) * X) for p, b in zip(pts, bands)]
        c.d.line(line, fill=(30, 110, 126), width=X)
    c.d.line(pts, fill=ACC["cyan"], width=2 * X)
    c.d.rectangle([x * X, y * X, (x + w) * X, (y + h) * X], outline=(80, 84, 92))


# ---------------------------------------------------------------- the panel
def render(show_curve, st):
    H = H_CURVE if show_curve else H_HIDE
    c = Canvas(W, H)

    # header + controls
    header(c, MARGIN, MARGIN, W - 2 * MARGIN, 22, "CHANNEL EQ")
    r = W - MARGIN
    button(c, r - 18, 13, 18, 16, "?", 0)
    dropdown(c, r - 88, 13, 64, 16, "Fit")
    button(c, r - 142, 13, 48, 16, "Curve", 2 if show_curve else 0)
    dropdown(c, r - 240, 13, 92, 16, st["law"])
    c.text(r - 240 - 52, 15, "Gain law", F1, DIM)

    y0 = MARGIN + 22 + 8
    if show_curve:
        panel(c, MARGIN, GRAPH_Y, W - 2 * MARGIN, GRAPH_H, "RESPONSE")
        curve(c, MARGIN + 10, GRAPH_Y + 30, W - 2 * MARGIN - 20, GRAPH_H - 40, st)
        y0 = GRAPH_Y + GRAPH_H + 10
    else:
        y0 = GRAPH_Y

    cols = [MARGIN + i * (COL_W + GAP) for i in range(6)]
    k0, k1, k2 = y0 + ROW0, y0 + ROW1, y0 + ROW2

    # FILTERS (green)
    px = cols[0]
    panel(c, px, y0, COL_W, BAND_H, "FILTERS")
    knob(c, px + KX, k0, st["hpf_t"], accent="green")
    ring(c, px + CX, k0 + 32, LEG_HPF)
    knob(c, px + KX, k1, st["lpf_t"], accent="green")
    ring(c, px + CX, k1 + 32, LEG_LPF)
    button(c, px + 8, k1 + 82, COL_W - 16, 18, "Filters In", 2 if st["filt_in"] else 0, "green")
    button(c, px + 8, k1 + 108, COL_W - 16, 18, "EQ In", 2 if st["eq_in"] else 0, "cyan")

    # bands (cyan)
    names = ["LF", "LMF", "HMF", "HF"]
    legends = [LEG_LF, LEG_LMF, LEG_HMF, LEG_HF]
    for i, nm in enumerate(names):
        px = cols[i + 1]
        panel(c, px, y0, COL_W, BAND_H, nm)
        knob(c, px + KX, k0, (st["g"][i] + 1) / 2, bipolar=True)
        ring(c, px + CX, k0 + 32, LEG_GAIN)
        knob(c, px + KX, k1, st["f_t"][i])
        ring(c, px + CX, k1 + 32, legends[i])
        if nm in ("HMF", "LMF"):
            knob(c, px + KX, k2, st["q_t"][i])
            ring(c, px + CX, k2 + 32, LEG_Q)
            button(c, px + COL_W - 46, y0 + 3, 40, 16, "x 3" if nm == "HMF" else "/ 3",
                   2 if st["sw"][i] else 0)

    # SATURATION (orange)
    px = cols[5]
    panel(c, px, y0, COL_W, BAND_H, "SATURATION")
    knob(c, px + KX, k0, st["sat_t"], accent="orange")
    field(c, px + (COL_W - 60) / 2, k0 + 76, 60, 16, st["sat_s"])
    tube = st["sat_mode"] == "Tube"
    wc = 54                             # "Console" needs more room than "Tube"
    button(c, px + 8, k0 + 112, wc, 18, "Console", 0 if tube else 2, "orange")
    button(c, px + 8 + wc, k0 + 112, COL_W - 16 - wc, 18, "Tube", 2 if tube else 0, "orange")
    c.text_c(px + CX, k0 + 142, "no effect yet", F1, DIM)

    # footer
    c.text(MARGIN, H - 22, "v0.1", F3, (89, 94, 102))
    lg = IMG["logo_magnolius_grey"]
    lh = 14
    lw = lh * 512 / 101
    c.paste(lg, W - MARGIN - lw, H - 24, lw, lh)
    return c.im.convert("RGB")


def state(**kw):
    s = dict(
        law="Circuit", filt_in=True, eq_in=True,
        hpf=0, lpf=0, hpf_t=0.0, lpf_t=1.0,
        g=[0, 0, 0, 0],
        f_t=[0.4, 0.45, 0.5, 0.6],
        q_t=[0, 0.3, 0.3, 0],
        sw=[0, 0, 0, 0], sat_s="0 %", sat_t=0.0, sat_mode="Console",
        bands=[("ls", 100, 0.72, 0), ("b", 800, 1.0, 0), ("b", 2000, 1.0, 0),
               ("hs", 8000, 0.72, 0)],
    )
    s.update(kw)
    return s


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    flat = state()
    played = state(
        hpf=80, hpf_t=0.42, lpf_t=1.0,
        g=[0.35, 0.7, -0.4, 0.55],
        f_t=[0.3, 0.35, 0.62, 0.7],
        q_t=[0, 0.2, 0.55, 0],
        sw=[0, 1, 0, 0], sat_s="35 %", sat_t=0.35, sat_mode="Tube",
        bands=[("ls", 60, 0.72, 4.1), ("b", 240, 0.9, 13.6),
               ("b", 3200, 1.8, -7.8), ("hs", 9000, 0.72, 6.2)],
    )
    render(True, flat).save(os.path.join(out, "mockup_curve.png"))
    render(False, flat).save(os.path.join(out, "mockup_hidden.png"))
    render(True, played).save(os.path.join(out, "mockup_played.png"))
    print("wrote", out, "sizes", (W, H_CURVE), (W, H_HIDE), "widest label reach %.1f of %.1f" % (REACH[0], COL_W / 2))


if __name__ == "__main__":
    main()
