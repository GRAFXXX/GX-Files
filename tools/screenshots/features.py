#!/usr/bin/env python3
"""Карточки возможностей для README: assets/features/1..4.png и assets/features/all.png.
Это иллюстрации (иконки + текст), а не скриншоты — настоящие скриншоты оформляет frame.py."""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'assets', 'features')
FD = ['/usr/share/fonts/opentype/inter', '/Library/Fonts', os.path.expanduser('~/Library/Fonts')]
def font(n, s):
    for d in FD:
        p = os.path.join(d, n)
        if os.path.exists(p): return ImageFont.truetype(p, s)
    return ImageFont.load_default(s)

W, H = 900, 1200
ACC = (124, 92, 255); ACC2 = (176, 92, 255); WHITE = (255, 255, 255)

def bg():
    img = Image.new('RGBA', (W, H), (12, 10, 20, 255))
    g = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(g)
    d.ellipse((-300, -200, 900, 800), fill=(110, 60, 255, 120))
    d.ellipse((300, 700, 1300, 1500), fill=(170, 70, 255, 70))
    img.alpha_composite(g.filter(ImageFilter.GaussianBlur(170)))
    return img

def tile(img, cx, cy, r=150):
    sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((cx - r + 10, cy - r + 24, cx + r + 10, cy + r + 24), radius=int(r * 0.45), fill=(0, 0, 0, 170))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(28)))
    t = Image.new('RGBA', (2 * r, 2 * r), (0, 0, 0, 0)); td = ImageDraw.Draw(t)
    for y in range(2 * r):                                   # вертикальный градиент
        k = y / (2 * r); c = tuple(int(ACC[i] + (ACC2[i] - ACC[i]) * k) for i in range(3))
        td.line((0, y, 2 * r, y), fill=c + (255,))
    m = Image.new('L', (2 * r, 2 * r), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 2 * r - 1, 2 * r - 1), radius=int(r * 0.45), fill=255)
    t.putalpha(m); img.alpha_composite(t, (cx - r, cy - r))
    hl = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle((cx - r, cy - r, cx + r, cy + r), radius=int(r * 0.45), outline=(255, 255, 255, 60), width=3)
    img.alpha_composite(hl)

def icon_folder(d, cx, cy):
    d.rounded_rectangle((cx - 85, cy - 62, cx - 5, cy - 30), radius=12, fill=WHITE)
    d.rounded_rectangle((cx - 85, cy - 45, cx + 85, cy + 65), radius=18, fill=WHITE)
    d.rounded_rectangle((cx - 85, cy - 22, cx + 85, cy + 65), radius=18, fill=(232, 226, 255))

def icon_box(d, cx, cy):
    d.rounded_rectangle((cx - 80, cy - 55, cx + 80, cy + 70), radius=16, fill=WHITE)
    d.rounded_rectangle((cx - 92, cy - 75, cx + 92, cy - 35), radius=12, fill=(232, 226, 255))
    for i in range(5):                                       # молния-«zip»
        y = cy - 30 + i * 18
        d.rectangle((cx - 8 + (6 if i % 2 else -6), y, cx + 8 + (6 if i % 2 else -6), y + 10), fill=ACC)

def icon_chip(d, cx, cy):
    d.rounded_rectangle((cx - 60, cy - 60, cx + 60, cy + 60), radius=14, fill=WHITE)
    for i in range(4):
        o = -45 + i * 30
        for (x0, y0, x1, y1) in [(cx + o - 6, cy - 88, cx + o + 6, cy - 62), (cx + o - 6, cy + 62, cx + o + 6, cy + 88),
                                 (cx - 88, cy + o - 6, cx - 62, cy + o + 6), (cx + 62, cy + o - 6, cx + 88, cy + o + 6)]:
            d.rounded_rectangle((x0, y0, x1, y1), radius=4, fill=WHITE)
    d.text((cx, cy + 2), 'ARM', font=font('Inter-ExtraBold.otf', 40), fill=ACC, anchor='mm')

def icon_code(d, cx, cy):
    f = font('Inter-ExtraBold.otf', 120)
    d.text((cx, cy - 6), '{ }', font=f, fill=WHITE, anchor='mm')
    d.text((cx, cy + 92), 'C → dylib', font=font('Inter-Bold.otf', 30), fill=(240, 236, 255), anchor='mm')

CARDS = [
    ('Files, your way', icon_folder, ['Dual panels, favorites, recents', 'Search by name and content', 'Find & replace across folders', 'Wi‑Fi transfer from a browser']),
    ('Archives & apps', icon_box, ['Edit ZIP / APK / IPA in place', 'APK manifest + v1/v2 signing', 'IPA name, icon, Info.plist', 'plist, SQLite, hex editors']),
    ('Binary editor', icon_chip, ['Mach-O & ELF strings, in place', 'Objective-C headers (.h)', 'ARM64 disassembler + assembler', 'Approximate C pseudocode']),
    ('Compiler on iPhone', icon_code, ['TinyCC built into the app', 'Write C, get an arm64 dylib', 'iOS SDK headers + gxkit.h', 'Ad-hoc signed, ready to use']),
]

def card(title, ic, bullets):
    img = bg(); cx = W // 2
    tile(img, cx, 330)
    d = ImageDraw.Draw(img); ic(d, cx, 330)
    d.text((cx, 580), title, font=font('Inter-ExtraBold.otf', 66), fill=WHITE, anchor='mm')
    f = font('Inter-Medium.otf', 38); y = 700
    for b in bullets:
        d.ellipse((120, y - 9, 138, y + 9), fill=ACC2)
        d.text((160, y), b, font=f, fill=(214, 208, 240), anchor='lm'); y += 92
    d.text((cx, H - 70), 'GX Files', font=font('Inter-SemiBold.otf', 30), fill=(140, 130, 180), anchor='mm')
    return img.convert('RGB')

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    cards = [card(*c) for c in CARDS]
    for i, c in enumerate(cards, 1): c.save(os.path.join(OUT, '%d.png' % i), optimize=True)
    gap = 30; allimg = Image.new('RGB', (W * len(cards) + gap * (len(cards) - 1), H), (12, 10, 20))
    for i, c in enumerate(cards): allimg.paste(c, (i * (W + gap), 0))
    allimg.thumbnail((2400, 2400)); allimg.save(os.path.join(OUT, 'all.png'), optimize=True)
    print('ok')
