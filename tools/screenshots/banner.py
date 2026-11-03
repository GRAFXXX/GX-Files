#!/usr/bin/env python3
"""Обложка репозитория: assets/banner.png (README) и assets/social-preview.png (превью ссылки, 1280×640)."""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONT_DIRS = ['/usr/share/fonts/opentype/inter', '/Library/Fonts', os.path.expanduser('~/Library/Fonts')]

def font(name, size):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p): return ImageFont.truetype(p, size)
    return ImageFont.load_default(size)

def glow(img, xy, r, color):
    g = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse((xy[0] - r, xy[1] - r, xy[0] + r, xy[1] + r), fill=color)
    img.alpha_composite(g.filter(ImageFilter.GaussianBlur(r * 0.6)))

def icon(size):
    ic = Image.open(os.path.join(ROOT, 'assets/icon/dark.png')).convert('RGBA').resize((size, size), Image.LANCZOS)
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.225), fill=255)
    ic.putalpha(m)
    return ic

def chip(d, x, y, text, f):
    w = d.textlength(text, font=f)
    d.rounded_rectangle((x, y, x + w + 36, y + 46), radius=23, fill=(124, 92, 255, 38), outline=(150, 120, 255, 110), width=2)
    d.text((x + 18, y + 23), text, font=f, fill=(226, 220, 255), anchor='lm')
    return x + w + 36 + 12

def make(W, H, out):
    img = Image.new('RGBA', (W, H), (10, 9, 16, 255))
    glow(img, (int(W * 0.18), int(H * 0.45)), int(H * 0.55), (110, 60, 255, 120))
    glow(img, (int(W * 0.95), int(H * 0.05)), int(H * 0.45), (170, 70, 255, 70))
    glow(img, (int(W * 0.75), int(H * 1.05)), int(H * 0.5), (60, 40, 200, 70))
    s = int(H * 0.56)
    ix, iy = int(W * 0.06), (H - s) // 2
    sh = Image.new('RGBA', img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((ix + 8, iy + 18, ix + s + 8, iy + s + 18), radius=int(s * 0.225), fill=(0, 0, 0, 160))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(22)))
    img.alpha_composite(icon(s), (ix, iy))
    d = ImageDraw.Draw(img)
    tx = ix + s + int(W * 0.05)
    d.text((tx, int(H * 0.17)), 'GX Files', font=font('Inter-ExtraBold.otf', int(H * 0.15)), fill=(255, 255, 255))
    d.text((tx + 4, int(H * 0.37)), 'File manager & binary editor for iPhone', font=font('Inter-Medium.otf', int(H * 0.05)), fill=(196, 188, 230))
    f = font('Inter-SemiBold.otf', int(H * 0.034))
    rows = [['ZIP · APK · IPA', 'plist · SQLite · hex'], ['Mach-O / ELF editor', 'ARM64 disassembler'], ['C → dylib on device', '8 languages']]
    y = int(H * 0.50)
    for r in rows:
        x = tx
        for t in r: x = chip(d, x, y, t, f)
        y += int(H * 0.095)
    d.text((tx + 4, int(H * 0.86)), 'LiveContainer · Feather · SideStore · TrollStore   ·   open source, GPL-3.0',
           font=font('Inter-Regular.otf', int(H * 0.03)), fill=(150, 142, 185))
    img.convert('RGB').save(out, optimize=True)
    print(out)

os.makedirs(os.path.join(ROOT, 'assets'), exist_ok=True)
make(1280, 640, os.path.join(ROOT, 'assets/social-preview.png'))
make(1600, 640, os.path.join(ROOT, 'assets/banner.png'))
