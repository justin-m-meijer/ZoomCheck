#!/usr/bin/env python3
"""Renders the ZoomCheck app icon (Resources/AppIcon.png and Resources/AppIcon.icns).

Requires Pillow and a bold sans font (Poppins Bold by default, override with ICON_FONT).
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 4                      # supersampling factor
N = 1024 * S               # working canvas size
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FONT = os.environ.get("ICON_FONT", "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf")


def px(v):
    return int(round(v * S))


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def vertical_gradient(size, top, bottom):
    w, h = size
    col = Image.new("RGBA", (1, h))
    for y in range(h):
        col.putpixel((0, y), lerp(top, bottom, y / (h - 1)))
    return col.resize((w, h))


def radial_gradient(size, center, radius, inner, outer):
    w, h = size
    g = Image.new("L", (256, 256))
    for y in range(256):
        for x in range(256):
            d = math.hypot(x - 128, y - 128) / 128
            g.putpixel((x, y), int(min(d, 1) * 255))
    g = g.resize((radius * 2, radius * 2), Image.BICUBIC)
    a = Image.new("RGBA", (radius * 2, radius * 2), inner)
    b = Image.new("RGBA", (radius * 2, radius * 2), outer)
    disc = Image.composite(b, a, g)
    out = Image.new("RGBA", size, outer)
    out.paste(disc, (center[0] - radius, center[1] - radius))
    return out


def circle_mask(size, center, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r], fill=255)
    return m


def main():
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # macOS icon grid: 824×824 body centred on a 1024 canvas.
    body = (px(100), px(100), px(924), px(924))
    radius = px(185)

    # Soft drop shadow.
    shadow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + px(14), body[2], body[3] + px(14)), radius, fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(18)))
    canvas.paste(Image.new("RGBA", (N, N), (10, 10, 30, 255)), (0, 0), shadow)

    # Background: indigo to violet.
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius, fill=255)
    bg = vertical_gradient((N, N), (49, 46, 129, 255), (124, 58, 237, 255))
    # Warm glow behind the lens.
    glow = radial_gradient((N, N), (px(512), px(470)), px(420), (251, 146, 60, 120), (251, 146, 60, 0))
    bg = Image.alpha_composite(bg, glow)
    canvas.paste(bg, (0, 0), mask)

    c = (px(512), px(486))
    draw = ImageDraw.Draw(canvas)

    # Lens barrel: outer dark ring with metallic edge.
    r_outer = px(300)
    lens_shadow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(lens_shadow).ellipse(
        [c[0] - r_outer, c[1] - r_outer + px(16), c[0] + r_outer, c[1] + r_outer + px(16)], fill=140)
    lens_shadow = lens_shadow.filter(ImageFilter.GaussianBlur(px(16)))
    canvas.paste(Image.new("RGBA", (N, N), (15, 10, 40, 255)), (0, 0), ImageChops.multiply(lens_shadow, mask))

    ring = vertical_gradient((N, N), (209, 213, 219, 255), (75, 85, 99, 255))
    canvas.paste(ring, (0, 0), circle_mask((N, N), c, r_outer))
    canvas.paste(Image.new("RGBA", (N, N), (17, 24, 39, 255)), (0, 0), circle_mask((N, N), c, px(282)))

    # Zoom ring tick marks (0.5x → 5x), brighter towards the telephoto end.
    for i in range(25):
        angle = math.radians(150 + i * 10)
        long = i % 4 == 0
        r1, r2 = px(250), px(276 if long else 268)
        t = i / 24
        color = lerp((148, 163, 184, 255), (251, 191, 36, 255), t)
        draw.line(
            [(c[0] + r1 * math.cos(angle), c[1] + r1 * math.sin(angle)),
             (c[0] + r2 * math.cos(angle), c[1] + r2 * math.sin(angle))],
            fill=color, width=px(7 if long else 4))

    # Inner barrel.
    canvas.paste(Image.new("RGBA", (N, N), (31, 41, 55, 255)), (0, 0), circle_mask((N, N), c, px(236)))
    canvas.paste(Image.new("RGBA", (N, N), (3, 7, 18, 255)), (0, 0), circle_mask((N, N), c, px(214)))

    # Glass: deep blue with a teal core.
    glass = radial_gradient((N, N), (c[0] + px(30), c[1] + px(30)), px(200),
                            (34, 211, 238, 255), (12, 18, 60, 255))
    canvas.paste(glass, (0, 0), circle_mask((N, N), c, px(196)))

    # Concentric inner element rings.
    for r, a in ((px(150), 90), (px(104), 70)):
        draw.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], outline=(186, 230, 253, a), width=px(5))
    pupil = radial_gradient((N, N), c, px(62), (8, 15, 45, 255), (2, 6, 23, 255))
    canvas.paste(pupil, (0, 0), circle_mask((N, N), c, px(62)))

    # Specular highlights.
    hl = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.ellipse([c[0] - px(150), c[1] - px(165), c[0] - px(20), c[1] - px(75)], fill=(255, 255, 255, 150))
    hd.ellipse([c[0] + px(70), c[1] + px(80), c[0] + px(110), c[1] + px(115)], fill=(255, 255, 255, 90))
    hl = hl.filter(ImageFilter.GaussianBlur(px(10)))
    canvas = Image.alpha_composite(canvas, Image.composite(hl, Image.new("RGBA", (N, N)), circle_mask((N, N), c, px(196))))

    # "2×" badge, bottom right.
    draw = ImageDraw.Draw(canvas)
    badge = (px(586), px(682), px(846), px(842))
    bshadow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(bshadow).rounded_rectangle(
        (badge[0], badge[1] + px(10), badge[2], badge[3] + px(10)), px(80), fill=120)
    bshadow = bshadow.filter(ImageFilter.GaussianBlur(px(12)))
    canvas.paste(Image.new("RGBA", (N, N), (60, 20, 0, 255)), (0, 0), bshadow)
    bmask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(bmask).rounded_rectangle(badge, px(80), fill=255)
    canvas.paste(vertical_gradient((N, N), (252, 211, 77, 255), (249, 115, 22, 255)), (0, 0), bmask)

    try:
        font = ImageFont.truetype(FONT, px(118))
    except OSError:
        sys.exit(f"Font not found: {FONT} (set ICON_FONT)")
    draw = ImageDraw.Draw(canvas)
    label = "2×"
    bx = (badge[0] + badge[2]) / 2
    by = (badge[1] + badge[3]) / 2
    draw.text((bx, by + px(6)), label, font=font, fill=(255, 255, 255, 255), anchor="mm")

    icon = canvas.resize((1024, 1024), Image.LANCZOS)
    out_dir = os.path.join(ROOT, "Resources")
    icon.save(os.path.join(out_dir, "AppIcon.png"))
    icon.save(os.path.join(out_dir, "AppIcon.icns"))
    print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
