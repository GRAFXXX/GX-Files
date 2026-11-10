# Changelog

## 4.6.1
- Certificate import: a clear message when iOS cannot read the .p12 format (errSecDecode, typical for OpenSSL 3 / AES-256 files) instead of a bare error code

## 4.6
- Certificate signing: import your own developer `.p12` (and optionally a `.mobileprovision`) and the on-device compiler signs the dylibs it builds with it instead of ad-hoc — so they load without JIT on a device whose app shares the certificate's Team ID
- New "Certificate signing" screen in the compiler menu: toggle, import/replace the `.p12` with its password, add a provisioning profile, and delete everything (certificate files and password are kept in the iOS Keychain, never in plain files)
- Signing is built as pure C (`gx_csign`): CodeDirectory (SHA-256) + Requirements + a full CMS/PKCS#7 signature, with the RSA step done through the Security framework so the private key never leaves the Keychain
- CI now signs a compiled dylib with a test certificate on every build and verifies the CMS with OpenSSL; AI-engine and compiler regression tests also run in CI

## 4.5.2
- Compiled dylibs now export __mh_dylib_header instead of __mh_execute_header, so binary analysers correctly see them as a dylib (the Mach-O filetype was already MH_DYLIB — only the symbol name was misleading)
- CI compiler test now also checks the filetype is MH_DYLIB and that no _mh_execute_header symbol is emitted

## 4.5.1
- Fixed: dylibs built by the on-device compiler now include an LC_UUID load command, so they load on current iOS — previously dlopen failed with “missing LC_UUID load command”
- CI now checks on every build that the compiler emits a valid LC_UUID and that signing keeps it

## 4.5
- On-device C compiler: link against 95 system libraries and frameworks instead of 8 — Security, AVFoundation, CoreMedia, CoreImage, Metal, Vision, Core ML, MapKit, CoreLocation, StoreKit, and dozens more (via the Objective-C runtime); plus libc++, libcompression, libxml2, libarchive and other system libs
- New grouped framework picker with search, "Core only" and "Clear all"
- gxkit.h: new helpers — NSNumber (gx_num_*/gx_int/gx_double/gx_bool), gx_alloc, and gx_prop/gx_setprop (properties by name via KVC)
- Help now explains that the compiler is C (not Objective-C) and that gxkit.h bridges C to any iOS class

## 4.4
- Keyboard: tapping anywhere outside a text field or scrolling now hides the keyboard everywhere in the app (buttons and list rows keep working as usual); in the AI chat the keyboard also hides after sending
- AI assistant chat history: chats are saved automatically and can be reopened and continued later; recent chats on the assistant screen, full history with search, rename and delete
- “Undo chat changes” also works in a reopened chat; deleting a chat removes its backups; folder paths are re-linked if iOS moves the app container after an update
- More automated tests for the AI engine (saving, loading, undo after reopening)

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
