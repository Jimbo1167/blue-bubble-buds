#!/usr/bin/env python3
"""Generate the Blue Bubble Buds app icon.

Draws an iMessage-inspired icon (two friendly speech bubbles on an iOS-blue
squircle) at 1024x1024, then emits the standard macOS iconset sizes.

Output: Resources/AppIcon.iconset/  (feed to `iconutil -c icns`)
"""

from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Resources" / "AppIcon.iconset"


def rounded_mask(size: int, radius_frac: float = 0.22) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_frac)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=r, fill=255)
    return mask


def bubble(draw: ImageDraw.ImageDraw, cx: int, cy: int, w: int, h: int, *,
           fill, tail_dir: int) -> None:
    """Draw a rounded-rect speech bubble with a small tail.
    tail_dir: -1 for tail on lower-left, +1 for tail on lower-right.
    """
    left = cx - w // 2
    top = cy - h // 2
    right = cx + w // 2
    bottom = cy + h // 2
    radius = int(min(w, h) * 0.45)
    draw.rounded_rectangle((left, top, right, bottom), radius=radius, fill=fill)

    # Tail: small filled ellipse biting into the lower corner
    tail_r = int(min(w, h) * 0.12)
    if tail_dir < 0:
        tx, ty = left + int(w * 0.15), bottom - tail_r
    else:
        tx, ty = right - int(w * 0.15) - tail_r, bottom - tail_r
    draw.ellipse((tx, ty, tx + tail_r * 2, ty + tail_r * 2), fill=fill)


def draw_icon(size: int) -> Image.Image:
    # Draw at 4x, then downsample for antialiased edges.
    scale = 4
    S = size * scale

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Background gradient: iMessage blue on top → slightly darker at bottom.
    top_color = (10, 132, 255)       # iOS "systemBlue"
    bot_color = (0, 100, 220)
    for y in range(S):
        t = y / (S - 1)
        r = int(top_color[0] * (1 - t) + bot_color[0] * t)
        g = int(top_color[1] * (1 - t) + bot_color[1] * t)
        b = int(top_color[2] * (1 - t) + bot_color[2] * t)
        d.line(((0, y), (S, y)), fill=(r, g, b, 255))

    # Squircle mask for rounded app-icon shape
    mask = rounded_mask(S, radius_frac=0.22)
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg.paste(img, (0, 0), mask)

    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)

    # Back bubble (white, slightly larger, upper-left)
    bubble(od, S // 2 - int(S * 0.08), S // 2 - int(S * 0.10),
           int(S * 0.52), int(S * 0.40),
           fill=(255, 255, 255, 255), tail_dir=-1)

    # Front bubble (light blue, lower-right, overlaps back bubble)
    bubble(od, S // 2 + int(S * 0.10), S // 2 + int(S * 0.12),
           int(S * 0.50), int(S * 0.38),
           fill=(175, 215, 255, 255), tail_dir=+1)

    # Heart on the back bubble (little "reaction" accent)
    heart_color = (255, 70, 100, 255)
    hx, hy = S // 2 - int(S * 0.14), S // 2 - int(S * 0.16)
    hr = int(S * 0.05)
    od.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=heart_color)
    od.ellipse((hx + hr // 2, hy - hr, hx + hr * 2 + hr // 2, hy + hr), fill=heart_color)
    od.polygon(
        [(hx - hr, hy), (hx + hr * 2 + hr // 2, hy),
         (hx + hr // 2, hy + int(hr * 2.2))],
        fill=heart_color,
    )

    # Three dots (stuck-sticker accent) on the front bubble
    dot_color = (10, 132, 255, 255)
    dxs = [S // 2 + int(S * 0.02), S // 2 + int(S * 0.10), S // 2 + int(S * 0.18)]
    dy = S // 2 + int(S * 0.12)
    dr = int(S * 0.025)
    for dx in dxs:
        od.ellipse((dx - dr, dy - dr, dx + dr, dy + dr), fill=dot_color)

    bg = Image.alpha_composite(bg, overlay)
    bg = bg.filter(ImageFilter.SMOOTH_MORE)

    return bg.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # Apple's required iconset names and sizes
    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    master = draw_icon(1024)
    for name, size in sizes:
        path = OUT_DIR / name
        if size == 1024:
            master.save(path)
        else:
            master.resize((size, size), Image.LANCZOS).save(path)
        print(f"  wrote {path.relative_to(ROOT)}")
    print(f"\nDone. Convert to .icns with:")
    print(f"  iconutil -c icns {OUT_DIR.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
