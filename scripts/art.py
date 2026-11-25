# /// script
# dependencies = ["pillow==11.1.0"]
# ///
"""Matiné's artwork: the app icon's layers (dawn sky, striped rising sun, a
small TV) and the Top Shelf images ("Matiné en casa" in Tangerine Bold, as on the
website; the font is fetched once and checked, see `font`). Deterministic (seeded stars), so a run
reproduces what's in the asset catalog.

    uv run scripts/art.py OUT_DIR
        writes every PNG to OUT_DIR; copy the ones that changed into
        Apps/Matine/Matine/Assets.xcassets/App Icon & Top Shelf Image.brandassets
"""
import sys, math, random
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

OUT = Path(sys.argv[1])
SS = 4  # supersampling

SKY = [(0.00, (20, 16, 58)), (0.45, (92, 36, 112)), (0.75, (214, 78, 92)), (1.00, (255, 150, 74))]
SUN_TOP, SUN_BOTTOM = (255, 226, 140), (255, 104, 60)
CREAM = (255, 244, 226)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(stops, y):
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if y <= p1: return lerp(c0, c1, (y - p0) / (p1 - p0))
    return stops[-1][1]

def sky(w, h, horizon=0.72, stars=True, seed=7):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        c = gradient(SKY, y / (h - 1))
        for x in range(w): px[x, y] = c
    # A warm glow on the horizon.
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse([w * 0.1, h * horizon - h * 0.35, w * 0.9, h * horizon + h * 0.35], fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(h * 0.12))
    img = Image.composite(Image.new("RGB", (w, h), (255, 190, 120)), img, glow)
    if stars:
        rnd = random.Random(seed)
        d = ImageDraw.Draw(img)
        for _ in range(int(w * h / 18000)):
            x, y = rnd.uniform(0, w), rnd.uniform(0, h * 0.38)
            r = rnd.uniform(0.6, 1.8) * w / 800
            a = rnd.randint(120, 230)
            d.ellipse([x - r, y - r, x + r, y + r], fill=(a, a, min(255, a + 20)))
    return img

def sun(w, h, cx, cy, r, stripes=4):
    """A gradient disc whose lower half is cut by widening gaps (retro sunset)."""
    S = SS
    W, H, CX, CY, R = w * S, h * S, cx * S, cy * S, r * S
    disc = Image.new("L", (W, H), 0)
    ImageDraw.Draw(disc).ellipse([CX - R, CY - R, CX + R, CY + R], fill=255)
    cut = ImageDraw.Draw(disc)
    for i in range(stripes):
        t = (i + 1) / (stripes + 1)
        y = CY + R * (0.05 + 0.95 * t)
        gap = R * (0.06 + 0.09 * t)
        cut.rectangle([CX - R - 2, y - gap / 2, CX + R + 2, y + gap / 2], fill=0)
    fill = Image.new("RGB", (W, H))
    fp = ImageDraw.Draw(fill)
    for y in range(int(CY - R), int(CY + R) + 1):
        fp.line([(CX - R, y), (CX + R, y)], fill=lerp(SUN_TOP, SUN_BOTTOM, (y - (CY - R)) / (2 * R)))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    layer.paste(fill, (0, 0), disc)
    # Soft halo behind the disc.
    halo = Image.new("L", (W, H), 0)
    ImageDraw.Draw(halo).ellipse([CX - R * 1.45, CY - R * 1.45, CX + R * 1.45, CY + R * 1.45], fill=45)
    halo = halo.filter(ImageFilter.GaussianBlur(R * 0.25))
    glow = Image.new("RGBA", (W, H), SUN_TOP + (0,))
    glow.putalpha(halo)
    out = Image.alpha_composite(glow, layer)
    return out.resize((w, h), Image.LANCZOS)

def tv(w, h, cx, cy, sw, sh, stroke):
    """Rounded screen outline with antennas and little feet, all cream."""
    S = SS
    img = Image.new("RGBA", (w * S, h * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = (cx - sw / 2) * S, (cy - sh / 2) * S, (cx + sw / 2) * S, (cy + sh / 2) * S
    st = stroke * S
    d.rounded_rectangle([x0, y0, x1, y1], radius=sh * 0.22 * S, outline=CREAM, width=int(st))
    # Antennas from a small knob on top.
    kx, ky = cx * S, y0 - st * 0.2
    for ang in (-35, 35):
        ex = kx + math.sin(math.radians(ang)) * sh * 0.55 * S
        ey = ky - math.cos(math.radians(ang)) * sh * 0.55 * S
        d.line([(kx, ky), (ex, ey)], fill=CREAM, width=int(st * 0.6))
        d.ellipse([ex - st * 0.55, ey - st * 0.55, ex + st * 0.55, ey + st * 0.55], fill=CREAM)
    d.ellipse([kx - st * 0.7, ky - st * 0.7, kx + st * 0.7, ky + st * 0.7], fill=CREAM)
    # Feet.
    for fx in (x0 + (x1 - x0) * 0.22, x1 - (x1 - x0) * 0.22):
        d.rounded_rectangle([fx - st * 0.9, y1 + st * 0.1, fx + st * 0.9, y1 + st * 1.4], radius=st * 0.4, fill=CREAM)
    # Soft shadow so the frame lifts off the sky.
    shadow = img.split()[3].filter(ImageFilter.GaussianBlur(st * 0.8)).point(lambda a: int(a * 0.45))
    sh_img = Image.new("RGBA", img.size, (30, 10, 40, 0))
    sh_img.putalpha(shadow)
    sh_img = sh_img.transform(sh_img.size, Image.AFFINE, (1, 0, 0, 0, 1, -st * 0.6))
    out = Image.alpha_composite(sh_img, img)
    return out.resize((w, h), Image.LANCZOS)

def icon_layers(w, h):
    back = sky(w, h)
    # The sun sits "on" the TV screen; the screen's centre is a little high.
    middle = sun(w, h, w * 0.5, h * 0.60, h * 0.30)
    front = tv(w, h, w * 0.5, h * 0.56, w * 0.40, h * 0.46, h * 0.035)
    return back, middle, front

def save_stack(name, w, h, scales):
    for scale in scales:
        b, m, f = icon_layers(w * scale, h * scale)
        tag = "" if scale == 1 else f"@{scale}x"
        b.save(OUT / f"{name}-back{tag}.png")
        m.save(OUT / f"{name}-middle{tag}.png")
        f.save(OUT / f"{name}-front{tag}.png")
        flat = Image.alpha_composite(Image.alpha_composite(b.convert("RGBA"), m), f)
        flat.convert("RGB").save(OUT / f"{name}-preview{tag}.png")

# The wordmark's face, as on the website: Tangerine Bold (Toshi Omagari, SIL OFL 1.1). It only draws these
# PNGs and never ships in the app, so it is fetched at a pinned google/fonts commit and checked, not vendored.
TANGERINE = ("https://raw.githubusercontent.com/google/fonts/c2de15f7863fcfa9500208336b08795613c867d5/ofl/tangerine/Tangerine-Bold.ttf",
             "a35368c814c71c15928ffc60cbac32bc81461f03b895a4a607df9c64b3d1548b")

def font(size):
    import hashlib, urllib.error, urllib.request
    url, sha = TANGERINE
    path = Path.home() / ".cache" / "matine" / "Tangerine-Bold.ttf"
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != sha:
        try: data = urllib.request.urlopen(url, timeout=30).read()
        except (urllib.error.URLError, TimeoutError) as e:
            sys.exit(f"art.py: cannot fetch Tangerine-Bold.ttf ({e}); it needs the network once, then lives in {path.parent}")
        if hashlib.sha256(data).hexdigest() != sha: sys.exit("art.py: Tangerine-Bold.ttf does not match its pinned hash")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return ImageFont.truetype(str(path), size)

def fog(w, h, seed=5):
    """A morning fog bank settled along the bottom: soft puffs, densest at the
    foot, thinning upward into the sky. Drawn small and scaled, so it is the
    same cloud at every size."""
    sw, sh = 600 * w // h, 600
    rnd = random.Random(seed)
    dens = Image.new("L", (sw, sh), 0)
    d = ImageDraw.Draw(dens)
    # A low bed of mist along the foot.
    for _ in range(90):
        cx = rnd.uniform(-0.1, 1.1) * sw
        cy = sh * rnd.uniform(0.93, 1.06)
        rx = sh * rnd.uniform(0.12, 0.30)
        ry = rx * rnd.uniform(0.25, 0.40)
        d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=rnd.randint(90, 140))
    # Rounded puffs rising out of it: the cloud's soft, lumpy top.
    x = -0.05 * sw
    while x < 1.05 * sw:
        r = sh * rnd.uniform(0.06, 0.13)
        cy = sh * rnd.uniform(0.86, 0.93)
        d.ellipse([x - r, cy - r * 0.8, x + r, cy + r * 0.8], fill=rnd.randint(110, 170))
        x += r * rnd.uniform(1.1, 1.7)
    dens = dens.filter(ImageFilter.GaussianBlur(sh * 0.022))
    # Only the bottom of the picture: nothing above the cloud tops.
    ramp = Image.new("L", (sw, sh), 0)
    rd = ImageDraw.Draw(ramp)
    for y in range(sh):
        t = (y / sh - 0.74) / 0.12
        rd.line([(0, y), (sw, y)], fill=int(255 * max(0, min(1, t))))
    alpha = ImageChops.multiply(dens.point(lambda a: min(255, int(a * 1.6))), ramp)
    layer = Image.new("RGBA", (sw, sh), (255, 236, 224, 0))
    layer.putalpha(alpha.point(lambda a: int(a * 0.8)))
    return layer.resize((w, h), Image.LANCZOS)

def top_shelf(w, h, name):
    """The shelf shows only the middle 1920 of the wide image's 2320 (per 720
    of height): everything that matters sits inside that, with a margin."""
    visible = h * 1920 / 720
    left = (w - visible) / 2 + visible * 0.07
    img = sky(w, h, horizon=0.85, seed=11).convert("RGBA")
    img = Image.alpha_composite(img, sun(w, h, (w + visible) / 2 - visible * 0.22, h * 0.80, h * 0.42, stripes=5))
    # The name low on the sky, sitting just above the dock like the sun. On
    # the TV the image is shown full width at the top of the screen and ends
    # just above the dock, so its lower edge is where the sun sets.
    # "Matiné" in the script, with a small "en casa" tucked under it, its "e" below the "t" (as on the website).
    f = font(int(h * 0.50))
    small = font(int(h * 0.15))
    words = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(words)
    top, bottom = draw.textbbox((0, 0), "Matiné", font=f)[1::2]
    floor = h * 0.74
    draw.text((left, floor - bottom), "Matiné", font=f, fill=CREAM + (255,))
    y0, y1 = floor - (bottom - top), floor
    # Its foot thins out softly; the fog finishes it.
    fade = Image.new("L", img.size, 255)
    fd = ImageDraw.Draw(fade)
    # Solid through most of its height (it must read at a glance); only the
    # base thins into the mist.
    start = y0 + (y1 - y0) * 0.72
    for y in range(int(start), h):
        t = min(1, max(0, (y - start) / (y1 - start)))
        fd.line([(0, y), (w, y)], fill=int(255 * (1 - 0.55 * t ** 1.4)))
    words.putalpha(ImageChops.multiply(words.split()[3], fade))
    # "en casa" after the fade: it sits in the mist but stays whole.
    draw = ImageDraw.Draw(words)
    t_left = left + draw.textlength("Ma", font=f)
    s_top = draw.textbbox((0, 0), "en casa", font=small)[1]
    draw.text((t_left, floor + h * 0.005 - s_top), "en casa", font=small, fill=CREAM + (255,))
    # A deeper shadow than on the plain sky: the name sits over bright mist.
    shadow = words.split()[3].filter(ImageFilter.GaussianBlur(h * 0.022)).point(lambda a: int(a * 0.75))
    dark = Image.new("RGBA", img.size, (40, 12, 60, 0))
    dark.putalpha(shadow)
    dark = dark.transform(dark.size, Image.AFFINE, (1, 0, -h * 0.006, 0, 1, -h * 0.014))
    # The fog settles over the sun; the name stands in front of it, its
    # base thinning into the mist, so it reads clearly.
    img = Image.alpha_composite(img, fog(w, h, seed=5))
    img = Image.alpha_composite(Image.alpha_composite(img, dark), words)
    img.convert("RGB").save(OUT / name)

save_stack("appicon", 400, 240, [1, 2])
save_stack("appstore", 1280, 768, [1])
top_shelf(1920, 720, "topshelf.png"); top_shelf(3840, 1440, "topshelf@2x.png")
top_shelf(2320, 720, "topshelf-wide.png"); top_shelf(4640, 1440, "topshelf-wide@2x.png")
print("ok")
