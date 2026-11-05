<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <b>English</b> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.uk.md">Українська</a> ·
  <a href="README.be.md">Беларуская</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português</a>
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/GRAFXXX/GX-Files?label=release&color=7c5cff" alt="Release"></a>
  <a href="../../actions"><img src="https://img.shields.io/github/actions/workflow/status/GRAFXXX/GX-Files/build.yml?label=build" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-blue" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0">
</p>

**GX Files** is a native file manager for iPhone with a built-in archive, APK/IPA and binary editor — and a C compiler that builds dylibs right on the device. It runs as a regular app (Feather, SideStore, AltStore, TrollStore) and inside [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Install

**Add the source** to Feather, SideStore or AltStore — updates arrive automatically:

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**Or download** `GXFiles.ipa` from [Releases](../../releases/latest) and install it any way you like.

| Installed via | What you can access |
|---|---|
| Feather / SideStore / AltStore | “My files” (also in Files → On My iPhone → GX Files), linked folders, files shared into the app |
| LiveContainer | all of the above + LiveContainer’s shared folder, guest app data, tweaks |
| TrollStore / jailbreak | the whole file system |

## Features

**Files**
- Dual panels, favorites, recents, hidden files, thumbnails
- Copy, move, symlinks, batch rename with patterns
- Search by name and content, duplicate finder, storage analysis
- Find & replace text or hex across a folder — even inside ZIP/APK/IPA without unpacking
- Wi‑Fi transfer through a browser on your computer
- “Open in GX Files” from the share sheet; apk, dylib, so, dex and btx open in GX Files from the Files app
- Network drives over WebDAV — computer, NAS, Nextcloud; GitHub client: browse, download, edit and commit from the phone
- AI assistant: connect any AI — OpenAI, Claude, Gemini, DeepSeek, OpenRouter or a local Ollama / LM Studio — and let it edit files in a folder you choose (even all of LiveContainer), with confirmation, backups and undo — chats are saved and can be continued later

**Formats**
- ZIP, APK, IPA, JAR — edit right inside the archive; read tar, 7z, rar and more
- Text editor with syntax highlighting, hex editor, plist / JSON / .strings, SQLite with a SQL console
- APK: binary manifest decoding, v1 + v2 signing
- IPA: name, bundle ID, icon, Info.plist, device restrictions, extensions
- Game textures (.btx / .dds / SHTX), Assets.car, provisioning profiles

**Binary editor (Mach-O / ELF)**
- Strings — search and edit in place, with code references
- Objective-C classes → .h headers
- ARM64 disassembler, approximate C pseudocode, built-in assembler
- ARM64 emulator: run a function step by step in a sandbox and watch the registers
- Pseudocode structured into if/else/while, not just goto
- Security audit (SAST): flags strcpy/sprintf/system, MD5/SHA-1, disabled TLS checks
- Numbers and constants, embedded images and fonts, UI colors
- Ad-hoc re-signing after edits

**On-device compiler** — [TinyCC](https://github.com/TinyCC/tinycc) with iOS SDK headers and the `gxkit.h` helper: write C, get an arm64 dylib.

**8 languages** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Screenshots

<p align="center"><img src="assets/features/all.png" alt="GX Files"></p>

Real screenshots — coming soon.

## Build from source

**macOS (Xcode):**
```sh
python3 -m pip install pillow
bash build.sh
```

**Linux:** needs `clang`, `lld`, `zip`, Python 3 with Pillow and an iPhoneOS SDK:
```sh
SDK=/path/to/iPhoneOS.sdk bash build.sh
```

The result is `GXFiles.ipa`. Headers for the on-device compiler are generated from your SDK on the first build (`tools/sdk/make_sdk.py`); Apple files are not stored in the repository. On macOS the build also produces light, dark and tinted app icons (iOS 18+).

Every push is built by GitHub Actions; a `v*` tag publishes a release and updates the source for Feather / SideStore.

## Project layout

```
src/            UI (Objective-C)
src/core/       C core: Mach-O/ELF, ARM64, zip, APK signing, images
tcc/            TinyCC and on-device compiler resources
i18n/           UI translations
assets/         icons, banner
source/         source for Feather / SideStore / AltStore
tools/          string extraction, SDK generation, screenshots
```

## Contributing

Bug reports, ideas and translations are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Adding a language takes one file.

## Responsible use

The binary editor and compiler are meant for studying, debugging and modifying **your own** apps and apps you have the right to modify. Do not use GX Files to violate licenses, bypass protections, or cheat in other people’s services and online games.

## License

[GNU GPL v3](LICENSE). Bundled TinyCC is LGPL 2.1 — see [THIRD_PARTY.md](THIRD_PARTY.md).
