#!/usr/bin/env python3
"""Иконки приложения из assets/icon/*.png (1024×1024).
    python3 make_icon.py <папка .app>              — PNG-иконки (основная — dark.png)
    python3 make_icon.py --xcassets <папка>        — каталог Assets.xcassets со светлой/тёмной/тонированной иконкой (для actool)
"""
import json, os, sys
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
ICON = os.path.join(HERE, 'assets', 'icon')

def png(name, size, out):
    Image.open(os.path.join(ICON, name)).convert('RGB').resize((size, size), Image.LANCZOS).save(out, optimize=True)

if len(sys.argv) > 2 and sys.argv[1] == '--xcassets':
    root = os.path.join(sys.argv[2], 'Assets.xcassets')
    s = os.path.join(root, 'AppIcon.appiconset')
    os.makedirs(s, exist_ok=True)
    json.dump({'info': {'author': 'xcode', 'version': 1}}, open(os.path.join(root, 'Contents.json'), 'w'))
    for n in ('light', 'dark', 'mono'): png(n + '.png', 1024, os.path.join(s, n + '.png'))
    img = lambda f, app=None: dict({'filename': f, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
                                   **({'appearances': [{'appearance': 'luminosity', 'value': app}]} if app else {}))
    json.dump({'images': [img('light.png'), img('dark.png', 'dark'), img('mono.png', 'tinted')],
               'info': {'author': 'xcode', 'version': 1}}, open(os.path.join(s, 'Contents.json'), 'w'), indent=1)
    sys.exit(0)

d = sys.argv[1]
for size, name in [(120, 'AppIcon60x60@2x.png'), (180, 'AppIcon60x60@3x.png'),
                   (152, 'AppIcon76x76@2x~ipad.png'), (167, 'AppIcon83.5x83.5@2x~ipad.png'), (512, 'icon512.png')]:
    png('dark.png', size, os.path.join(d, name))
