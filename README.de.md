<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.uk.md">Українська</a> ·
  <a href="README.be.md">Беларуская</a> ·
  <b>Deutsch</b> ·
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

**GX Files** ist ein nativer Dateimanager für das iPhone mit eingebautem Editor für Archive, APK/IPA und Binärdateien — und einem C-Compiler, der dylibs direkt auf dem Gerät baut. Er läuft als normale App (Feather, SideStore, AltStore, TrollStore) und in [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Installation

**Quelle hinzufügen** in Feather, SideStore oder AltStore — Updates kommen automatisch:

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**Oder** `GXFiles.ipa` unter [Releases](../../releases/latest) herunterladen und beliebig installieren.

| Installiert über | Zugriff auf |
|---|---|
| Feather / SideStore / AltStore | „Meine Dateien“ (auch in Dateien → Auf meinem iPhone → GX Files), verknüpfte Ordner, geteilte Dateien |
| LiveContainer | alles oben + LiveContainer-Ordner, Daten der Gast-Apps, Tweaks |
| TrollStore / Jailbreak | das gesamte Dateisystem |

## Funktionen

**Dateien**
- Zwei Felder, Favoriten, Verlauf, versteckte Dateien, Miniaturen
- Kopieren, Verschieben, symbolische Links, Stapel-Umbenennung mit Mustern
- Suche nach Name und Inhalt, Duplikate, Speicheranalyse
- Text oder Hex im ganzen Ordner suchen und ersetzen — sogar in ZIP/APK/IPA ohne Entpacken
- WLAN-Übertragung über den Browser am Computer
- „In GX Files öffnen“ über das Teilen-Menü; apk, dylib, so, dex und btx öffnen sich aus der Dateien-App in GX Files
- Netzlaufwerke über WebDAV — Computer, NAS, Nextcloud; GitHub-Client: ansehen, herunterladen, bearbeiten und committen vom Handy
- KI-Assistent: Verbinde jede KI — OpenAI, Claude, Gemini, DeepSeek, OpenRouter oder lokal Ollama / LM Studio — und lass sie Dateien in einem Ordner deiner Wahl bearbeiten (sogar ganz LiveContainer), mit Bestätigung, Sicherungen und Rückgängig

**Formate**
- ZIP, APK, IPA, JAR direkt im Archiv bearbeiten; tar, 7z, rar u. a. lesen
- Texteditor mit Syntaxhervorhebung, Hex-Editor, plist / JSON / .strings, SQLite mit SQL-Konsole
- APK: Binär-Manifest dekodieren, Signatur v1 + v2
- IPA: Name, Bundle-ID, Symbol, Info.plist, Geräteeinschränkungen, Erweiterungen
- Spieltexturen (.btx / .dds / SHTX), Assets.car, Bereitstellungsprofile

**Binär-Editor (Mach-O / ELF)**
- Strings suchen und direkt bearbeiten, mit Verweisen aus dem Code
- Objective-C-Klassen → .h-Header
- ARM64-Disassembler, ungefährer C-Pseudocode, integrierter Assembler
- ARM64-Emulator: eine Funktion Schritt für Schritt in einer Sandbox ausführen und die Register beobachten
- Pseudocode mit if/else/while-Strukturen, nicht nur goto
- Sicherheitsaudit (SAST): meldet strcpy/sprintf/system, MD5/SHA-1, deaktivierte TLS-Prüfungen
- Zahlen und Konstanten, eingebettete Bilder und Schriften, UI-Farben
- Ad-hoc-Neusignierung nach Änderungen

**Compiler auf dem Gerät** — [TinyCC](https://github.com/TinyCC/tinycc) mit iOS-SDK-Headern und dem Helfer `gxkit.h`: C schreiben, arm64-dylib erhalten.

**8 Sprachen** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Screenshots

<p align="center"><img src="assets/features/all.png" alt="GX Files"></p>

Echte Screenshots folgen bald.

## Selbst bauen

**macOS (Xcode):** `python3 -m pip install pillow && bash build.sh`

**Linux:** benötigt `clang`, `lld`, `zip`, Python 3 mit Pillow und ein iPhoneOS-SDK: `SDK=/pfad/zum/iPhoneOS.sdk bash build.sh`

Ergebnis ist `GXFiles.ipa`. Die Header für den Compiler werden beim ersten Build aus deinem SDK erzeugt; Apple-Dateien liegen nicht im Repository. GitHub Actions baut jeden Push; ein `v*`-Tag veröffentlicht ein Release und aktualisiert die Quelle für Feather / SideStore.

## Mitmachen

Fehlerberichte, Ideen und Übersetzungen sind willkommen — siehe [CONTRIBUTING.md](CONTRIBUTING.md).

## Verantwortungsvolle Nutzung

Binär-Editor und Compiler sind zum Lernen, Debuggen und Ändern **eigener** Apps gedacht und solcher, die du ändern darfst. Nutze GX Files nicht, um Lizenzen zu verletzen, Schutzmaßnahmen zu umgehen oder in fremden Diensten und Online-Spielen zu betrügen.

## Lizenz

[GNU GPL v3](LICENSE). Das enthaltene TinyCC steht unter LGPL 2.1 — siehe [THIRD_PARTY.md](THIRD_PARTY.md).
