"""Minimal stdlib WAV I/O (float32 write; PCM16/24/32 + float32 read).

Copy into your plugin's tools/ directory next to render_test.py.
"""
import array
import struct


def write_wav_f32(path, srate, channels):
    """channels: list of equal-length float sequences (one per channel)."""
    nch = len(channels)
    nfr = len(channels[0])
    inter = array.array("f")
    for fr in range(nfr):
        for ch in channels:
            inter.append(ch[fr])
    raw = inter.tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(raw)) + b"WAVE")
        f.write(struct.pack("<4sIHHIIHH", b"fmt ", 16, 3, nch, srate,
                            srate * nch * 4, nch * 4, 32))
        f.write(b"data" + struct.pack("<I", len(raw)))
        f.write(raw)


def read_wav(path):
    """Returns (srate, [ch0, ch1, ...]) with samples as floats in -1..1."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file: %s" % path)
    pos = 12
    fmt_body = raw = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        sz = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + sz]
        if cid == b"fmt ":
            fmt_body = body
        elif cid == b"data":
            raw = body
        pos += 8 + sz + (sz & 1)
    if fmt_body is None or raw is None:
        raise ValueError("missing fmt/data chunk: %s" % path)
    tag, nch, srate, _, _, bits = struct.unpack("<HHIIHH", fmt_body[:16])
    if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: real tag in the GUID
        tag = struct.unpack("<H", fmt_body[24:26])[0]
    if tag == 3 and bits == 32:
        vals = array.array("f")
        vals.frombytes(raw[: len(raw) // 4 * 4])
        flat = list(vals)
    elif tag == 1 and bits == 16:
        vals = array.array("h")
        vals.frombytes(raw[: len(raw) // 2 * 2])
        flat = [v / 32768.0 for v in vals]
    elif tag == 1 and bits == 24:
        flat = []
        for i in range(0, len(raw) - 2, 3):
            v = raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16)
            if v >= 1 << 23:
                v -= 1 << 24
            flat.append(v / 8388608.0)
    elif tag == 1 and bits == 32:
        vals = array.array("i")
        vals.frombytes(raw[: len(raw) // 4 * 4])
        flat = [v / 2147483648.0 for v in vals]
    else:
        raise ValueError("unsupported wav format tag=%d bits=%d" % (tag, bits))
    chans = [flat[c::nch] for c in range(nch)]
    return srate, chans
