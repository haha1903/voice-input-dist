#!/usr/bin/env python3
"""Generate a 1024x1024 app icon for VoiceInput.

The design: a rounded-square background with a soft blue-to-purple gradient,
a centered white microphone glyph (body + base + stand), and a subtle inner
shadow for depth. Exported as icon_1024.png. `make-icns.sh` then rasterises
it into a proper .icns bundle.
"""
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = "icon_1024.png"

# Base transparent canvas (2x oversampled for AA then downsampled)
S = SIZE * 2
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- Background: rounded square with vertical gradient ---
radius = int(S * 0.22)            # Apple's "squircle" corner radius ratio
top_color = (74, 110, 240)        # calm blue
bot_color = (131, 86, 232)        # purple

gradient = Image.new("RGB", (S, S), top_color)
grad_draw = ImageDraw.Draw(gradient)
for y in range(S):
    t = y / (S - 1)
    r = int(top_color[0] + (bot_color[0] - top_color[0]) * t)
    g = int(top_color[1] + (bot_color[1] - top_color[1]) * t)
    b = int(top_color[2] + (bot_color[2] - top_color[2]) * t)
    grad_draw.line([(0, y), (S, y)], fill=(r, g, b))

# Rounded-square mask
mask = Image.new("L", (S, S), 0)
mdraw = ImageDraw.Draw(mask)
mdraw.rounded_rectangle((0, 0, S - 1, S - 1), radius=radius, fill=255)
img.paste(gradient, (0, 0), mask)

# --- Microphone glyph (centered, white) ---
draw = ImageDraw.Draw(img)
cx = S // 2

# Mic capsule: rounded rectangle
cap_w = int(S * 0.28)
cap_h = int(S * 0.44)
cap_top = int(S * 0.22)
cap_left = cx - cap_w // 2
cap_right = cx + cap_w // 2
cap_bot = cap_top + cap_h
draw.rounded_rectangle(
    (cap_left, cap_top, cap_right, cap_bot),
    radius=cap_w // 2,
    fill=(255, 255, 255, 255),
)

# Arc (the U-shaped holder under the capsule)
arc_w = int(cap_w * 1.6)
arc_h = int(cap_h * 0.55)
arc_left = cx - arc_w // 2
arc_top = cap_bot - arc_h // 2
arc_right = cx + arc_w // 2
arc_bot = arc_top + arc_h
stroke = int(S * 0.028)
draw.arc(
    (arc_left, arc_top, arc_right, arc_bot),
    start=0, end=180,
    fill=(255, 255, 255, 255),
    width=stroke,
)

# Stand (vertical line) + base (short horizontal line)
stand_top = arc_bot - stroke // 2
stand_bot = int(S * 0.85)
draw.line(
    [(cx, stand_top), (cx, stand_bot)],
    fill=(255, 255, 255, 255),
    width=stroke,
)
base_half = int(S * 0.09)
draw.line(
    [(cx - base_half, stand_bot), (cx + base_half, stand_bot)],
    fill=(255, 255, 255, 255),
    width=stroke,
)

# --- Soft inner glow for depth (subtle) ---
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gdraw = ImageDraw.Draw(glow)
gdraw.rounded_rectangle(
    (0, 0, S - 1, S - 1),
    radius=radius,
    outline=(255, 255, 255, 60),
    width=int(S * 0.006),
)
glow = glow.filter(ImageFilter.GaussianBlur(radius=int(S * 0.003)))
img = Image.alpha_composite(img, glow)

# Downsample for anti-aliasing
img = img.resize((SIZE, SIZE), Image.LANCZOS)
img.save(OUT)
print(f"Wrote {OUT}")
