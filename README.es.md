<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.uk.md">Українська</a> ·
  <a href="README.be.md">Беларуская</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <b>Español</b> ·
  <a href="README.pt-BR.md">Português</a>
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/GRAFXXX/GX-Files?label=release&color=7c5cff" alt="Release"></a>
  <a href="../../actions"><img src="https://img.shields.io/github/actions/workflow/status/GRAFXXX/GX-Files/build.yml?label=build" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-blue" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0">
</p>

**GX Files** es un gestor de archivos nativo para iPhone con editor integrado de archivos comprimidos, APK/IPA y binarios — y un compilador de C que genera dylib directamente en el dispositivo. Funciona como app normal (Feather, SideStore, AltStore, TrollStore) y dentro de [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Instalación

**Añade la fuente** en Feather, SideStore o AltStore — las actualizaciones llegan solas:

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**O descarga** `GXFiles.ipa` desde [Releases](../../releases/latest) e instálalo como prefieras.

| Instalado con | Acceso |
|---|---|
| Feather / SideStore / AltStore | «Mis archivos» (también en Archivos → En mi iPhone → GX Files), carpetas vinculadas, archivos compartidos con la app |
| LiveContainer | todo lo anterior + carpeta compartida de LiveContainer, datos de apps invitadas, tweaks |
| TrollStore / jailbreak | todo el sistema de archivos |

## Funciones

**Archivos**
- Dos paneles, favoritos, recientes, archivos ocultos, miniaturas
- Copiar, mover, enlaces simbólicos, renombrado en lote con plantillas
- Búsqueda por nombre y contenido, duplicados, análisis de espacio
- Buscar y reemplazar texto o hex en toda una carpeta — incluso dentro de ZIP/APK/IPA sin descomprimir
- Transferencia por Wi‑Fi desde el navegador del ordenador
- «Abrir en GX Files» desde Compartir; apk, dylib, so, dex y btx se abren en GX Files desde la app Archivos
- Unidades de red por WebDAV — ordenador, NAS, Nextcloud; cliente de GitHub: ver, descargar, editar y hacer commit desde el móvil
- Asistente de IA: conecta cualquier IA — OpenAI, Claude, Gemini, DeepSeek, OpenRouter u Ollama / LM Studio en local — y deja que edite archivos en la carpeta que elijas (incluso todo LiveContainer), con confirmación, copias de seguridad y deshacer

**Formatos**
- ZIP, APK, IPA, JAR: edición directa dentro del archivo; lectura de tar, 7z, rar y más
- Editor de texto con resaltado, editor hex, plist / JSON / .strings, SQLite con consola SQL
- APK: decodificación del manifiesto binario, firma v1 + v2
- IPA: nombre, bundle ID, icono, Info.plist, restricciones de dispositivo, extensiones
- Texturas de juegos (.btx / .dds / SHTX), Assets.car, perfiles de aprovisionamiento

**Editor de binarios (Mach-O / ELF)**
- Cadenas: búsqueda y edición en su sitio, referencias desde el código
- Clases Objective-C → cabeceras .h
- Desensamblador ARM64, pseudocódigo C aproximado, ensamblador integrado
- Emulador ARM64: ejecuta una función paso a paso en un entorno aislado y observa los registros
- Pseudocódigo con estructuras if/else/while, no solo goto
- Auditoría de seguridad (SAST): detecta strcpy/sprintf/system, MD5/SHA-1, comprobaciones TLS desactivadas
- Números y constantes, imágenes y fuentes incrustadas, colores de interfaz
- Refirmado ad hoc tras editar

**Compilador en el dispositivo** — [TinyCC](https://github.com/TinyCC/tinycc) con cabeceras del SDK de iOS y el ayudante `gxkit.h`: escribe C y obtén una dylib arm64.

**8 idiomas** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Capturas de pantalla

<p align="center"><img src="assets/features/all.png" alt="GX Files"></p>

Capturas reales — próximamente.

## Compilar

**macOS (Xcode):** `python3 -m pip install pillow && bash build.sh`

**Linux:** necesitas `clang`, `lld`, `zip`, Python 3 con Pillow y un SDK de iPhoneOS: `SDK=/ruta/a/iPhoneOS.sdk bash build.sh`

El resultado es `GXFiles.ipa`. Las cabeceras del compilador se generan desde tu SDK en la primera compilación; no hay archivos de Apple en el repositorio. GitHub Actions compila cada push; una etiqueta `v*` publica una release y actualiza la fuente para Feather / SideStore.

## Contribuir

Informes de errores, ideas y traducciones son bienvenidos — ver [CONTRIBUTING.md](CONTRIBUTING.md).

## Uso responsable

El editor de binarios y el compilador sirven para estudiar, depurar y modificar **tus propias** apps y las que tienes derecho a modificar. No uses GX Files para violar licencias, saltarte protecciones ni hacer trampas en servicios y juegos online de otros.

## Licencia

[GNU GPL v3](LICENSE). TinyCC incluido: LGPL 2.1 — ver [THIRD_PARTY.md](THIRD_PARTY.md).
