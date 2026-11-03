<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.uk.md">Українська</a> ·
  <a href="README.be.md">Беларуская</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <b>Français</b> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português</a>
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/GRAFXXX/GX-Files?label=release&color=7c5cff" alt="Release"></a>
  <a href="../../actions"><img src="https://img.shields.io/github/actions/workflow/status/GRAFXXX/GX-Files/build.yml?label=build" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-blue" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0">
</p>

**GX Files** est un gestionnaire de fichiers natif pour iPhone avec un éditeur intégré d'archives, d'APK/IPA et de binaires — et un compilateur C qui produit des dylib directement sur l'appareil. Il fonctionne comme une app normale (Feather, SideStore, AltStore, TrollStore) et dans [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Installation

**Ajoutez la source** dans Feather, SideStore ou AltStore — les mises à jour arrivent toutes seules :

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**Ou téléchargez** `GXFiles.ipa` depuis [Releases](../../releases/latest) et installez-le comme vous voulez.

| Installé via | Accès |
|---|---|
| Feather / SideStore / AltStore | « Mes fichiers » (aussi dans Fichiers → Sur mon iPhone → GX Files), dossiers liés, fichiers partagés vers l'app |
| LiveContainer | tout ce qui précède + dossier partagé de LiveContainer, données des apps invitées, tweaks |
| TrollStore / jailbreak | tout le système de fichiers |

## Fonctionnalités

**Fichiers**
- Deux panneaux, favoris, récents, fichiers cachés, miniatures
- Copie, déplacement, liens symboliques, renommage par lot avec modèles
- Recherche par nom et contenu, doublons, analyse de l'espace
- Rechercher et remplacer du texte ou de l'hex dans tout un dossier — même dans des ZIP/APK/IPA sans les décompresser
- Transfert Wi‑Fi via le navigateur de l'ordinateur
- « Ouvrir dans GX Files » depuis le menu Partager ; apk, dylib, so, dex et btx s'ouvrent dans GX Files depuis l'app Fichiers

**Formats**
- ZIP, APK, IPA, JAR modifiables directement dans l'archive ; lecture de tar, 7z, rar et autres
- Éditeur de texte avec coloration, éditeur hex, plist / JSON / .strings, SQLite avec console SQL
- APK : décodage du manifeste binaire, signature v1 + v2
- IPA : nom, bundle ID, icône, Info.plist, restrictions d'appareil, extensions
- Textures de jeux (.btx / .dds / SHTX), Assets.car, profils de provisionnement

**Éditeur de binaires (Mach-O / ELF)**
- Chaînes : recherche et modification sur place, références depuis le code
- Classes Objective-C → en-têtes .h
- Désassembleur ARM64, pseudocode C approximatif, assembleur intégré
- Nombres et constantes, images et polices intégrées, couleurs d'interface
- Re-signature ad hoc après modification

**Compilateur sur l'appareil** — [TinyCC](https://github.com/TinyCC/tinycc) avec les en-têtes du SDK iOS et l'aide `gxkit.h` : écrivez du C, obtenez une dylib arm64.

**8 langues** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Captures d'écran

Bientôt.

## Compiler soi-même

**macOS (Xcode) :** `python3 -m pip install pillow && bash build.sh`

**Linux :** il faut `clang`, `lld`, `zip`, Python 3 avec Pillow et un SDK iPhoneOS : `SDK=/chemin/vers/iPhoneOS.sdk bash build.sh`

Le résultat est `GXFiles.ipa`. Les en-têtes du compilateur sont générés depuis votre SDK au premier build ; aucun fichier Apple n'est dans le dépôt. GitHub Actions compile chaque push ; un tag `v*` publie une release et met à jour la source pour Feather / SideStore.

## Contribuer

Rapports de bugs, idées et traductions bienvenus — voir [CONTRIBUTING.md](CONTRIBUTING.md).

## Usage responsable

L'éditeur de binaires et le compilateur servent à étudier, déboguer et modifier **vos propres** apps et celles que vous avez le droit de modifier. N'utilisez pas GX Files pour violer des licences, contourner des protections ou tricher dans les services et jeux en ligne d'autrui.

## Licence

[GNU GPL v3](LICENSE). TinyCC intégré : LGPL 2.1 — voir [THIRD_PARTY.md](THIRD_PARTY.md).
