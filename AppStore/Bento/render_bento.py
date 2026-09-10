#!/usr/bin/env python3
"""Render Keynote-inspired Bento feature grids for Meal Plan."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "AppStore" / "Bento"
SOURCE = OUT / "source"
SCREEN_DIR = ROOT / "AppStore" / "iPhone"

BG = (244, 244, 246)
CARD = (251, 251, 252)
WHITE = (255, 255, 255)
INK = (24, 25, 28)
MUTED = (104, 107, 113)
NAVY = (16, 46, 79)
BLUE = (26, 125, 242)
GREEN = (67, 150, 102)
RED = (220, 76, 70)
ORANGE = (240, 146, 44)
PURPLE = (145, 92, 202)

FONT_BOLD = "/Library/Fonts/SF-Pro-Display-Bold.otf"
FONT_MEDIUM = "/Library/Fonts/SF-Pro-Display-Medium.otf"
FONT_TEXT = "/Library/Fonts/SF-Pro-Text-Regular.otf"
FONT_SEMIBOLD = "/Library/Fonts/SF-Pro-Text-Semibold.otf"


def font(path, size):
    return ImageFont.truetype(path, max(8, round(size)))


def rr_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def cover(image, size, focus=(0.5, 0.5)):
    image = image.convert("RGB")
    scale = max(size[0] / image.width, size[1] / image.height)
    resized = image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.LANCZOS)
    left = max(0, min(resized.width - size[0], round((resized.width - size[0]) * focus[0])))
    top = max(0, min(resized.height - size[1], round((resized.height - size[1]) * focus[1])))
    return resized.crop((left, top, left + size[0], top + size[1]))


def contain(image, size):
    scale = min(size[0] / image.width, size[1] / image.height)
    return image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.LANCZOS)


def add_shadow(canvas, box, radius, strength=28):
    x, y, w, h = box
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        (x + 2, y + 8, x + w + 2, y + h + 8), radius=radius, fill=(20, 23, 30, strength)
    )
    canvas.alpha_composite(layer.filter(ImageFilter.GaussianBlur(max(8, radius // 3))))


def new_tile(canvas, box, fill=CARD, radius=None):
    x, y, w, h = box
    radius = radius or max(26, min(w, h) // 10)
    add_shadow(canvas, box, radius)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x, y, x + w, y + h), radius=radius, fill=fill, outline=(232, 232, 235), width=2)
    return d, radius


def wrap(draw, text, f, max_width):
    words, lines, current = text.split(), [], ""
    for word in words:
        trial = word if not current else current + " " + word
        if draw.textlength(trial, font=f) <= max_width:
            current = trial
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return "\n".join(lines)


def title(draw, box, text, size=None, align="center", color=INK, top_pad=None, max_lines=2):
    x, y, w, h = box
    size = size or max(25, min(48, w * 0.09))
    f = font(FONT_BOLD, size)
    pad = top_pad if top_pad is not None else max(24, h * 0.055)
    wrapped = "\n".join(wrap(draw, text, f, w - 52).splitlines()[:max_lines])
    anchor = "ma" if align == "center" else "la"
    tx = x + w / 2 if align == "center" else x + 30
    draw.multiline_text((tx, y + pad), wrapped, font=f, fill=color, anchor=anchor, align=align, spacing=-2)


def paste_rounded(canvas, image, box, radius, focus=(0.5, 0.5)):
    x, y, w, h = box
    img = cover(image, (w, h), focus).convert("RGBA")
    img.putalpha(rr_mask((w, h), radius))
    canvas.alpha_composite(img, (x, y))


def tint_mark(size, color):
    mark = sources["mark"].copy()
    alpha = mark.getchannel("A")
    mark = Image.new("RGBA", mark.size, color + (255,))
    mark.putalpha(alpha)
    return contain(mark, size)


def soft_gradient(size):
    w, h = size
    base = Image.new("RGBA", size, (91, 197, 246, 255))
    blobs = [
        ((-w * .10, h * .22), w * .72, (86, 215, 211, 255)),
        ((w * .56, -h * .18), w * .68, (250, 193, 93, 255)),
        ((w * .68, h * .62), w * .70, (225, 75, 137, 255)),
        ((w * .18, h * .72), w * .60, (106, 112, 232, 255)),
    ]
    for (cx, cy), diameter, color in blobs:
        layer = Image.new("RGBA", size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse(
            (cx - diameter / 2, cy - diameter / 2, cx + diameter / 2, cy + diameter / 2), fill=color
        )
        base = Image.alpha_composite(base, layer.filter(ImageFilter.GaussianBlur(round(diameter * .20))))
    return base


def hero_tile(canvas, box):
    x, y, w, h = box
    radius = max(30, min(w, h) // 9)
    add_shadow(canvas, box, radius, 36)
    tile = soft_gradient((w, h))
    gloss = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    ImageDraw.Draw(gloss).ellipse((-w * .1, -h * .8, w * 1.05, h * .7), fill=(255, 255, 255, 40))
    tile = Image.alpha_composite(tile, gloss.filter(ImageFilter.GaussianBlur(max(20, h // 9))))
    tile.putalpha(rr_mask((w, h), radius))
    canvas.alpha_composite(tile, (x, y))
    d = ImageDraw.Draw(canvas)
    hero_size = min(96, max(54, w * .10))
    d.text((x + w / 2, y + h * .52), "Meal Plan", font=font(FONT_MEDIUM, hero_size), fill=WHITE, anchor="mm")
    d.text((x + w / 2, y + h * .77), "Plan · Cook · Shop", font=font(FONT_SEMIBOLD, hero_size * .30), fill=(255, 255, 255, 225), anchor="mm")
    mark = tint_mark((round(w * .18), round(h * .18)), WHITE)
    canvas.alpha_composite(mark, (round(x + w / 2 - mark.width / 2), round(y + h * .13)))


def screenshot_tile(canvas, box, key, label, accent, focus=(0.5, 0.08)):
    x, y, w, h = box
    d, radius = new_tile(canvas, box, CARD)
    fs = max(26, min(50, w * .085))
    title(d, box, label, fs)
    top = y + round(max(96, fs * 2.6))
    pad = max(16, round(min(w, h) * .045))
    image_box = (x + pad, top, w - pad * 2, y + h - top - pad)
    source = sources[key]
    # The legacy App Store images already carry headlines above their device
    # mockups. Remove that band so each Bento tile has one clean label only.
    source = source.crop((0, 220, source.width, source.height))
    paste_rounded(canvas, source, image_box, max(18, radius // 2), focus)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle((x + w - 34, y + 22, x + w - 18, y + 38), radius=8, fill=accent)


def draw_cloud(d, cx, cy, scale, color):
    d.ellipse((cx - 1.25 * scale, cy - .2 * scale, cx + .15 * scale, cy + .85 * scale), fill=color)
    d.ellipse((cx - .45 * scale, cy - .9 * scale, cx + .85 * scale, cy + .75 * scale), fill=color)
    d.ellipse((cx + .35 * scale, cy - .25 * scale, cx + 1.25 * scale, cy + .78 * scale), fill=color)
    d.rounded_rectangle((cx - 1.25 * scale, cy + .15 * scale, cx + 1.25 * scale, cy + .8 * scale), radius=scale * .3, fill=color)


def feature_tile(canvas, box, label, kind, accent=BLUE, dark=False):
    x, y, w, h = box
    fill = NAVY if dark else CARD
    text_color = WHITE if dark else INK
    d, _ = new_tile(canvas, box, fill)
    fs = max(24, min(46, w * .09))
    title(d, box, label, fs, color=text_color)
    cx, cy = x + w / 2, y + h * .64
    s = min(w, h) * .15

    if kind == "offline":
        draw_cloud(d, cx, cy, s * .72, (222, 234, 244))
        d.ellipse((cx + s * .25, cy + s * .05, cx + s * 1.0, cy + s * .8), fill=GREEN)
        d.line((cx + s * .43, cy + s * .42, cx + s * .57, cy + s * .57, cx + s * .84, cy + s * .25), fill=WHITE, width=max(4, round(s * .1)), joint="curve")
    elif kind == "translate":
        r = s * .72
        d.rounded_rectangle((cx - 1.15 * s, cy - r, cx + .15 * s, cy + r), radius=r * .35, fill=(229, 236, 255))
        d.rounded_rectangle((cx - .15 * s, cy - .45 * r, cx + 1.15 * s, cy + 1.05 * r), radius=r * .35, fill=(235, 226, 251))
        d.text((cx - .5 * s, cy), "A", font=font(FONT_BOLD, s * .9), fill=BLUE, anchor="mm")
        d.text((cx + .5 * s, cy + .26 * s), "文", font=font(FONT_BOLD, s * .65), fill=PURPLE, anchor="mm")
    elif kind == "watch":
        ww, wh = s * 1.55, s * 1.85
        d.rounded_rectangle((cx - ww / 2, cy - wh / 2, cx + ww / 2, cy + wh / 2), radius=s * .38, fill=(48, 50, 55), outline=(195, 197, 201), width=max(3, round(s * .06)))
        d.rounded_rectangle((cx - ww * .38, cy - wh * .34, cx + ww * .38, cy + wh * .34), radius=s * .22, fill=(14, 22, 31))
        for i, color in enumerate((BLUE, GREEN, ORANGE)):
            yy = cy - s * .35 + i * s * .36
            d.rounded_rectangle((cx - s * .43, yy, cx + s * .43, yy + s * .18), radius=s * .09, fill=color)
    elif kind == "import":
        pw, ph = s * 1.35, s * 1.6
        d.rounded_rectangle((cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2), radius=s * .14, fill=(235, 240, 246), outline=accent, width=max(3, round(s * .06)))
        d.line((cx - s * .38, cy - s * .25, cx + s * .38, cy - s * .25), fill=MUTED, width=max(3, round(s * .05)))
        d.line((cx - s * .38, cy, cx + s * .22, cy), fill=MUTED, width=max(3, round(s * .05)))
        d.polygon(((cx, cy + s * .32), (cx + s * .42, cy + s * .32), (cx + s * .21, cy + s * .62)), fill=accent)
    elif kind == "household":
        for dx, color in ((-s * .65, BLUE), (0, GREEN), (s * .65, ORANGE)):
            d.ellipse((cx + dx - s * .25, cy - s * .55, cx + dx + s * .25, cy - s * .05), fill=color)
            d.rounded_rectangle((cx + dx - s * .38, cy + s * .05, cx + dx + s * .38, cy + s * .62), radius=s * .22, fill=color)
    elif kind == "nutrition":
        r = s * 1.05
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(230, 235, 239))
        d.pieslice((cx - r, cy - r, cx + r, cy + r), -90, 35, fill=GREEN)
        d.pieslice((cx - r, cy - r, cx + r, cy + r), 35, 145, fill=ORANGE)
        d.pieslice((cx - r, cy - r, cx + r, cy + r), 145, 255, fill=BLUE)
        d.ellipse((cx - r * .52, cy - r * .52, cx + r * .52, cy + r * .52), fill=fill)
        d.text((cx, cy), "kcal", font=font(FONT_SEMIBOLD, s * .34), fill=text_color, anchor="mm")
    elif kind == "calendar":
        rw, rh = s * 1.75, s * 1.45
        d.rounded_rectangle((cx - rw / 2, cy - rh / 2, cx + rw / 2, cy + rh / 2), radius=s * .18, fill=WHITE, outline=(210, 212, 216), width=max(2, round(s * .04)))
        d.rounded_rectangle((cx - rw / 2, cy - rh / 2, cx + rw / 2, cy - rh * .19), radius=s * .17, fill=RED)
        for row in range(2):
            for col in range(4):
                xx = cx - rw * .34 + col * rw * .23
                yy = cy - rh * .02 + row * rh * .32
                d.ellipse((xx - s * .08, yy - s * .08, xx + s * .08, yy + s * .08), fill=BLUE if (row + col) % 3 == 0 else (198, 200, 205))
    elif kind == "cooking":
        r = s * .95
        d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=ORANGE, width=max(7, round(s * .16)))
        d.line((cx, cy, cx, cy - r * .62), fill=text_color, width=max(5, round(s * .10)))
        d.line((cx, cy, cx + r * .52, cy + r * .28), fill=text_color, width=max(5, round(s * .10)))
        d.ellipse((cx - s * .11, cy - s * .11, cx + s * .11, cy + s * .11), fill=ORANGE)
    elif kind == "ecosystem":
        widths = (s * .82, s * 1.35, s * 1.85)
        heights = (s * 1.28, s * 1.05, s * .96)
        offsets = (-s * 1.25, 0, s * 1.35)
        for ww, hh, dx in zip(widths, heights, offsets):
            d.rounded_rectangle((cx + dx - ww / 2, cy - hh / 2, cx + dx + ww / 2, cy + hh / 2), radius=s * .16, outline=(205, 211, 219), width=max(3, round(s * .06)), fill=(242, 246, 250))
            d.rounded_rectangle((cx + dx - ww * .32, cy - hh * .20, cx + dx + ww * .32, cy + hh * .18), radius=s * .08, fill=BLUE)


def grid_geometry(size, cols, row_heights, margin, gap):
    width, _ = size
    col_w = (width - margin * 2 - gap * (cols - 1)) / cols
    xs = [round(margin + i * (col_w + gap)) for i in range(cols)]
    ys, cursor = [], margin
    for height in row_heights:
        ys.append(round(cursor))
        cursor += height + gap

    def box(col, row, col_span=1, row_span=1):
        x, y = xs[col], ys[row]
        right = xs[col + col_span - 1] + round(col_w)
        height = sum(row_heights[row:row + row_span]) + gap * (row_span - 1)
        return (x, y, right - x, round(height))

    return box


def render_format(name, size, cols, rows, margin, gap, layout):
    canvas = Image.new("RGBA", size, BG + (255,))
    box = grid_geometry(size, cols, rows, margin, gap)
    for kind, pos, *args in layout:
        b = box(*pos)
        if kind == "hero":
            hero_tile(canvas, b)
        elif kind == "screen":
            screenshot_tile(canvas, b, *args)
        else:
            feature_tile(canvas, b, *args)
    target = OUT / name / f"meal-plan-feature-grid-{size[0]}x{size[1]}.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(target, quality=96)
    return target


def render_all():
    iphone = [
        ("hero", (0, 0, 2, 1)),
        ("feature", (2, 0, 1, 1), "Works offline", "offline", BLUE, False),
        ("screen", (0, 1, 2, 2), "plan", "Plan the whole week", BLUE, (0.5, 0.08)),
        ("feature", (2, 1, 1, 1), "Import recipes", "import", RED, False),
        ("feature", (2, 2, 1, 1), "On Apple Watch", "watch", BLUE, True),
        ("screen", (0, 3, 2, 1), "recipes", "A recipe library you’ll use", RED, (0.5, 0.08)),
        ("feature", (2, 3, 1, 1), "Translate recipes", "translate", PURPLE, False),
        ("screen", (0, 4, 1, 1), "shopping", "Shopping, sorted", GREEN, (0.5, 0.08)),
        ("screen", (1, 4, 2, 1), "widgets", "What’s next, at a glance", BLUE, (0.5, 0.05)),
        ("feature", (0, 5, 1, 1), "Share the household", "household", ORANGE, False),
        ("feature", (1, 5, 1, 1), "Nutrition estimates", "nutrition", GREEN, False),
        ("feature", (2, 5, 1, 1), "Hands-free cooking", "cooking", ORANGE, True),
    ]
    ipad = [
        ("hero", (0, 0, 3, 1)),
        ("feature", (3, 0, 1, 1), "Works offline", "offline", BLUE, False),
        ("feature", (4, 0, 1, 1), "Translate recipes", "translate", PURPLE, False),
        ("screen", (0, 1, 3, 2), "plan", "Plan the whole week", BLUE, (0.5, 0.08)),
        ("feature", (3, 1, 1, 1), "Import recipes", "import", RED, False),
        ("feature", (4, 1, 1, 1), "On Apple Watch", "watch", BLUE, True),
        ("screen", (3, 2, 2, 1), "recipes", "A recipe library you’ll use", RED, (0.5, 0.08)),
        ("screen", (0, 3, 2, 1), "shopping", "Shopping, sorted", GREEN, (0.5, 0.08)),
        ("screen", (2, 3, 3, 1), "widgets", "What’s next, at a glance", BLUE, (0.5, 0.05)),
        ("feature", (0, 4, 1, 1), "Share the household", "household", ORANGE, False),
        ("feature", (1, 4, 2, 1), "Nutrition estimates", "nutrition", GREEN, False),
        ("feature", (3, 4, 1, 1), "Calendar aware", "calendar", RED, False),
        ("feature", (4, 4, 1, 1), "Hands-free cooking", "cooking", ORANGE, True),
    ]
    mac = [
        ("hero", (0, 0, 3, 1)),
        ("feature", (3, 0, 1, 1), "Works offline", "offline", BLUE, False),
        ("feature", (4, 0, 1, 1), "Translate recipes", "translate", PURPLE, False),
        ("feature", (5, 0, 2, 1), "Meal Plan on Apple Watch", "watch", BLUE, True),
        ("screen", (0, 1, 3, 2), "plan", "Plan the whole week", BLUE, (0.5, 0.08)),
        ("screen", (3, 1, 2, 1), "recipes", "Your recipe library", RED, (0.5, 0.08)),
        ("feature", (5, 1, 2, 1), "Import from the web or camera", "import", RED, False),
        ("screen", (3, 2, 2, 1), "shopping", "Shopping, sorted", GREEN, (0.5, 0.08)),
        ("screen", (5, 2, 2, 1), "widgets", "What’s next, at a glance", BLUE, (0.5, 0.05)),
        ("feature", (0, 3, 1, 1), "Shared household", "household", ORANGE, False),
        ("feature", (1, 3, 2, 1), "Nutrition estimates", "nutrition", GREEN, False),
        ("feature", (3, 3, 1, 1), "Calendar aware", "calendar", RED, False),
        ("feature", (4, 3, 1, 1), "Cooking mode", "cooking", ORANGE, True),
        ("feature", (5, 3, 2, 1), "iPhone · iPad · Mac", "ecosystem", BLUE, False),
    ]

    return [
        render_format("iPhone", (1284, 2778), 3, [348, 483, 483, 483, 483, 332], 28, 22, iphone),
        render_format("iPad", (2064, 2752), 5, [400, 550, 550, 550, 550], 32, 22, ipad),
        render_format("Mac", (2880, 1800), 7, [400, 410, 410, 440], 32, 22, mac),
    ]


if __name__ == "__main__":
    sources = {
        "plan": Image.open(SCREEN_DIR / "MealPlan Made easy.jpg").convert("RGB"),
        "recipes": Image.open(SCREEN_DIR / "Manage Recipes.jpg").convert("RGB"),
        "shopping": Image.open(SCREEN_DIR / "shopping list.jpg").convert("RGB"),
        "widgets": Image.open(SCREEN_DIR / "widgets.jpg").convert("RGB"),
        "mark": Image.open(SOURCE / "launch-mark.png").convert("RGBA"),
    }
    for path in render_all():
        print(path)
