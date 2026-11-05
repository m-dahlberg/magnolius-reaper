"""Reference model of Magnolius_VocalRider.jsfx, sample for sample.

Mirrors @init / recalc() / @sample. Edit it together with the .jsfx: the
render tests compare the two, so a change to one alone fails them.

    out_l, out_r, gains = model.run([left, right], srate, **sliders)
"""
import math

NAMES = ["target", "max_boost", "speed", "floor", "sc_infl", "win_v",
         "win_sc", "trim", "max_cut", "amount", "lookahead", "breath_guard",
         "breath_thr", "tail_lift"]
DEFAULTS = dict(target=-18.0, max_boost=6.0, speed=300.0, floor=-50.0,
                sc_infl=0.0, win_v=50.0, win_sc=200.0, trim=0.0,
                max_cut=6.0, amount=100.0, lookahead=0.0,
                breath_guard=1, breath_thr=-8.0, tail_lift=100.0)

EPS = 0.000000000001
RING = 262144
GATE_HYST = 3.0
GATE_HOLD = 0.15
GAP_RELEASE = 2.0
REL_TAU = 1.0
W_KNEE = 6.0
W_GATE = 12.0
PK_TAU = 0.5
SLOPE_TAU = 0.02
S_FULL50 = -30.0
S_ZERO50 = -60.0
TAIL_FALL = 0.2
TAIL_POW = 2.5
BR_LP = 1500.0
BR_HP = 3000.0
BR_TAU = 0.01
BR_DEPTH = 12.0
BR_ATT = 0.01
BR_REL = 0.05
BR_ANTIC = 0.02


def rbj(kind, f, srate):
    w = 2 * math.pi * min(f, srate * 0.45) / srate
    c = math.cos(w)
    al = math.sin(w) / (2 * 0.7071)
    a0 = 1 + al
    if kind == "lp":
        b0 = (1 - c) / 2 / a0
        b1 = (1 - c) / a0
    else:
        b0 = (1 + c) / 2 / a0
        b1 = -(1 + c) / a0
    return b0, b1, b0, -2 * c / a0, (1 - al) / a0


def lookahead_samples(ms, srate):
    return min(int(math.floor(ms * 0.001 * srate + 0.5)), RING - 1)


def run(chans, srate, target_fn=None, **kw):
    """target_fn(n) -> target dB at sample n overrides the Target slider
    (mimics automation; only exact when it changes on block boundaries)."""
    p = dict(DEFAULTS, **kw)
    exp = math.exp
    k_v = 1 - exp(-1 / (srate * p["win_v"] * 0.001))
    k_sc = 1 - exp(-1 / (srate * p["win_sc"] * 0.001))
    k_cut = 1 - exp(-1 / (srate * p["speed"] * 0.001 * 0.5))
    k_boost = 1 - exp(-1 / (srate * p["speed"] * 0.001 * 0.5 * 1.5))
    k_rel = 1 - exp(-1 / (srate * REL_TAU))
    k_pk = 1 - exp(-1 / (srate * PK_TAU))
    k_sl = 1 - exp(-1 / (srate * SLOPE_TAU))
    s_zero = S_ZERO50 * 50 / p["win_v"]
    s_full = S_FULL50 * 50 / p["win_v"]
    lb0, lb1, lb2, la1, la2 = rbj("lp", BR_LP, srate)
    hb0, hb1, hb2, ha1, ha2 = rbj("hp", BR_HP, srate)
    k_br = 1 - exp(-1 / (srate * BR_TAU))
    k_bsa = 1 - exp(-1 / (srate * BR_ATT))
    k_bsr = 1 - exp(-1 / (srate * BR_REL))
    hold_n = math.floor(GATE_HOLD * srate + 0.5)
    release_n = math.floor(GAP_RELEASE * srate + 0.5)
    amt = p["amount"] * 0.01
    tail_w = (p["tail_lift"] * 0.01) ** TAIL_POW
    trim = 10 ** (p["trim"] / 20)
    L = lookahead_samples(p["lookahead"], srate)
    A = min(L, math.floor(BR_ANTIC * srate + 0.5))
    guard = p["breath_guard"] >= 0.5
    no_boost = p["breath_guard"] >= 1.5
    thr = p["breath_thr"]
    floor_db, mb, mc = p["floor"], p["max_boost"], p["max_cut"]
    sc_infl = p["sc_infl"]

    left, right = chans[0], chans[1]
    scl = chans[2] if len(chans) > 2 else None
    scr = chans[3] if len(chans) > 3 else None
    n = len(left)
    rms_v = rms_sc = 0.0
    g1 = g2 = 0.0
    gated = 1
    pk = -150.0
    slope = 0.0
    voc_prev = 10 * math.log(EPS) / math.log(10)
    lx1 = lx2 = ly1 = ly2 = hx1 = hx2 = hy1 = hy2 = 0.0
    e_lo = e_hi = e_sh = 0.0
    bs = 0.0
    ghold = 0.0
    flags = [0] * n
    below_n = 0
    gap_n = 0
    log10 = math.log(10)
    out_l = [0.0] * n
    out_r = [0.0] * n
    gains = [0.0] * n
    for i in range(n):
        s0, s1 = left[i], right[i]
        s2 = scl[i] if scl else 0.0
        s3 = scr[i] if scr else 0.0
        tgt = target_fn(i) if target_fn else p["target"]
        e_v = max(s0 * s0, s1 * s1)
        e_sc = max(s2 * s2, s3 * s3)
        rms_v += k_v * (e_v - rms_v)
        rms_sc += k_sc * (e_sc - rms_sc)
        voc_db = 10 * math.log(rms_v + EPS) / log10
        sc_db = 10 * math.log(rms_sc + EPS) / log10
        slope += k_sl * ((voc_db - voc_prev) * srate - slope)
        voc_prev = voc_db

        x = (s0 + s1) * 0.5
        y = lb0 * x + lb1 * lx1 + lb2 * lx2 - la1 * ly1 - la2 * ly2
        lx2, lx1, ly2, ly1 = lx1, x, ly1, y
        e_lo += k_br * (y * y - e_lo)
        y = hb0 * x + hb1 * hx1 + hb2 * hx2 - ha1 * hy1 - ha2 * hy2
        hx2, hx1, hy2, hy1 = hx1, x, hy1, y
        e_hi += k_br * (y * y - e_hi)
        e_sh += k_br * (e_v - e_sh)
        sh_db = 10 * math.log(e_sh + EPS) / log10
        breath = (guard and sh_db < pk - BR_DEPTH and sh_db > -90 and
                  10 * math.log((e_hi + EPS) / (e_lo + EPS)) / log10 > thr)
        flags[i] = 1 if breath else 0

        if voc_db > floor_db:
            gated = 0
            below_n = 0
        elif gated == 0:
            below_n = below_n + 1 if voc_db < floor_db - GATE_HYST else 0
            if below_n >= hold_n:
                gated = 1
                gap_n = 0

        if gated:
            gap_n += 1
            if gap_n > release_n:
                if g1 > 0:
                    g1 -= k_rel * g1
                if g2 > 0:
                    g2 -= k_rel * g2
        else:
            sc_amt = min(max((sc_db - tgt) / 12, 0), 1)
            eff = tgt + sc_infl * sc_amt
            err = eff - voc_db
            want = min(max(amt * err, -mc), mb)
            if breath:
                w = 0.0
            else:
                pk = voc_db if voc_db > pk else pk + k_pk * (voc_db - pk)
                d = pk - voc_db
                if d <= W_KNEE:
                    w = 1.0
                elif d >= W_GATE:
                    w = 0.0
                else:
                    w = 0.5 + 0.5 * math.cos(math.pi * (d - W_KNEE) / (W_GATE - W_KNEE))
                w *= min(max((slope - s_zero) / (s_full - s_zero), 0), 1)
            if want > g1:
                fall = min(max(slope / (s_full * TAIL_FALL), 0.0), 1.0)
                w *= 1 - (1 - tail_w) * fall
            g1 += (k_cut if want < g1 else k_boost) * w * (want - g1)
            g2 += (k_cut if g1 < g2 else k_boost) * (g1 - g2)
        j = i - L + A
        f = flags[j] if j >= 0 else 0
        bs += (k_bsa if f > bs else k_bsr) * (f - bs)
        if bs < 0.01:
            ghold = g2
        cap = min(ghold, 0.0) if no_boost else ghold
        g_out = g2 - bs * max(g2 - cap, 0.0)
        gains[i] = g_out
        g = 10 ** (g_out / 20) * trim
        j = i - L
        out_l[i] = (left[j] if j >= 0 else 0.0) * g
        out_r[i] = (right[j] if j >= 0 else 0.0) * g
    return out_l, out_r, gains
