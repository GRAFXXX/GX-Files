<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.uk.md">Українська</a> ·
  <b>Беларуская</b> ·
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

**GX Files** — натыўны файлавы менеджар для iPhone з убудаваным рэдактарам архіваў, APK/IPA і бінарнікаў, а таксама кампілятарам C, які збірае dylib проста на тэлефоне. Працуе як звычайная праграма (Feather, SideStore, AltStore, TrollStore) і ўнутры [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Усталёўка

**Дадай крыніцу** ў Feather, SideStore або AltStore — абнаўленні будуць прыходзіць самі:

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**Або спампуй** `GXFiles.ipa` з [Releases](../../releases/latest) і ўсталюй любым спосабам.

| Як усталявана | Што даступна |
|---|---|
| Feather / SideStore / AltStore | «Мае файлы» (таксама ў «Файлах» → «На iPhone» → GX Files), падключаныя папкі, файлы праз «Падзяліцца» |
| LiveContainer | усё вышэй + агульная папка LiveContainer, даныя гасцявых праграм, твікі |
| TrollStore / джэйлбрэйк | уся файлавая сістэма |

## Магчымасці

**Файлы**
- Дзве панэлі, абранае, нядаўнія, схаваныя файлы, мініяцюры
- Капіяванне, перамяшчэнне, сімвалічныя спасылкі, пакетнае перайменаванне па шаблоне
- Пошук па імені і змесціве, пошук дублікатаў, аналіз месца
- Пошук і замена тэксту ці hex ва ўсёй папцы — нават унутры ZIP/APK/IPA без распакавання
- Перадача файлаў праз Wi‑Fi у браўзеры на камп'ютары
- «Адкрыць у GX Files» праз «Падзяліцца»; apk, dylib, so, dex і btx адкрываюцца ў GX Files з «Файлаў»
- Сеткавыя дыскі праз WebDAV — камп'ютар, NAS, Nextcloud; кліент GitHub: глядзець, спампоўваць, правіць і камітаваць з тэлефона
- ШІ-памочнік: падключы любы ШІ — OpenAI, Claude, Gemini, DeepSeek, OpenRouter або лакальны Ollama / LM Studio — і ён змяняе файлы ў выбранай папцы (хоць ва ўсім LiveContainer), з пацвярджэннем, рэзервовымі копіямі і адменай — чаты захоўваюцца, іх можна працягнуць пазней

**Фарматы**
- ZIP, APK, IPA, JAR — праўка проста ў архіве; чытанне tar, 7z, rar і іншых
- Тэкставы рэдактар з падсветкай, hex-рэдактар, plist / JSON / .strings, SQLite з SQL-кансоллю
- APK: разбор бінарнага маніфеста, подпіс v1 + v2
- IPA: назва, bundle ID, іконка, Info.plist, абмежаванні прылад, пашырэнні
- Гульнявыя тэкстуры (.btx / .dds / SHTX), Assets.car, профілі подпісу

**Рэдактар бінарнікаў (Mach-O / ELF)**
- Радкі — пошук і праўка на месцы, спасылкі з кода
- Класы Objective-C → загалоўкі .h
- Дызасэмблер ARM64, прыблізны псеўдакод на C, убудаваны асэмблер
- Кампілятар C→arm64 проста на тэлефоне (TinyCC): 95 фреймворкаў і бібліятэк iOS для лінкавання, ad-hoc подпіс і ўкараненне dylib
- Эмулятар ARM64: пакрокавае выкананне функцыі ў пясочніцы з праглядам рэгістраў
- Псеўдакод са структурамі if/else/while, а не толькі goto
- Аўдыт бяспекі (SAST): знаходзіць strcpy/sprintf/system, MD5/SHA-1, адключаныя праверкі TLS
- Лікі і канстанты, убудаваныя выявы і шрыфты, колеры інтэрфейсу
- Перападпіс ad-hoc пасля праўкі

**Кампілятар на тэлефоне** — [TinyCC](https://github.com/TinyCC/tinycc) з загалоўкамі iOS SDK і памочнікам `gxkit.h`: пішаш на C — атрымліваеш arm64 dylib.

**8 моў** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Скрыншоты

<p align="center"><img src="assets/features/all.png" alt="GX Files"></p>

Сапраўдныя скрыншоты — хутка.

## Зборка

**macOS (Xcode):** `python3 -m pip install pillow && bash build.sh`

**Linux:** патрэбныя `clang`, `lld`, `zip`, Python 3 з Pillow і iPhoneOS SDK: `SDK=/шлях/да/iPhoneOS.sdk bash build.sh`

Вынік — `GXFiles.ipa`. Загалоўкі для ўбудаванага кампілятара генеруюцца з твайго SDK пры першай зборцы, файлаў Apple у рэпазіторыі няма. Кожную змену збірае GitHub Actions; тэг `v*` публікуе рэліз і абнаўляе крыніцу для Feather / SideStore.

## Удзел

Паведамленні пра памылкі, ідэі і пераклады вітаюцца — гл. [CONTRIBUTING.md](CONTRIBUTING.md).

## Адказнае выкарыстанне

Рэдактар бінарнікаў і кампілятар прызначаны для вывучэння, адладкі і праўкі **сваіх** праграм і тых, якія ты маеш права змяняць. Не выкарыстоўвай GX Files для парушэння ліцэнзій, абыходу абароны ці несумленнай гульні ў чужых сэрвісах і анлайн-гульнях.

## Ліцэнзія

[GNU GPL v3](LICENSE). Убудаваны TinyCC — LGPL 2.1, гл. [THIRD_PARTY.md](THIRD_PARTY.md).
