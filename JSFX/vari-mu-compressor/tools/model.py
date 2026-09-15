"""Pure-Python mirror of Magnolius_VariMuCompressor.jsfx @init/@slider/@sample.

EDIT THIS AND Magnolius_VariMuCompressor.jsfx TOGETHER.  render_test.py's "model" test
renders the plugin and compares sample-for-sample against this; if they
disagree, one of the two is wrong -- do not loosen the tolerance to make it
pass.

Only the audio path is mirrored.  @gfx is not, and cannot be: offline
renders never run it.
"""
import math

LOG2DB = 8.6858896380650366     # 20/ln(10)
DB2LOG = 0.11512925464970229    # ln(10)/20
TINY = 1e-30

TCATK = [0.0002, 0.0002, 0.0004, 0.0008, 0.0002, 0.0004]
TCREL = [0.300, 0.800, 2.000, 5.000, 10.000, 25.000]

DEFAULTS = dict(lthr_db=0.0, rthr_db=0.0, lbias_pct=70.0, rbias_pct=70.0,
                lmakeup_db=0.0, rmakeup_db=0.0, agc_mode=2, ltc=1, rtc=1,
                lrms_us=100.0, rrms_us=100.0, ratio_max=20.0, sc_hz=20.0,
                link_pct=100.0, mix_pct=100.0, trim_db=0.0, hist_s=6.0)

# slider order in the .jsfx header, for building an .rpp slider line
ORDER = ["lthr_db", "rthr_db", "lbias_pct", "rbias_pct", "lmakeup_db",
         "rmakeup_db", "agc_mode", "ltc", "rtc", "lrms_us", "rrms_us",
         "ratio_max", "sc_hz", "link_pct", "mix_pct", "trim_db", "hist_s"]


class Det:
    """One detector chain -- mirrors the det() instance function."""

    def __init__(self):
        self.runave = 0.0
        self.rundb = 0.0
        self.gr = 0.0
        self.grv = 1.0

    def config(self, thr_db, bias_pct, tc, rms_us, srate):
        i = max(1, min(6, int(tc))) - 1
        self.threshv = math.exp(thr_db * DB2LOG)
        self.bias = 80.0 * bias_pct * 0.01
        self.atcoef = math.exp(-1.0 / (TCATK[i] * srate))
        self.relcoef = math.exp(-1.0 / (TCREL[i] * srate))
        self.rmscoef = math.exp(-1.0 / (max(rms_us, 1.0) * 1e-6 * srate))

    def step(self, x, capsc, ratio_max):
        sq = x * x
        self.runave = sq + self.rmscoef * (self.runave - sq)
        d = math.sqrt(max(0.0, self.runave))
        over = max(0.0, capsc * math.log(max(d, TINY) / self.threshv))
        if over > self.rundb:
            self.rundb = over + self.atcoef * (self.rundb - over)
        else:
            self.rundb = over + self.relcoef * (self.rundb - over)
        over = max(self.rundb, 0.0)
        if self.bias > 0:
            cr = 1.0 + (ratio_max - 1.0) * math.sqrt(over / self.bias)
        else:
            cr = ratio_max
        self.gr = -over * (cr - 1.0) / cr
        self.grv = math.exp(self.gr * DB2LOG) if self.gr < 0 else 1.0


def process(chL, chR, srate, **kw):
    """Returns (outL, outR) as lists. kw overrides DEFAULTS."""
    p = dict(DEFAULTS)
    p.update(kw)

    amode = int(p["agc_mode"])
    agc = amode & 1                              # 0 = L/R, 1 = Mid/Side
    capsc = LOG2DB if (amode & 2) else LOG2DB * 2.08136898

    left = Det()
    left.config(p["lthr_db"], p["lbias_pct"], p["ltc"], p["lrms_us"], srate)
    lmakeupv = math.exp(p["lmakeup_db"] * DB2LOG)

    right = Det()
    if agc:
        right.config(p["rthr_db"], p["rbias_pct"], p["rtc"], p["rrms_us"], srate)
        rmakeupv = math.exp(p["rmakeup_db"] * DB2LOG)
    else:
        # L/R: mirror the left chain's derived values, keep separate state
        right.threshv = left.threshv
        right.bias = left.bias
        right.atcoef = left.atcoef
        right.relcoef = left.relcoef
        right.rmscoef = left.rmscoef
        rmakeupv = lmakeupv

    link = p["link_pct"] * 0.01
    wet = p["mix_pct"] * 0.01
    dry = 1.0 - wet
    trimv = math.exp(p["trim_db"] * DB2LOG)
    sc_on = p["sc_hz"] > 20
    sc_a = math.exp(-2.0 * math.pi * p["sc_hz"] / srate)
    ratio_max = p["ratio_max"]

    hp0 = hp1 = px0 = px1 = 0.0
    outL = []
    outR = []
    for in0, in1 in zip(chL, chR):
        in0 = float(in0)
        in1 = float(in1)
        if agc:
            mid = (in0 + in1) * 0.5
            sid = (in0 - in1) * 0.5
            d0, d1 = mid, sid
        else:
            d0, d1 = in0, in1

        if sc_on:
            hp0 = sc_a * (hp0 + d0 - px0)
            px0 = d0
            d0 = hp0
            hp1 = sc_a * (hp1 + d1 - px1)
            px1 = d1
            d1 = hp1

        d0 = abs(d0)
        d1 = abs(d1)

        if not agc:
            dmx = max(d0, d1)
            d0 += link * (dmx - d0)
            d1 += link * (dmx - d1)

        left.step(d0, capsc, ratio_max)
        right.step(d1, capsc, ratio_max)

        if agc:
            mid *= left.grv * lmakeupv
            sid *= right.grv * rmakeupv
            w0 = mid + sid
            w1 = mid - sid
        else:
            w0 = in0 * left.grv * lmakeupv
            w1 = in1 * right.grv * rmakeupv

        outL.append((dry * in0 + wet * w0) * trimv)
        outR.append((dry * in1 + wet * w1) * trimv)
    return outL, outR
