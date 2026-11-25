#!/usr/bin/env python3
"""Builds the demo library into build/media (gitignored): art made from frames of the films, tiny placeholder videos,
NFO files. Run through demo-server.sh (it uses build/venv for Pillow). Frames are grabbed with ffmpeg seeking over HTTP
range requests, so no film is downloaded; they are cached in build/frames.

Art: posters (800x1200, a 2:3 crop of one frame with the title lettered on it), backdrops (1920x1080) and episode
thumbs (1280x720). Nothing is downloaded from TMDB, fanart.tv or Wikipedia; there are no logos.
Video: full-runtime H.264 640 px wide at 1 fps built from a handful of frames, silent AAC tagged eng.
"""
import subprocess, sys, time
from pathlib import Path
from xml.sax.saxutils import escape

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from catalog import MOVIES, SHOWS

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
FRAMES = BUILD / "frames"
MEDIA = BUILD / "media"
SERIF = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
SANS = "/System/Library/Fonts/Helvetica.ttc"


def frame(slug: str, url: str, t: int, crop: str | None = None) -> Path:
    """The full-size frame at second t of a source, cached. Retries: download.blender.org answers 429 to bursts."""
    out = FRAMES / slug / f"{t}.png"
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-v", "error", "-y", "-ss", str(t), "-i", url, "-frames:v", "1"]
    if crop:
        cmd += ["-vf", crop]
    for attempt in range(8):
        if subprocess.run(cmd + [str(out)]).returncode == 0 and out.exists():
            return out
        print(f"  retry {slug}@{t} ({attempt + 1})", file=sys.stderr)
        time.sleep(15)
    sys.exit(f"cannot grab {slug}@{t}")


def cover(im: Image.Image, w: int, h: int, fx: float = 0.5) -> Image.Image:
    """Scale to cover w x h, cropping around horizontal focus fx (0..1)."""
    s = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    x = min(max(round(im.width * fx - w / 2), 0), im.width - w)
    y = (im.height - h) // 2
    return im.crop((x, y, x + w, y + h))


def poster(src: Path, title: str, year: int | str, fx: float, dest: Path, fit: bool = False) -> None:
    """fit: for low-resolution sources, show the whole frame over a blurred copy instead of a tight, soft crop."""
    W, H = 800, 1200
    if fit:
        raw = Image.open(src).convert("RGB")
        im = cover(raw, W, H).filter(ImageFilter.GaussianBlur(28))
        im = Image.eval(im, lambda v: int(v * 0.55))
        fg = raw.resize((W, round(raw.height * W / raw.width)), Image.LANCZOS).filter(ImageFilter.UnsharpMask(2, 50, 2))
        im.paste(fg, (0, 150))
    else:
        im = cover(Image.open(src).convert("RGB"), W, H, fx).filter(ImageFilter.UnsharpMask(2, 60, 2))
    grad = Image.new("L", (1, H))
    for y in range(H):
        grad.putpixel((0, y), int(235 * min(1, max(0, (y - H * 0.50) / (H * 0.42))) ** 1.4))
    im.paste(Image.new("RGB", (W, H), (8, 8, 12)), (0, 0), grad.resize((W, H)))
    d = ImageDraw.Draw(im)
    size = 96
    while True:   # wrap by words, shrink until three lines fit
        font = ImageFont.truetype(SERIF, size)
        lines, line = [], ""
        for word in title.split():
            trial = f"{line} {word}".strip()
            if d.textlength(trial, font=font) <= W - 120 or not line:
                line = trial
            else:
                lines.append(line); line = word
        lines.append(line)
        if len(lines) <= 3 and all(d.textlength(l, font=font) <= W - 100 for l in lines):
            break
        size -= 4
    lh = int(size * 1.15)
    y = H - 110 - lh * len(lines)
    for l in lines:
        x = (W - d.textlength(l, font=font)) / 2
        d.text((x + 3, y + 3), l, font=font, fill=(0, 0, 0))
        d.text((x, y), l, font=font, fill=(250, 246, 236))
        y += lh
    small = ImageFont.truetype(SANS, 34)
    ys = str(year)
    d.text(((W - d.textlength(ys, font=small)) / 2, H - 85), ys, font=small, fill=(205, 200, 190))
    dest.parent.mkdir(parents=True, exist_ok=True)
    im.save(dest, quality=90)


def wide(src: Path, w: int, h: int, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    cover(Image.open(src).convert("RGB"), w, h).save(dest, quality=88)


def placeholder(slug: str, url: str, frames: list[int], runtime_s: int, crop: str | None, dest: Path) -> None:
    """Full-runtime video from a handful of frames: 640 px wide, 1 fps, silent AAC (eng)."""
    if dest.exists():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    scaled = []
    for t in frames:
        im = Image.open(frame(slug, url, t, crop)).convert("RGB")
        w = 640
        h = round(im.height * w / im.width) // 2 * 2
        p = FRAMES / slug / f"{t}-640.png"
        im.resize((w, h), Image.LANCZOS).save(p)
        scaled.append(p)
    # every frame the same size (the first one's): crop/pad is unnecessary, sources share an aspect ratio
    each = runtime_s / len(scaled)
    lst = FRAMES / slug / "concat.txt"
    lst.write_text("".join(f"file '{p}'\nduration {each:.3f}\n" for p in scaled) + f"file '{scaled[-1]}'\n")
    tmp = dest.with_suffix(".tmp.mp4")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                    "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", str(runtime_s), "-r", "1", "-vf", "format=yuv420p",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-g", "10", "-tune", "stillimage",
                    "-c:a", "aac", "-b:a", "16k", "-metadata:s:a:0", "language=eng",
                    "-movflags", "+faststart", "-f", "mp4", str(tmp)], check=True)
    tmp.rename(dest)


def nfo_common(m: dict) -> str:
    out = []
    for g in m["genres"]:
        out.append(f"  <genre>{escape(g)}</genre>")
    for t in m["tags"]:
        out.append(f"  <tag>{escape(t)}</tag>")
    out.append(f"  <studio>{escape(m['studio'])}</studio>")
    for d in m["director"].split(", "):
        out.append(f"  <director>{escape(d)}</director>")
    return "\n".join(out)


def tagline(m: dict) -> str:
    """A few words of our own, or nothing: the app shows the tagline on screen, so no license text goes here."""
    return escape(m.get("tagline", ""))


def license_comment(m: dict) -> str:
    """License and credit live in CREDITS.md and, invisibly, in an XML comment (no field the app shows)."""
    return f"<!-- {escape(m['license'])}. {escape(m['credit'])}. See CREDITS.md. -->".replace("--.", "-.")


def write_movie(m: dict) -> None:
    name = f"{m['title'].replace(':', ' -')} ({m['year']})"
    d = MEDIA / "movies" / name
    d.mkdir(parents=True, exist_ok=True)
    mins = round(m["runtime_s"] / 60)
    (d / "movie.nfo").write_text(f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  {license_comment(m)}
  <title>{escape(m['title'])}</title>
  <originaltitle>{escape(m['title'])}</originaltitle>
  <sorttitle>{escape(m['title'])}</sorttitle>
  <year>{m['year']}</year>
  <plot>{escape(m['plot'])}</plot>
  <outline>{escape(m['plot'])}</outline>
  <tagline>{tagline(m)}</tagline>
  <runtime>{mins}</runtime>
  <mpaa>{m['mpaa']}</mpaa>
{nfo_common(m)}
</movie>
""")
    src_post = frame(m["slug"], m["url"], m["poster_t"], m.get("crop"))
    poster(src_post, m["title"].split(":")[0] if ":" in m["title"] else m["title"], m["year"], m["poster_fx"], d / "poster.jpg", m.get("fit", False))
    wide(frame(m["slug"], m["url"], m["backdrop_t"], m.get("crop")), 1920, 1080, d / "fanart.jpg")
    placeholder(m["slug"], m["url"], m["frames"], m["runtime_s"], m.get("crop"), d / f"{name}.mp4")


def write_show(s: dict) -> None:
    folder = s["title"].replace(":", " -")
    d = MEDIA / "shows" / folder
    d.mkdir(parents=True, exist_ok=True)
    ep_src = next(e for e in s["episodes"] if e["slug"] == s["poster_ep"])
    bd_src = next(e for e in s["episodes"] if e["slug"] == s.get("backdrop_ep", s["poster_ep"]))
    (d / "tvshow.nfo").write_text(f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tvshow>
  {license_comment(s)}
  <title>{escape(s['title'])}</title>
  <originaltitle>{escape(s['title'])}</originaltitle>
  <sorttitle>{escape(s['title'])}</sorttitle>
  <year>{s['year']}</year>
  <plot>{escape(s['plot'])}</plot>
  <tagline>{tagline(s)}</tagline>
  <mpaa>{s['mpaa']}</mpaa>
  <status>Ended</status>
{nfo_common(s)}
</tvshow>
""")
    post = frame(ep_src["slug"], ep_src["url"], s["poster_t"], ep_src.get("crop"))
    poster(post, s["title"], s.get("poster_label", f"{s['year']} - 2016"), s["poster_fx"], d / "poster.jpg")
    poster(post, s["title"], "Season 1", s["poster_fx"], d / "season01-poster.jpg")
    wide(frame(bd_src["slug"], bd_src["url"], s["backdrop_t"], bd_src.get("crop")), 1920, 1080, d / "fanart.jpg")
    sd = d / "Season 01"
    sd.mkdir(exist_ok=True)
    for e in s["episodes"]:
        base = f"{folder} S01E{e['n']:02d}"
        mins = max(1, round(e["runtime_s"] / 60))
        (sd / f"{base}.nfo").write_text(f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<episodedetails>
  <title>{escape(e['title'])}</title>
  <originaltitle>{escape(e['original'])}</originaltitle>
  <showtitle>{escape(s['title'])}</showtitle>
  <season>1</season>
  <episode>{e['n']}</episode>
  <year>{e['year']}</year>
  <plot>{escape(e['plot'])}</plot>
  <runtime>{mins}</runtime>
  <director>{escape(s['director'])}</director>
  {license_comment(s)}
</episodedetails>
""")
        wide(frame(e["slug"], e["url"], e["thumb_t"], e.get("crop")), 1280, 720, sd / f"{base}-thumb.jpg")
        placeholder(e["slug"], e["url"], e["frames"], e["runtime_s"], e.get("crop"), sd / f"{base}.mp4")


def main() -> None:
    only = set(sys.argv[1:])
    for m in MOVIES:
        if not only or m["slug"] in only:
            print("==", m["title"], flush=True)
            write_movie(m)
    for s in SHOWS:
        if not only or s["slug"] in only:
            print("==", s["title"], flush=True)
            write_show(s)


main()
