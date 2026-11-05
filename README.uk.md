<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ru.md">Русский</a> ·
  <b>Українська</b> ·
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

**GX Files** — нативний файловий менеджер для iPhone із вбудованим редактором архівів, APK/IPA та бінарників, а також компілятором C, що збирає dylib прямо на телефоні. Працює як звичайний застосунок (Feather, SideStore, AltStore, TrollStore) і всередині [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Встановлення

**Додай джерело** у Feather, SideStore або AltStore — оновлення надходитимуть самі:

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**Або завантаж** `GXFiles.ipa` з [Releases](../../releases/latest) і встанови будь-яким способом.

| Як встановлено | Що доступно |
|---|---|
| Feather / SideStore / AltStore | «Мої файли» (також у «Файлах» → «На iPhone» → GX Files), підключені теки, файли через «Поділитися» |
| LiveContainer | усе вище + спільна тека LiveContainer, дані гостьових застосунків, твіки |
| TrollStore / джейлбрейк | уся файлова система |

## Можливості

**Файли**
- Дві панелі, обране, нещодавні, приховані файли, мініатюри
- Копіювання, переміщення, символьні посилання, пакетне перейменування за шаблоном
- Пошук за назвою та вмістом, пошук дублікатів, аналіз місця
- Пошук і заміна тексту чи hex у всій теці — навіть усередині ZIP/APK/IPA без розпакування
- Передавання файлів через Wi‑Fi у браузері на комп'ютері
- «Відкрити в GX Files» через «Поділитися»; apk, dylib, so, dex і btx відкриваються в GX Files з «Файлів»
- Мережеві диски через WebDAV — комп'ютер, NAS, Nextcloud; клієнт GitHub: переглядати, завантажувати, правити й комітити з телефона
- ШІ-помічник: підключи будь-який ШІ — OpenAI, Claude, Gemini, DeepSeek, OpenRouter або локальний Ollama / LM Studio — і він змінює файли у вибраній папці (хоч у всьому LiveContainer), з підтвердженням, резервними копіями та скасуванням — чати зберігаються, їх можна продовжити пізніше

**Формати**
- ZIP, APK, IPA, JAR — редагування прямо в архіві; читання tar, 7z, rar та інших
- Текстовий редактор із підсвічуванням, hex-редактор, plist / JSON / .strings, SQLite з SQL-консоллю
- APK: розбір бінарного маніфесту, підпис v1 + v2
- IPA: назва, bundle ID, іконка, Info.plist, обмеження пристроїв, розширення
- Ігрові текстури (.btx / .dds / SHTX), Assets.car, профілі підпису

**Редактор бінарників (Mach-O / ELF)**
- Рядки — пошук і редагування на місці, посилання з коду
- Класи Objective-C → заголовки .h
- Дизасемблер ARM64, приблизний псевдокод на C, вбудований асемблер
- Емулятор ARM64: покрокове виконання функції в пісочниці з переглядом регістрів
- Псевдокод зі структурами if/else/while, а не лише goto
- Аудит безпеки (SAST): знаходить strcpy/sprintf/system, MD5/SHA-1, вимкнені перевірки TLS
- Числа й константи, вбудовані зображення та шрифти, кольори інтерфейсу
- Перепідпис ad-hoc після редагування

**Компілятор на телефоні** — [TinyCC](https://github.com/TinyCC/tinycc) із заголовками iOS SDK і помічником `gxkit.h`: пишеш на C — отримуєш arm64 dylib.

**8 мов** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Скриншоти

<p align="center"><img src="assets/features/all.png" alt="GX Files"></p>

Справжні скриншоти — незабаром.

## Збирання

**macOS (Xcode):** `python3 -m pip install pillow && bash build.sh`

**Linux:** потрібні `clang`, `lld`, `zip`, Python 3 з Pillow та iPhoneOS SDK: `SDK=/шлях/до/iPhoneOS.sdk bash build.sh`

Результат — `GXFiles.ipa`. Заголовки для вбудованого компілятора генеруються з твого SDK під час першого збирання, файлів Apple у репозиторії немає. Кожну зміну збирає GitHub Actions; тег `v*` публікує реліз і оновлює джерело для Feather / SideStore.

## Участь

Повідомлення про помилки, ідеї та переклади вітаються — див. [CONTRIBUTING.md](CONTRIBUTING.md).

## Відповідальне використання

Редактор бінарників і компілятор призначені для вивчення, налагодження та редагування **своїх** застосунків і тих, які ти маєш право змінювати. Не використовуй GX Files для порушення ліцензій, обходу захисту чи нечесної гри в чужих сервісах та онлайн-іграх.

## Ліцензія

[GNU GPL v3](LICENSE). Вбудований TinyCC — LGPL 2.1, див. [THIRD_PARTY.md](THIRD_PARTY.md).
