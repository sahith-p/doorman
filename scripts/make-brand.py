#!/usr/bin/env python3
"""Draws Doorman's icon and logos, and renders every size the app, the extension and GitHub use.

Everything comes from the shapes in this file, so there's no font or stock glyph in the mark. Run it
with `make brand`. It needs Chrome (to turn the drawings into images) and Apple's sips and iconutil.
"""
import math, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRAND = ROOT / "assets/brand"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BLUE_TOP, BLUE_BOTTOM, INK = "#3A6BF0", "#2149CC", "#141B2E"


def squircle(cx, cy, half, n=5.0, steps=240):
    """Apple-style continuous corners: a superellipse rather than a rounded rectangle."""
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        points.append((cx + half * math.copysign(abs(c) ** (2 / n), c), cy + half * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in points) + "Z"


def key(color, scale=1.0, bold=False):
    """An open-ring key, drawn upright around the origin and tilted so the ring sits top left."""
    ring, shaft, tooth = (112, 124, 92) if bold else (86, 88, 64)
    return f"""<g transform="translate({512 - 30 * scale:.1f} {512 + 8 * scale:.1f}) rotate(-45) scale({scale}) translate(0 28)" fill="{color}">
    <circle cx="0" cy="-200" r="{166 - ring / 2}" fill="none" stroke="{color}" stroke-width="{ring}"/>
    <rect x="{-shaft / 2}" y="-60" width="{shaft}" height="390" rx="26"/>
    <rect x="0" y="{330 - tooth}" width="{shaft / 2 + 104}" height="{tooth}" rx="18"/>
    <rect x="0" y="{330 - 2 * tooth - 36}" width="{shaft / 2 + 104}" height="{tooth}" rx="18"/>
  </g>"""


def tile(half=512, shadow=False, bold=False, scale=1.0, ids="b"):
    filt = ' filter="url(#s)"' if shadow else ""
    return f"""<defs>
    <linearGradient id="{ids}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{BLUE_TOP}"/><stop offset="1" stop-color="{BLUE_BOTTOM}"/></linearGradient>
    <filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity=".28"/></filter>
  </defs>
  <path d="{squircle(512, 512, half)}" fill="url(#{ids})"{filt}/>
  {key("#fff", scale, bold)}"""


def wordmark(x, baseline, color, stroke=22):
    """'doorman', drawn from circles and stems. r is the x-height radius."""
    r, up = 50, 170
    b = baseline
    def bowl(cx):
        return f'<circle cx="{x + cx}" cy="{b - r}" r="{r}"/>'
    def stem(at, top):
        return f'<path d="M{x + at} {b - top}V{b}"/>'
    def arch(at, w=76):
        return f'<path d="M{x + at} {b - 62}a{w / 2} {w / 2 - 2} 0 0 1 {w} 0V{b}"/>'
    parts = [
        bowl(50), stem(100, up),                                   # d
        bowl(184),                                                 # o
        bowl(318),                                                 # o
        stem(402, 100), f'<path d="M{x + 402} {b - 58}C{x + 402} {b - 84} {x + 420} {b - 100} {x + 448} {b - 100}"/>',  # r
        stem(476, 100), arch(476), arch(552),                      # m
        bowl(712), stem(762, 100),                                 # a
        stem(796, 100), arch(796),                                 # n
    ]
    return f'<g fill="none" stroke="{color}" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round">{"".join(parts)}</g>'


def svg(w, h, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">\n  {body}\n</svg>\n'


def lockup(color):
    # The icon is 1024 wide, drawn at 200 here.
    return svg(1140, 200, f'<g transform="scale({200 / 1024})">{tile()}</g>\n  {wordmark(246, 186, color)}')


def render(page, out, w, h):
    """Headless Chrome with a throwaway profile, so it never touches your own browser."""
    with tempfile.TemporaryDirectory() as tmp:
        html = pathlib.Path(tmp) / "page.html"
        html.write_text(f'<!doctype html><html><body style="margin:0;background:transparent;overflow:hidden">{page}</body></html>')
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-first-run", f"--user-data-dir={tmp}/profile",
                        "--hide-scrollbars", "--force-device-scale-factor=1", "--default-background-color=00000000",
                        f"--window-size={w},{h}", f"--screenshot={out}", html.as_uri()],
                       check=True, capture_output=True, timeout=60)


def resize(src, size, out):
    subprocess.run(["sips", "-z", str(size), str(size), str(src), "--out", str(out)], check=True, capture_output=True)


def main():
    BRAND.mkdir(parents=True, exist_ok=True)
    full = svg(1024, 1024, tile())
    (BRAND / "icon.svg").write_text(full)
    (BRAND / "logo-light.svg").write_text(lockup(INK))
    (BRAND / "logo-dark.svg").write_text(lockup("#FFFFFF"))

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        # The Mac app: Apple's icon grid leaves a margin around the tile, and it casts a soft shadow.
        mac = tmp / "mac.png"
        render(svg(1024, 1024, tile(half=412, shadow=True, scale=412 / 512)), mac, 1024, 1024)
        iconset = tmp / "AppIcon.iconset"
        iconset.mkdir()
        for n in (16, 32, 128, 256, 512):
            resize(mac, n, iconset / f"icon_{n}x{n}.png")
            resize(mac, n * 2, iconset / f"icon_{n}x{n}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "assets/AppIcon.icns")], check=True)

        # The extension: Chrome's small sizes need every pixel, so they fill the square with a bolder key.
        big, bold = tmp / "full.png", tmp / "bold.png"
        render(full, big, 1024, 1024)
        render(svg(1024, 1024, tile(bold=True, scale=1.12)), bold, 1024, 1024)
        padded = tmp / "padded.png"
        render(svg(1024, 1024, tile(half=448, scale=448 / 512)), padded, 1024, 1024)
        out = ROOT / "extension/fill/icons"
        out.mkdir(parents=True, exist_ok=True)
        resize(bold, 16, out / "icon16.png")
        resize(bold, 32, out / "icon32.png")
        resize(big, 48, out / "icon48.png")
        resize(padded, 128, out / "icon128.png")
        resize(big, 512, BRAND / "icon-512.png")

    # The picture GitHub, X and others show when the repo's link is shared.
    mark = f'<g transform="scale({200 / 1024})">{tile(ids="w")}</g>'
    render(f"""<div style="width:1280px;height:640px;display:flex;flex-direction:column;align-items:center;justify-content:center;
        background:linear-gradient(160deg,#10172B,#1B2A5E);color:#fff;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1140 200" width="760" height="133">{mark}{wordmark(246, 186, "#fff")}</svg>
      <div style="font-size:35px;font-weight:400;margin-top:54px;opacity:.86;letter-spacing:.1px">Lets AI agents sign in to websites</div>
      <div style="font-size:35px;font-weight:400;margin-top:8px;opacity:.86;letter-spacing:.1px">without ever seeing your password.</div>
    </div>""", BRAND / "social-preview.png", 1280, 640)


if __name__ == "__main__":
    main()
