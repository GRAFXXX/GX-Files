# Contributing to GX Files

Thanks for helping! Everything below works without a Mac unless noted.

## Report a bug
Open an [issue](../../issues/new/choose) and pick **Bug report**. Please include your iOS version, how GX Files is installed (Feather, SideStore, LiveContainer, TrollStore…) and steps to reproduce. For crashes, attach the crash log: Settings → Privacy & Security → Analytics & Improvements → Analytics Data → file starting with `GXFiles`.

## Add or fix a translation
1. Copy `i18n/en.tsv` to `i18n/<code>.tsv` (for example `it.tsv`, `pl.tsv`, `ja.tsv`).
2. Translate the text after `|`. Keep `%@`, `%d`, `%s`, `\n` and spaces at the start/end of a line exactly as they are.
3. Check: `python3 tools/i18n/build.py --stats` — it shows the percentage and any lines with broken placeholders.
4. Add your language to `GXLanguages()` in `src/GXLang.m`.
5. Open a pull request. Partial translations are fine — missing lines fall back to English.

You can also translate the README: copy `README.md` to `README.<code>.md` and add a link to the language bar at the top of every README.

## Change the code
- UI is Objective-C in `src/`, the core is plain C in `src/core/`.
- New user-visible Russian strings: run `python3 tools/i18n/wrap.py` — it wraps them in `GXL()` and updates `tools/i18n/source.tsv`. Then add translations.
- Build: see the README. GitHub Actions builds every pull request.

## Screenshots
Take screenshots on your iPhone, then:
```sh
python3 tools/screenshots/frame.py shot1.png "Caption" shot2.png "Another caption"
```
Framed images are written to `assets/screenshots/`.

## Ground rules
Be kind. Keep the project a file manager and developer tool — no features aimed at cheating in online games or bypassing app protections.
