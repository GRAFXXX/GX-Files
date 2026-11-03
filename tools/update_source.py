#!/usr/bin/env python3
"""Обновляет source/apps.json — источник для Feather / SideStore / AltStore.
    python3 tools/update_source.py <владелец/репозиторий> [тег] [путь к ipa]
Запускается автоматически в GitHub Actions при каждом релизе (тег v…)."""
import json, os, plistlib, sys, datetime
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
repo = sys.argv[1] if len(sys.argv) > 1 else 'YOUR_NAME/gx-files'
tag = sys.argv[2] if len(sys.argv) > 2 else None
ipa = sys.argv[3] if len(sys.argv) > 3 else os.path.join(ROOT, 'GXFiles.ipa')
info = plistlib.load(open(os.path.join(ROOT, 'Info.plist'), 'rb'))
ver = info['CFBundleShortVersionString']
size = os.path.getsize(ipa) if os.path.exists(ipa) else 0
url = f'https://github.com/{repo}/releases/download/{tag}/GXFiles.ipa' if tag else f'https://github.com/{repo}/releases/latest/download/GXFiles.ipa'
raw = f'https://raw.githubusercontent.com/{repo}/main'
date = datetime.date.today().isoformat()
desc = ('File manager for iPhone: archives, APK/IPA, plist, SQLite, hex, Mach-O/ELF editor with an ARM64 '
        'disassembler and an on-device C → dylib compiler. Works as a regular app and inside LiveContainer.')
p = os.path.join(ROOT, 'source', 'apps.json')
old = json.load(open(p)) if os.path.exists(p) else {}
versions = [v for v in (old.get('apps') or [{}])[0].get('versions', []) if v.get('version') != ver]
versions.insert(0, {'version': ver, 'buildVersion': info['CFBundleVersion'], 'date': date, 'size': size,
                    'downloadURL': url, 'minOSVersion': info.get('MinimumOSVersion', '15.0'),
                    'localizedDescription': f'GX Files {ver}'})
src = {
    'name': 'GX Files', 'identifier': info['CFBundleIdentifier'] + '.source',
    'sourceURL': f'{raw}/source/apps.json', 'iconURL': f'{raw}/assets/icon/dark.png',
    'website': f'https://github.com/{repo}', 'tintColor': '#6B4BFF',
    'apps': [{
        'name': 'GX Files', 'bundleIdentifier': info['CFBundleIdentifier'], 'developerName': repo.split('/')[0],
        'subtitle': 'File manager, archive & binary editor', 'localizedDescription': desc,
        'iconURL': f'{raw}/assets/icon/dark.png', 'tintColor': '#6B4BFF', 'category': 'utilities',
        'version': ver, 'versionDate': date, 'downloadURL': url, 'size': size, 'versions': versions[:10],
    }],
    'news': [],
}
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(src, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('source/apps.json →', ver, url)
