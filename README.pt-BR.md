<p align="center"><img src="assets/banner.png" alt="GX Files"></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.ru.md">Русский</a> ·
  <a href="README.uk.md">Українська</a> ·
  <a href="README.be.md">Беларуская</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.es.md">Español</a> ·
  <b>Português</b>
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/GRAFXXX/GX-Files?label=release&color=7c5cff" alt="Release"></a>
  <a href="../../actions"><img src="https://img.shields.io/github/actions/workflow/status/GRAFXXX/GX-Files/build.yml?label=build" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-15%2B-blue" alt="iOS 15+">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0">
</p>

**GX Files** é um gerenciador de arquivos nativo para iPhone com editor integrado de arquivos compactados, APK/IPA e binários — e um compilador C que gera dylib direto no aparelho. Funciona como app normal (Feather, SideStore, AltStore, TrollStore) e dentro do [LiveContainer](https://github.com/khanhduytran0/LiveContainer).

## Instalação

**Adicione a fonte** no Feather, SideStore ou AltStore — as atualizações chegam sozinhas:

```
https://raw.githubusercontent.com/GRAFXXX/GX-Files/main/source/apps.json
```

**Ou baixe** `GXFiles.ipa` em [Releases](../../releases/latest) e instale como preferir.

| Instalado via | Acesso |
|---|---|
| Feather / SideStore / AltStore | “Meus arquivos” (também em Arquivos → No meu iPhone → GX Files), pastas vinculadas, arquivos compartilhados com o app |
| LiveContainer | tudo acima + pasta compartilhada do LiveContainer, dados dos apps convidados, tweaks |
| TrollStore / jailbreak | todo o sistema de arquivos |

## Recursos

**Arquivos**
- Dois painéis, favoritos, recentes, arquivos ocultos, miniaturas
- Copiar, mover, links simbólicos, renomear em lote com modelos
- Busca por nome e conteúdo, duplicados, análise de espaço
- Localizar e substituir texto ou hex em uma pasta inteira — até dentro de ZIP/APK/IPA sem descompactar
- Transferência por Wi‑Fi pelo navegador do computador
- “Abrir no GX Files” pelo Compartilhar; apk, dylib, so, dex e btx abrem no GX Files a partir do app Arquivos
- Unidades de rede via WebDAV — computador, NAS, Nextcloud; cliente do GitHub: ver, baixar, editar e fazer commit pelo celular
- Assistente de IA: conecte qualquer IA — OpenAI, Claude, Gemini, DeepSeek, OpenRouter ou Ollama / LM Studio local — e deixe-a editar arquivos na pasta que você escolher (até todo o LiveContainer), com confirmação, backups e desfazer — os chats ficam salvos e podem ser continuados depois

**Formatos**
- ZIP, APK, IPA, JAR: edição direto no arquivo compactado; leitura de tar, 7z, rar e outros
- Editor de texto com realce, editor hex, plist / JSON / .strings, SQLite com console SQL
- APK: decodificação do manifesto binário, assinatura v1 + v2
- IPA: nome, bundle ID, ícone, Info.plist, restrições de dispositivo, extensões
- Texturas de jogos (.btx / .dds / SHTX), Assets.car, perfis de provisionamento

**Editor de binários (Mach-O / ELF)**
- Strings: busca e edição no lugar, referências a partir do código
- Classes Objective-C → cabeçalhos .h
- Desmontador ARM64, pseudocódigo C aproximado, assembler integrado
- Emulador ARM64: execute uma função passo a passo em uma sandbox e acompanhe os registradores
- Pseudocódigo com estruturas if/else/while, não só goto
- Auditoria de segurança (SAST): detecta strcpy/sprintf/system, MD5/SHA-1, verificações de TLS desativadas
- Números e constantes, imagens e fontes embutidas, cores da interface
- Reassinatura ad hoc após editar

**Compilador no aparelho** — [TinyCC](https://github.com/TinyCC/tinycc) com cabeçalhos do SDK do iOS e o auxiliar `gxkit.h`: escreva C, receba uma dylib arm64.

**8 idiomas** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português (Brasil).

## Capturas de tela

<p align="center"><img src="assets/features/all.png" alt="GX Files"></p>

Capturas reais — em breve.

## Compilar

**macOS (Xcode):** `python3 -m pip install pillow && bash build.sh`

**Linux:** precisa de `clang`, `lld`, `zip`, Python 3 com Pillow e um SDK do iPhoneOS: `SDK=/caminho/para/iPhoneOS.sdk bash build.sh`

O resultado é `GXFiles.ipa`. Os cabeçalhos do compilador são gerados a partir do seu SDK na primeira compilação; não há arquivos da Apple no repositório. O GitHub Actions compila cada push; uma tag `v*` publica uma release e atualiza a fonte para Feather / SideStore.

## Contribuir

Relatos de bugs, ideias e traduções são bem-vindos — veja [CONTRIBUTING.md](CONTRIBUTING.md).

## Uso responsável

O editor de binários e o compilador servem para estudar, depurar e modificar **seus próprios** apps e os que você tem direito de modificar. Não use o GX Files para violar licenças, contornar proteções ou trapacear em serviços e jogos online de terceiros.

## Licença

[GNU GPL v3](LICENSE). TinyCC incluído: LGPL 2.1 — veja [THIRD_PARTY.md](THIRD_PARTY.md).
