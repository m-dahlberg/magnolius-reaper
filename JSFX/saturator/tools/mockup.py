#!/usr/bin/env python3
"""Panel mockup for Magnolius_Saturator.jsfx, rendered from the real kit PNGs.

    python3 tools/mockup.py [outdir]

Writes two PNGs: a neutral state and a driven state.  Coordinates are the
plugin's logical pixels; everything is drawn at 2x like the kit's artwork.
Edit the layout constants here first, look at the result, then carry them into
the .jsfx.  Fonts: Arial, as the kit sets gk_font.

The meter levels are made-up numbers, only there to show how the meters look.
"""
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

# ---------------------------------------------------------------- layout
W = 720
MARGIN, GAP = 10, 10
PANEL_Y = 40
KNOB_Y = 34                             # knob tops, relative to the panel top
LABEL_Y = KNOB_Y + 64 + 4               # knob label
FIELD_Y = LABEL_Y + 16                  # value field
ROW_Y = FIELD_Y + 28                    # Knee buttons / Auto Gain row
PANEL_H = ROW_Y + 18 + 12
FOOT = 32
H = PANEL_Y + PANEL_H + FOOT
COL = 80                                # one knob column
FIELD_W = 64
SIDE_W = 208                            # DRIVE and OUTPUT
MID_W = W - 2 * MARGIN - 2 * SIDE_W - 2 * GAP   # COLOUR
METER_W = 10
METER_Y0, METER_Y1 = KNOB_Y - 2, ROW_Y + 2      # meter span; its label sits in the button row
METER_LO, METER_HI = -60.0, 6.0
METER_TICKS = (0, -12, -24, -48)

PX_DRIVE = MARGIN
PX_COLOUR = PX_DRIVE + SIDE_W + GAP
PX_OUT = PX_COLOUR + MID_W + GAP


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
        "button_cyan", "button_orange", "knob_cyan_grid", "knob_orange_grid",
        "bar_cyan_grid", "logo_magnolius_grey")}


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

    def text_box(self, x, y, w, h, s, f=F1, col=FG, align="c", pad=0):
        """Text vertically centred in a box (like gfx_drawstr with flags)."""
        tw = self.d.textlength(s, font=f)
        bb = f.getbbox("Ag")
        ty = y * X + (h * X - (bb[3] - bb[1])) / 2 - bb[1]
        tx = {"c": (x + w / 2) * X - tw / 2, "l": (x + pad) * X,
              "r": (x + w - pad) * X - tw}[align]
        self.d.text((tx, ty), s, font=f, fill=col)

    def textw(self, s, f=F1):
        return self.d.textlength(s, font=f) / X

    def rect(self, x, y, w, h, col):
        self.d.rectangle([x * X, y * X, (x + w) * X - 1, (y + h) * X - 1], fill=col)


def panel(c, x, y, w, h, title):
    c.nine(IMG["panel_tile"], 8, 4, x, y, w, h)
    header(c, x, y, w, 22, title)


def header(c, x, y, w, h, title):
    c.paste(IMG["header_bar"], x, y, w, h)
    c.text_box(x + 8, y, w - 8, h, title, F2, FG, "l")


def grid_frame(img, t, n=64, cols=8):
    fw = img.size[0] // cols
    fh = img.size[1] // ((n + cols - 1) // cols)
    i = max(0, min(n - 1, int(round(t * (n - 1)))))
    return img.crop(((i % cols) * fw, (i // cols) * fh,
                     (i % cols) * fw + fw, (i // cols) * fh + fh))


def knob(c, cx, y, t, accent):
    c.paste(grid_frame(IMG["knob_%s_grid" % accent], t), cx - 32, y, 64, 64)


def field(c, x, y, w, h, s, col=FG):
    c.nine(IMG["value_field"], 8, 4, x, y, w, h)
    c.text_box(x, y, w, h, s, F1, col, "c")


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


def column(c, cx, py, t, label, value, accent):
    """Knob, label and value field centred on cx."""
    knob(c, cx, py + KNOB_Y, t, accent)
    c.text_c(cx, py + LABEL_Y, label, F1, DIM)
    field(c, cx - FIELD_W / 2, py + FIELD_Y, FIELD_W, 16, value)


def meter(c, x, py, peak_db, hold_db, label, ticks_right):
    """Vertical bar meter: the kit bar strip, dB ticks on one side, a peak-hold
    line and the label underneath."""
    y0, y1 = py + METER_Y0, py + METER_Y1
    h = y1 - y0

    def ydb(db):
        return y1 - h * (db - METER_LO) / (METER_HI - METER_LO)

    t = (peak_db - METER_LO) / (METER_HI - METER_LO)
    c.rect(x - 1, y0 - 1, METER_W + 2, h + 2, (26, 27, 30))
    c.paste(grid_frame(IMG["bar_cyan_grid"], t), x, y0, METER_W, h)
    if hold_db > METER_LO:
        c.rect(x, ydb(hold_db), METER_W, 1, FG)
    for db in METER_TICKS:
        s = "%d" % db
        tw = c.textw(s, F3)
        ty = ydb(db) - 5.5
        if ticks_right:
            c.rect(x + METER_W + 1, ydb(db), 3, 1, TICK)
            c.text(x + METER_W + 6, ty, s, F3, DIM)
        else:
            c.rect(x - 4, ydb(db), 3, 1, TICK)
            c.text(x - 6 - tw, ty, s, F3, DIM)
    c.text_c(x + METER_W / 2, y1 + 4, label, F3, DIM)


# ---------------------------------------------------------------- the panel
def render(st):
    c = Canvas(W, H)

    # header: name left; oversampling, scale and help right
    header(c, MARGIN, MARGIN, W - 2 * MARGIN, 22, "SATURATOR")
    r = W - MARGIN
    button(c, r - 18, 13, 18, 16, "?", 0)
    dropdown(c, r - 88, 13, 64, 16, "Fit")
    dropdown(c, r - 146, 13, 48, 16, st["os"])
    c.text(r - 146 - 6 - c.textw("Oversampling", F1), 15, "Oversampling", F1, DIM)

    py = PANEL_Y

    # DRIVE: input meter on the left, then Input and Slew
    panel(c, PX_DRIVE, py, SIDE_W, PANEL_H, "DRIVE")
    meter(c, PX_DRIVE + 12, py, st["in_db"], st["in_hold"], "IN", True)
    c1 = PX_DRIVE + 44 + COL / 2
    column(c, c1, py, (st["input"] + 18) / 36, "Input", "%+.1f dB" % st["input"], "cyan")
    column(c, c1 + COL, py, st["slew"] / 100, "Slew", "%.0f %%" % st["slew"], "cyan")

    # COLOUR: Asymmetric, Symmetric, Knee
    panel(c, PX_COLOUR, py, MID_W, PANEL_H, "COLOUR")
    cc = PX_COLOUR + MID_W / 2
    column(c, cc - 50, py, st["asym"] / 100, "Asymmetric", "%.0f %%" % st["asym"], "orange")
    column(c, cc + 50, py, st["sym"] / 100, "Symmetric", "%.0f %%" % st["sym"], "orange")
    bw = 60
    bx = cc - 1.5 * bw
    for i, nm in enumerate(("Soft", "Medium", "Hard")):
        button(c, bx + i * bw, py + ROW_Y, bw, 18, nm, 2 if st["knee"] == i else 0, "orange")

    # OUTPUT: Mix and Output, Auto Gain and the level-change readout, meter right
    panel(c, PX_OUT, py, SIDE_W, PANEL_H, "OUTPUT")
    c2 = PX_OUT + 4 + COL / 2
    column(c, c2, py, st["mix"] / 100, "Mix", "%.0f %%" % st["mix"], "cyan")
    column(c, c2 + COL, py, (st["output"] + 18) / 36, "Output", "%+.1f dB" % st["output"], "cyan")
    button(c, c2 - FIELD_W / 2 - 4, py + ROW_Y, FIELD_W + 8, 18, "Auto Gain",
           2 if st["auto"] else 0, "cyan")
    field(c, c2 + COL - FIELD_W / 2, py + ROW_Y + 1, FIELD_W, 16,
          "Δ %+.1f dB" % st["delta"], DIM)
    meter(c, PX_OUT + SIDE_W - 12 - METER_W, py, st["out_db"], st["out_hold"], "OUT", False)

    # footer
    c.text(MARGIN, H - 22, "v0.1   latency %d smp" % st["lat"], F3, (89, 94, 102))
    lg = IMG["logo_magnolius_grey"]
    lh = 14
    lw = lh * 512 / 101
    c.paste(lg, W - MARGIN - lw, H - 24, lw, lh)
    return c.im.convert("RGB")


def state(**kw):
    s = dict(os="2x", input=0.0, slew=0.0, asym=0.0, sym=0.0, knee=1,
             output=0.0, auto=True, mix=100.0, delta=0.0, lat=24,
             in_db=-60.0, in_hold=-60.0, out_db=-60.0, out_hold=-60.0)
    s.update(kw)
    return s


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    neutral = state()
    driven = state(os="4x", input=6.0, slew=35.0, asym=40.0, sym=65.0, knee=2,
                   output=-1.5, mix=80.0, delta=-0.3, lat=37,
                   in_db=-5.0, in_hold=-2.1, out_db=-8.0, out_hold=-5.6)
    render(neutral).save(os.path.join(out, "mockup_neutral.png"))
    render(driven).save(os.path.join(out, "mockup_driven.png"))
    print("wrote", out, "size", (W, H), "colour panel", MID_W)


if __name__ == "__main__":
    main()
