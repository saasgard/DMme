"""Render DMme graphics with signed-distance shapes (no dependencies).

Outputs:
  <addon>/Media/gear.tga   64x64 white gear (tinted in-game)
  <addon>/Media/icon.tga   64x64 logo (minimap button + addon list icon)
  <addon>/Art/curseforge-logo.png  512x512 logo
  <scratch>/preview_*.png  previews on a dark background
"""
import math, os, struct, sys, zlib

ADDON = sys.argv[1]
SCRATCH = sys.argv[2]

# ---------------------------------------------------------------- SDF helpers
def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x

def sd_circle(px, py, cx, cy, r):
    return math.hypot(px - cx, py - cy) - r

def sd_rrect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - hw + r
    qy = abs(py - cy) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r

def sd_tri(px, py, a, b, c):
    # Inigo Quilez triangle SDF
    def sub(u, v): return (u[0] - v[0], u[1] - v[1])
    def dot(u, v): return u[0] * v[0] + u[1] * v[1]
    p = (px, py)
    e0, e1, e2 = sub(b, a), sub(c, b), sub(a, c)
    v0, v1, v2 = sub(p, a), sub(p, b), sub(p, c)
    def seg(v, e):
        h = clamp(dot(v, e) / dot(e, e))
        return (v[0] - e[0] * h, v[1] - e[1] * h)
    pq0, pq1, pq2 = seg(v0, e0), seg(v1, e1), seg(v2, e2)
    s = 1 if (e0[0] * e2[1] - e0[1] * e2[0]) > 0 else -1
    d0 = (dot(pq0, pq0), s * (v0[0] * e0[1] - v0[1] * e0[0]))
    d1 = (dot(pq1, pq1), s * (v1[0] * e1[1] - v1[1] * e1[0]))
    d2 = (dot(pq2, pq2), s * (v2[0] * e2[1] - v2[1] * e2[0]))
    dmin = min(d0[0], d1[0], d2[0])
    smin_ = min(d0[1], d1[1], d2[1])
    return -math.sqrt(dmin) if smin_ > 0 else math.sqrt(dmin)

def smin(a, b, k):
    h = clamp(0.5 + 0.5 * (b - a) / k)
    return b * (1 - h) + a * h - k * h * (1 - h)

def cover(d, px_per_unit):
    """Anti-aliased coverage from a distance in shape units."""
    return clamp(0.5 - d * px_per_unit)

def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))

def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

# ---------------------------------------------------------------- canvas
class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[0.0, 0.0, 0.0, 0.0] for _ in range(w * h)]  # premultiplied

    def over(self, i, rgb, a):
        if a <= 0: return
        p = self.px[i]
        inv = 1 - a
        p[0] = rgb[0] * a + p[0] * inv
        p[1] = rgb[1] * a + p[1] * inv
        p[2] = rgb[2] * a + p[2] * inv
        p[3] = a + p[3] * inv

    def rgba8(self):
        out = []
        for r, g, b, a in self.px:
            if a > 0:
                out.append((round(clamp(r / a) * 255), round(clamp(g / a) * 255),
                            round(clamp(b / a) * 255), round(clamp(a) * 255)))
            else:
                out.append((0, 0, 0, 0))
        return out

def write_png(path, w, h, pix):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pix[y * w + x])
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f: f.write(png)

def write_tga(path, w, h, pix):
    # uncompressed 32-bit BGRA, bottom-up rows (descriptor 8 = 8 alpha bits)
    hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 8)
    body = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = pix[y * w + x]
            body.extend((b, g, r, a))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f: f.write(hdr + body)

def on_dark(pix, w, h, bg=(24, 22, 30)):
    out = []
    for r, g, b, a in pix:
        t = a / 255
        out.append((round(r * t + bg[0] * (1 - t)), round(g * t + bg[1] * (1 - t)),
                    round(b * t + bg[2] * (1 - t)), 255))
    return out

def upscale(pix, w, h, k):
    out = []
    for y in range(h * k):
        for x in range(w * k):
            out.append(pix[(y // k) * w + (x // k)])
    return out

# ---------------------------------------------------------------- gear
def gear_sdf(x, y, cx=32, cy=32, teeth=8, base=18.0, tooth_mid=22.5, tooth_half_len=5.5,
             tooth_half_w=4.8, hole=7.5):
    dx, dy = x - cx, y - cy
    d = math.hypot(dx, dy) - base
    for i in range(teeth):
        t = i * 2 * math.pi / teeth
        c, s = math.cos(t), math.sin(t)
        lx = c * dx + s * dy
        ly = -s * dx + c * dy
        d = smin(d, sd_rrect(lx, ly, tooth_mid, 0, tooth_half_len, tooth_half_w, 1.8), 1.6)
    return max(d, -(math.hypot(dx, dy) - hole))

def render_gear(size=64):
    cv = Canvas(size, size)
    k = size / 64
    for y in range(size):
        for x in range(size):
            d = gear_sdf((x + 0.5) / k, (y + 0.5) / k)
            cv.over(y * size + x, (1, 1, 1), cover(d, k))
    return cv.rgba8()

# ---------------------------------------------------------------- logo (designed on a 512 grid)
PINK, PURPLE = hexc("#ff7ae6"), hexc("#8f5bff")
BG_TOP, BG_BOT = hexc("#221c30"), hexc("#0c0b12")

def main_bubble(x, y):
    body = sd_rrect(x, y, 246, 236, 150, 108, 64)
    tail = sd_tri(x, y, (128, 300), (196, 330), (104, 404))
    return smin(body, tail, 14)

def back_bubble(x, y):
    body = sd_rrect(x, y, 344, 150, 98, 70, 46)
    tail = sd_tri(x, y, (380, 190), (420, 182), (444, 246))
    return smin(body, tail, 10)

def render_logo(size, with_bg=True):
    cv = Canvas(size, size)
    k = size / 512.0
    for py in range(size):
        for px in range(size):
            x, y = (px + 0.5) / k, (py + 0.5) / k
            i = py * size + px

            if with_bg:
                dbg = sd_rrect(x, y, 256, 256, 256, 256, 104)
                a = cover(dbg, k)
                if a > 0:
                    col = lerp(BG_TOP, BG_BOT, clamp(y / 512))
                    # soft pink glow in the middle of the background
                    g = clamp(1 - math.hypot(x - 230, y - 250) / 300) ** 2 * 0.22
                    col = lerp(col, PINK, g)
                    cv.over(i, col, a)
                    # thin inner rim
                    rim = cover(abs(dbg + 3) - 1.5, k) * 0.35
                    cv.over(i, hexc("#4a3d63"), rim * a)

            # back bubble (darker, behind)
            db = back_bubble(x, y)
            cv.over(i, lerp(hexc("#5b3f8f"), hexc("#3b2c63"), clamp((y - 80) / 170)), cover(db, k))

            # shadow of the main bubble
            dm = main_bubble(x, y)
            ds = main_bubble(x - 6, y - 12)
            sh = clamp(1 - (ds + 4) / 34) ** 2 * 0.55 if ds > -4 else 0.55
            cv.over(i, (0, 0, 0), sh * (1 - cover(dm, k)) * (1 if with_bg else 0.6))

            # main bubble with diagonal pink -> purple gradient
            a = cover(dm, k)
            if a > 0:
                t = clamp(((x - 96) + (y - 128)) / 560)
                col = lerp(PINK, PURPLE, t)
                # subtle top highlight
                hl = clamp(1 - (y - 128) / 90) * 0.18
                col = lerp(col, (1, 1, 1), hl)
                cv.over(i, col, a)

            # three dots (typing / whisper)
            for cx in (176, 246, 316):
                dd = sd_circle(x, y, cx, 238, 24)
                cv.over(i, (1, 1, 1), cover(dd, k) * 0.97)
    return cv.rgba8()

# ---------------------------------------------------------------- go
gear = render_gear(64)
write_tga(os.path.join(ADDON, "Media", "gear.tga"), 64, 64, gear)
write_png(os.path.join(SCRATCH, "preview_gear.png"), 256, 256, upscale(on_dark(gear, 64, 64), 64, 64, 4))

icon = render_logo(64, with_bg=True)
write_tga(os.path.join(ADDON, "Media", "icon.tga"), 64, 64, icon)
write_png(os.path.join(SCRATCH, "preview_icon.png"), 256, 256, upscale(on_dark(icon, 64, 64), 64, 64, 4))

logo = render_logo(512, with_bg=True)
write_png(os.path.join(ADDON, "Art", "curseforge-logo.png"), 512, 512, logo)
print("done")
