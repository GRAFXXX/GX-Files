#!/usr/bin/env python3
"""Оформляет настоящие скриншоты iPhone для README: рамка телефона, подпись, фон в стиле иконки.
    python3 tools/screenshots/frame.py shot1.png "Подпись" shot2.png "Подпись" …
Результат: assets/screenshots/1.png, 2.png, … и общая картинка assets/screenshots/all.png"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'assets', 'screenshots')
FONT_DIRS = ['/usr/share/fonts/opentype/inter', '/Library/Fonts', os.path.expanduser('~/Library/Fonts'), '/System/Library/Fonts']

def font(names, size):
    for d in FONT_DIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p): return ImageFont.truetype(p, size)
    return ImageFont.load_default(size)

def wrap(d, text, f, width):
    words, lines, cur = text.split(), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if d.textlength(t, font=f) <= width: cur = t
        else: lines.append(cur); cur = w
    if cur: lines.append(cur)
    return lines

def frame(shot, caption, W=900, H=1700):
    img = Image.new('RGBA', (W, H), (12, 10, 20, 255))
    g = Image.new('RGBA', (W, H), (0, 0, 0, 0)); gd = ImageDraw.Draw(g)
    gd.ellipse((-W * 0.3, -H * 0.1, W * 0.9, H * 0.55), fill=(110, 60, 255, 110))
    gd.ellipse((W * 0.3, H * 0.55, W * 1.4, H * 1.2), fill=(170, 70, 255, 70))
    img.alpha_composite(g.filter(ImageFilter.GaussianBlur(160)))
    d = ImageDraw.Draw(img)
    f = font(['Inter-Bold.otf', 'SFNSDisplay-Bold.otf', 'Helvetica.ttc'], 58)
    y = 90
    for line in wrap(d, caption, f, W - 120):
        d.text((W / 2, y), line, font=f, fill=(255, 255, 255), anchor='mt'); y += 72
    s = Image.open(shot).convert('RGB')
    pw = int(W * 0.74); ph = int(pw * s.height / s.width)
    maxh = H - y - 70
    if ph > maxh: ph = maxh; pw = int(ph * s.width / s.height)
    s = s.resize((pw, ph), Image.LANCZOS)
    bez = 18; r = int(pw * 0.13)
    x0 = (W - pw) // 2 - bez; y0 = y + 40
    sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((x0 + 10, y0 + 24, x0 + pw + 2 * bez + 10, y0 + ph + 2 * bez + 24), radius=r + bez, fill=(0, 0, 0, 170))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(30)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((x0, y0, x0 + pw + 2 * bez, y0 + ph + 2 * bez), radius=r + bez, fill=(28, 26, 36), outline=(90, 80, 130), width=3)
    m = Image.new('L', (pw, ph), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=r, fill=255)
    img.paste(s, (x0 + bez, y0 + bez), m)
    return img.convert('RGB')

if __name__ == '__main__':
    args = sys.argv[1:]
    if len(args) < 2 or len(args) % 2: sys.exit(__doc__)
    os.makedirs(OUT, exist_ok=True)
    frames = []
    for i in range(0, len(args), 2):
        fr = frame(args[i], args[i + 1]); frames.append(fr)
        p = os.path.join(OUT, '%d.png' % (i // 2 + 1)); fr.save(p, optimize=True); print(p)
    # общая картинка — все скриншоты в ряд
    gap = 30; w = sum(f.width for f in frames) + gap * (len(frames) - 1)
    allimg = Image.new('RGB', (w, frames[0].height), (12, 10, 20))
    x = 0
    for f in frames: allimg.paste(f, (x, 0)); x += f.width + gap
    allimg.thumbnail((2400, 2400)); allimg.save(os.path.join(OUT, 'all.png'), optimize=True)
    print(os.path.join(OUT, 'all.png'))
