# Changelog

## 4.3
- AI assistant: connect any AI by API — OpenAI-compatible (OpenAI, Gemini, OpenRouter, DeepSeek, Groq, Mistral, xAI), Anthropic, or a local model (Ollama, LM Studio) on a computer in your network
- The assistant works with files only inside the folder you pick — any folder GX Files can reach, including the whole LiveContainer: lists, reads, searches, creates, edits, moves, copies and deletes files; binary .plist files are edited as XML and saved back as binary
- Safety: asks before every change (can be turned off), keeps a backup of everything it changes or deletes, and one tap undoes all changes of the chat
- Model list loading, connection test, API keys stored in the Keychain
- Automated tests of the assistant engine run in CI before every build
- Translations in 8 languages

## 4.2
- Decompiler: pseudocode is now structured into if/else and while loops (dominator-based), with goto kept only for irregular control flow — much closer to readable C
- Security audit (SAST) in the binary editor: finds unsafe string functions (strcpy, sprintf, gets, scanf), command execution (system/popen/exec*), weak hashes (MD5/SHA-1) and ciphers (DES/RC4), insecure RNG, and disabled transport security (ATS off, certificate checks disabled); tap a finding to jump to the function
- Translations for the new screens in 8 languages

## 4.1
- Network drives over WebDAV: computer, NAS, Nextcloud/ownCloud and other servers — browse, download, upload, create folders, rename, delete
- GitHub client: your own and public repositories, branches, download files or the whole repo as ZIP, edit in GX Files and commit back, upload and delete files
- ARM64 emulator in the binary editor: run a function step by step in a sandbox, set arguments, watch registers and memory accesses
- Translations for all new screens in 8 languages

## 4.0
- New app icon (light, dark and tinted variants on iOS 18+)
- Works as a regular app (Feather, SideStore, AltStore, TrollStore), not only in LiveContainer
- “My files” folder visible in the Files app; link folders from Files
- “Open in GX Files” from the share sheet; apk, dylib, so, dex, btx open from the Files app
- Files opened in place are edited as originals
- 8 UI languages with a language switcher
- Binary editor: menu design (theme colors, fonts), embedded images, C code recovery
- Source for Feather / SideStore / AltStore
- Fixed a crash on launch in 3.9
