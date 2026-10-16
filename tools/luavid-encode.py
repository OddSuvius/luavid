#!/usr/bin/env python3
"""luavid-encode: any ffmpeg-readable video -> Lua video modules (LVD1 stream).
usage: luavid-encode.py in out_dir [W] [H] [fps] [tol] [keyframe_sec] [max_sec] [QY] [QC]
Codec: YCbCr, Y at WxH, Cb/Cr at W/2 x H/2, uniformly quantized (QY, QC = step sizes).
Keyframe: each plane predicted from the previous element in raster order. Inter frame: predicted
from the previous frame (same element). Residuals with |r| <= tol are forced to 0. Residual stream
per plane is tokenized: 0x00-0x7F run of op+1 zeros | 0x80-0xBF op-0x7F nibble residuals (-8..7,
two per byte) | 0xC0-0xFF op-0xBF byte residuals (signed). Needs numpy + pillow (run via uv)."""
import sys, struct, base64, os, subprocess, zlib
import numpy as np
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
a = sys.argv[3:] + [None] * 8
W, H = int(a[0] or 160), int(a[1] or 120)
FPS, TOL = float(a[2] or 12), int(a[3] or 1)
KEY_SEC, MAX_SEC = float(a[4] or 3), float(a[5] or 1e9)
QY, QC = int(a[6] or 4), int(a[7] or 8)
TOLC = int(os.environ.get("TOLC", "0"))  # chroma drift allowance in steps; 0 = exact colour (dark scenes show chroma drift badly)
DUMP = int(os.environ.get("DUMP", "-1"))  # frame index to save as original/decoded PNG pair for eyeballing
CHUNK = 100_000
assert W % 2 == 0 and H % 2 == 0
delay_ms = round(1000 / FPS)  # player recovers fps = round(1000 / delay_ms), so keep FPS an integer

det = subprocess.run(["ffmpeg", "-v", "info", "-i", src, "-t", "40", "-vf", "cropdetect=24:2:0", "-f", "null", "-"], capture_output=True, text=True).stderr
crops = [l.split("crop=")[1].strip() for l in det.splitlines() if "crop=" in l]
crop = max(set(crops), key=crops.count) if crops else None
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-t", str(MAX_SEC), "-vf", (f"crop={crop}," if crop else "") + f"fps={FPS},scale={W}:{H}:flags=lanczos,hqdn3d=" + os.environ.get("DENOISE", "6:4:16:12"),
                      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
n = len(raw) // (W * H * 3)
rgb = np.frombuffer(raw, np.uint8).reshape(n, H, W, 3)

def planes(frame):  # -> quantized Y (H,W), Cb, Cr (H/2,W/2) as int16
    ycc = np.asarray(Image.fromarray(frame).convert("YCbCr")).astype(np.float32)
    y = ycc[..., 0]
    cb = ycc[..., 1].reshape(H // 2, 2, W // 2, 2).mean((1, 3))
    cr = ycc[..., 2].reshape(H // 2, 2, W // 2, 2).mean((1, 3))
    return [np.clip(np.floor(y / QY), 0, 255 // QY).astype(np.int16),
            np.clip(np.floor(cb / QC), 0, 255 // QC).astype(np.int16),
            np.clip(np.floor(cr / QC), 0, 255 // QC).astype(np.int16)]

def tokenize(r):  # r: flat int16 residual array -> bytes
    cls = np.where(r == 0, 0, np.where((r >= -8) & (r <= 7), 1, 2)).astype(np.int8)
    edges = np.flatnonzero(np.diff(cls)) + 1
    starts = np.concatenate(([0], edges)); ends = np.concatenate((edges, [len(r)]))
    out = bytearray()
    for s, e, c in zip(starts.tolist(), ends.tolist(), cls[starts].tolist()):
        i = s
        if c == 0:
            while i < e:
                k = min(128, e - i); out.append(k - 1); i += k
        elif c == 1:
            while i < e:
                k = min(64, e - i); out.append(0x7F + k)
                v = (r[i:i + k] & 15).astype(np.uint8)
                if k % 2: v = np.append(v, np.uint8(0))
                out += (v[0::2] | (v[1::2] << 4)).tobytes(); i += k
        else:
            while i < e:
                k = min(64, e - i); out.append(0xBF + k); out += (r[i:i + k] & 255).astype(np.uint8).tobytes(); i += k
    return bytes(out)

def untokenize(enc, count):  # reference decoder for the self-check
    out, i, p = np.zeros(count, np.int16), 0, 0
    while p < count:
        op = enc[i]; i += 1
        if op < 0x80: p += op + 1
        elif op < 0xC0:
            k = op - 0x7F; nb = (k + 1) // 2; v = np.frombuffer(enc[i:i + nb], np.uint8); i += nb
            nib = np.stack((v & 15, v >> 4), 1).reshape(-1)[:k].astype(np.int16); nib[nib > 7] -= 16
            out[p:p + k] = nib; p += k
        else:
            k = op - 0xBF; v = np.frombuffer(enc[i:i + k], np.uint8).astype(np.int16); v[v > 127] -= 256
            out[p:p + k] = v; i += k; p += k
    assert i == len(enc); return out

def key_residual(cur, mid, tol):  # sequential left-prediction with tolerance; returns residual, recon
    flat = cur.reshape(-1); res = np.empty(len(flat), np.int16); rec = np.empty(len(flat), np.int16); prev = mid
    for i, v in enumerate(flat.tolist()):
        r = v - prev
        if -tol <= r <= tol: r = 0
        res[i] = r; prev += r; rec[i] = prev
    return res, rec.reshape(cur.shape)

body = bytearray(b"LVD1" + struct.pack("<HHIHBB", W, H, n, delay_ms, QY, QC))
recon, key_every = None, max(1, round(KEY_SEC * FPS))
sizes, psnr, cerr = [0, 0], [], []
CUT_HIST = 0.5  # L1 distance between consecutive 32-bin luma histograms; cuts score > 0.7, fast motion < 0.35
cuts, prev_hist = [], None
for k in range(n):
    cur = planes(rgb[k])
    hist = np.bincount(cur[0].reshape(-1) * QY // 8, minlength=32)[:32] / cur[0].size
    is_cut = prev_hist is not None and bool(np.abs(hist - prev_hist).sum() > CUT_HIST)
    prev_hist = hist
    if is_cut: cuts.append(k)
    is_key = k % key_every == 0 or is_cut  # a cut restarts cleanly as a keyframe (with chroma) instead of a huge delta
    has_chroma = is_key or k % 2 == 0  # chroma at half the frame rate: the eye barely resolves colour motion
    frame = bytearray(); new = []
    for pi, c in enumerate(cur):
        if pi > 0 and not has_chroma:
            new.append(recon[pi]); continue
        tol = TOL if pi == 0 else TOLC
        if is_key:
            res, rec = key_residual(c, (255 // (QY if pi == 0 else QC)) // 2, 0)  # keyframes exact: spatial tolerance paints row streaks
        else:
            res = (c - recon[pi]).reshape(-1); res[np.abs(res) <= tol] = 0; rec = recon[pi] + res.reshape(c.shape)
        enc = tokenize(res)
        if k < 2: assert np.array_equal(untokenize(enc, res.size), res), f"roundtrip mismatch frame {k} plane {pi}"
        frame += enc; new.append(rec)
    recon = new
    err = ((recon[0].astype(np.float32) - cur[0]) * QY) ** 2
    psnr.append(10 * np.log10(255 ** 2 / max(err.mean(), 1e-3)))
    cerr.append(max(np.abs(recon[1] - cur[1]).mean(), np.abs(recon[2] - cur[2]).mean()) * QC)  # includes skipped-chroma frames
    if k == DUMP:
        def to_rgb(pl):
            y = np.clip(pl[0] * QY + QY // 2, 0, 255); c = [np.clip(np.kron(pl[i] * QC + QC // 2, np.ones((2, 2))), 0, 255) for i in (1, 2)]
            return Image.fromarray(np.stack((y, c[0], c[1]), -1).astype(np.uint8), "YCbCr").convert("RGB")
        pair = Image.new("RGB", (W * 2 + 4, H)); pair.paste(Image.fromarray(rgb[k]), (0, 0)); pair.paste(to_rgb(recon), (W + 4, 0))
        pair.resize((pair.width * 3, pair.height * 3), Image.NEAREST).save(os.path.join(os.path.dirname(out) or ".", f"dump_{k}.png"))
    body += struct.pack("<IB", len(frame), (1 if is_key else 0) + (2 if has_chroma else 0) + (4 if is_cut else 0)) + frame
    sizes[is_key] += len(frame)
# Optional container (ZLIB=1): "LVZ1" + u32 raw length + zlib stream, padded to even length. Needs a
# DEFLATE decoder in Luau on the player side (we used Picguin's, MIT); gives ~1.6x on top of the codec.
if os.environ.get("ZLIB") == "1":
    comp = zlib.compress(bytes(body), 9)
    if len(comp) % 2: comp += b"\0"
    container = b"LVZ1" + struct.pack("<I", len(body)) + comp
else:
    comp, container = bytes(body), bytes(body)
b64 = base64.b64encode(container).decode()
os.makedirs(out, exist_ok=True)
for f in os.listdir(out): os.remove(os.path.join(out, f))
chunks = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]
for i, c in enumerate(chunks, 1): open(os.path.join(out, f"{i}.luau"), "w").write(f'return "{c}"\n')
open(os.path.join(out, "init.luau"), "w").write(
    "local parts = table.create(%d)\nfor i = 1, %d do parts[i] = require(script[tostring(i)]) end\nreturn table.concat(parts)\n" % (len(chunks), len(chunks)))
px = n * (W * H + 2 * (W // 2) * (H // 2))
print(f"scene cuts: {len(cuts)} (first few at frames {cuts[:8]})")
print(f"luma PSNR vs quantized source: mean {np.mean(psnr):.1f} dB, worst {np.min(psnr):.1f} dB | chroma mean abs error {np.mean(cerr):.1f} levels (+-{QC/2:.0f} from quantization)")
print(f"crop={crop} {W}x{H} @{FPS}fps tol={TOL} QY={QY} QC={QC} key {KEY_SEC}s | {n} frames = {n/FPS:.0f}s | "
      f"tokens {len(body)/1048576:.2f} MB ({len(body)/px:.3f} B/elem) -> {"zlib" if os.environ.get("ZLIB") == "1" else "raw"} {len(comp)/1048576:.2f} MB -> base64 {len(b64)/1048576:.2f} MB in {len(chunks)} modules")
