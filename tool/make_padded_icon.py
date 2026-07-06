"""Generate an adaptive-icon-friendly padded version of Icon.png.

Goal:
- Whole hero image visible after any launcher mask (circle/squircle).
- No visible empty color band at the edges.

Approach:
- Canvas = square, size 1024.
- Background layer = the original icon blown up and heavily blurred so that
  the outer padding blends with the hero image (no hard color boundary).
- Foreground layer = the original icon scaled down to fit inside the
  adaptive icon safe zone (~72% of the foreground) and centered.
- Save the result as assets/Icon_padded.png so flutter_launcher_icons can
  consume it for both legacy and adaptive foreground.
"""

from PIL import Image, ImageFilter

SRC = "assets/Icon.png"
OUT = "assets/Icon_padded.png"
SIZE = 1024
INNER_RATIO = 0.72  # icon takes 72% of the foreground -> fully in safe zone

src = Image.open(SRC).convert("RGBA")

# Background = scaled up + blurred version of the icon so the padding blends.
bg = src.resize((int(SIZE * 1.35), int(SIZE * 1.35)), Image.LANCZOS)
bg = bg.filter(ImageFilter.GaussianBlur(radius=80))

canvas = Image.new("RGBA", (SIZE, SIZE), (79, 163, 217, 255))
# Center-crop the blurred background onto the canvas.
bx = (bg.width - SIZE) // 2
by = (bg.height - SIZE) // 2
canvas.paste(bg.crop((bx, by, bx + SIZE, by + SIZE)), (0, 0))

inner = int(SIZE * INNER_RATIO)
fg = src.resize((inner, inner), Image.LANCZOS)
offset = (SIZE - inner) // 2
canvas.paste(fg, (offset, offset), fg)

canvas.convert("RGB").save(OUT, "PNG", optimize=True)
print(f"Wrote {OUT} at {SIZE}x{SIZE}")
