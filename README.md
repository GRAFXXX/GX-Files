<p align="center">
  <img src="assets/icon/logo.png" width="128" alt="GX Files">
</p>

<h1 align="center">GX Files</h1>

<p align="center">
  Файловый менеджер для iPhone: архивы, APK/IPA, plist, SQLite, hex,<br>
  редактор Mach-O/ELF с дизассемблером ARM64 и компилятор C → dylib прямо на телефоне.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-15%2B-blue" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0">
  <img src="https://img.shields.io/badge/languages-8-purple" alt="8 languages">
</p>

<p align="center"><b>🇷🇺 Русский</b> · <a href="#english">🇬🇧 English</a></p>

---

## Скриншоты

<!-- Добавь 3–4 скриншота в папку assets/screenshots и раскомментируй строку ниже -->
<!-- <p align="center"><img src="assets/screenshots/1.png" width="200"> <img src="assets/screenshots/2.png" width="200"> <img src="assets/screenshots/3.png" width="200"></p> -->

## Установка

**Через Feather / SideStore / AltStore (источник):** добавь источник

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

и установи GX Files из него — обновления будут приходить сами.

**Вручную:** скачай `GXFiles.ipa` из [Releases](../../releases) и установи любым способом — Feather, SideStore, AltStore, TrollStore или внутрь [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

| Где установлен | Что доступно |
|---|---|
| Обычная установка | «Мои файлы» (видны в «Файлах» → «На iPhone» → GX Files), подключённые папки, файлы через «Поделиться» |
| LiveContainer | всё выше + общая папка LiveContainer, данные гостевых приложений, твики |
| TrollStore / джейлбрейк | вся файловая система, как у Filza |

## Возможности

**Файлы**
- Две панели, избранное, недавние, скрытые файлы, миниатюры
- Копирование, перемещение, символические ссылки, пакетное переименование по шаблону
- Поиск по имени и содержимому, дубликаты, анализ занятого места
- Поиск и замена текста или hex во всей папке — даже внутри ZIP/APK/IPA без распаковки
- Передача файлов по Wi‑Fi через браузер на компьютере
- GX Files в «Поделиться» для любых файлов; apk, dylib, so, dex, btx открываются в нём из «Файлов»

**Форматы**
- ZIP, APK, IPA, JAR — правка прямо в архиве; чтение tar, 7z, rar и других
- Текстовый редактор с подсветкой, hex-редактор, plist/JSON/.strings, SQLite с SQL-консолью
- APK: разбор манифеста, подпись v1 + v2
- IPA: название, bundle ID, иконка, Info.plist, ограничения устройств, расширения
- Текстуры .btx / .dds / SHTX, Assets.car, профили подписи

**Редактор бинарников (Mach-O / ELF)**
- Строки — поиск и правка на месте, ссылки из кода
- Классы Objective-C → заголовки .h
- Дизассемблер ARM64, приблизительный псевдокод на C, встроенный ассемблер
- Числа и константы, встроенные картинки и шрифты, цвета интерфейса
- Переподпись ad-hoc после правки

**Компилятор C → dylib** — встроенный [TinyCC](https://github.com/TinyCC/tinycc) с заголовками iOS SDK и помощником `gxkit.h`.

**Языки:** русский, English, українська, беларуская, Deutsch, Français, Español, Português (Brasil).

## Сборка

**macOS (Xcode):**
```sh
python3 -m pip install pillow
bash build.sh
```

**Linux:** нужны `clang`, `lld`, `zip`, Python 3 с Pillow и iPhoneOS SDK.
```sh
SDK=/путь/к/iPhoneOS.sdk bash build.sh
```

Результат — `GXFiles.ipa`. Заголовки Apple для встроенного компилятора генерируются из твоего SDK при первой сборке (`tools/sdk/make_sdk.py`) — в репозитории их нет. На macOS дополнительно собирается каталог иконок со светлой, тёмной и тонированной версией (iOS 18+).

## Структура

```
src/            интерфейс (Objective-C)
src/core/       ядро на C: Mach-O/ELF, ARM64, zip, подпись APK, картинки
tcc/            TinyCC и ресурсы встроенного компилятора
i18n/           переводы интерфейса
assets/icon/    иконки (светлая, тёмная, монохромная)
source/         источник для Feather / SideStore / AltStore
tools/          сбор строк, генерация SDK
```

## Перевод на свой язык

1. Скопируй `i18n/en.tsv` в `i18n/<код>.tsv`.
2. Переведи текст после `|`, сохранив `%@`, `%d`, `%s`, `\n` и пробелы по краям.
3. Проверь: `python3 tools/i18n/build.py --stats`.
4. Добавь язык в `GXLanguages()` в `src/GXLang.m` и пришли pull request.

## Ответственное использование

Редактор бинарников и компилятор нужны для изучения, отладки и правки **своих** приложений и приложений, на изменение которых у тебя есть право. Не используй GX Files для нарушения лицензий, обхода защиты или нечестной игры в чужих сервисах и онлайн-играх.

## Лицензия

[GNU GPL v3](LICENSE). Встроенный TinyCC — LGPL 2.1, см. [THIRD_PARTY.md](THIRD_PARTY.md).

---

<a id="english"></a>

# GX Files (English)

A file manager for iPhone: archives, APK/IPA, plist, SQLite, hex, a Mach-O/ELF editor with an ARM64 disassembler, and an on-device C → dylib compiler.

## Install

- **Feather / SideStore / AltStore source:** `https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json`
- **Manually:** download `GXFiles.ipa` from [Releases](../../releases) and install it with Feather, SideStore, AltStore, TrollStore, or inside LiveContainer.

A regular install gets “My files” (Files → On My iPhone → GX Files), linked folders and files shared into the app. LiveContainer adds its shared folder and guest app data. TrollStore or a jailbreak gives full filesystem access.

## Features

- **Files:** dual panels, favorites, recents, thumbnails, symlinks, batch rename, search by name and content, duplicates, storage analysis, find & replace across a folder (even inside ZIP/APK/IPA), Wi‑Fi transfer, “Open in GX Files” from the share sheet.
- **Formats:** edit ZIP/APK/IPA/JAR in place; read tar, 7z, rar; text and hex editors, plist/JSON/.strings, SQLite console; APK manifest decoding and v1 + v2 signing; IPA metadata editing; .btx/.dds/SHTX textures, Assets.car.
- **Binary editor:** strings, Objective-C headers, ARM64 disassembler, approximate C pseudocode, assembler, numbers, embedded images/fonts, UI colors, ad-hoc re-signing.
- **On-device compiler:** [TinyCC](https://github.com/TinyCC/tinycc) with iOS SDK headers and `gxkit.h`.
- **Languages:** Russian, English, Ukrainian, Belarusian, German, French, Spanish, Portuguese (Brazil).

## Build

- **macOS:** `python3 -m pip install pillow && bash build.sh`
- **Linux:** needs `clang`, `lld`, `zip`, Python 3 with Pillow and an iPhoneOS SDK: `SDK=/path/to/iPhoneOS.sdk bash build.sh`

## Translating

Copy `i18n/en.tsv` to `i18n/<code>.tsv`, translate the text after `|` keeping `%@`, `%d`, `%s`, `\n` and edge spaces, check with `python3 tools/i18n/build.py --stats`, add the language to `GXLanguages()` in `src/GXLang.m` and open a pull request.

## Responsible use

The binary editor and compiler are for studying, debugging and modifying **your own** apps and apps you have the right to modify. Don't use GX Files to violate licenses, bypass protections, or cheat in other people's services and online games.

## License

[GNU GPL v3](LICENSE). Bundled TinyCC is LGPL 2.1 — see [THIRD_PARTY.md](THIRD_PARTY.md).
