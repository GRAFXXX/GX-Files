# Third-party components

| Component | Where | License |
|---|---|---|
| [TinyCC](https://github.com/TinyCC/tinycc) (commit e23dabe) | `tcc/src`, `tcc/res/include` | GNU LGPL 2.1 — see `tcc/src/COPYING`, `tcc/res/LICENSE-TinyCC.txt` |
| [Lua](https://www.lua.org) 5.4.7 | `lua/` (built through `src/core/gx_lua.c`) | MIT — see `lua/LICENSE` (shipped in the app as `LICENSE-Lua.txt`) |
| Apple WWDR intermediate certificates (public) | `src/core/gx_wwdr.c`, `tests/fixtures/wwdr/` | published by Apple at apple.com/certificateauthority |
| libarchive headers (`archive.h`, `archive_entry.h`) | `src/la` | BSD 2-Clause — license text in the file headers |
| libarchive, zlib, sqlite3 | linked dynamically from iOS | system libraries, not included |

GX Files changes to TinyCC are marked with `#ifdef GX_IOS` in `tcc/src/tccmacho.c` (see `tcc/src/UPSTREAM.txt`).

**Apple SDK files are not included.** Headers and `.tbd` stubs for the on-device compiler
are generated at build time from your own iPhoneOS SDK by `tools/sdk/make_sdk.py`.

**Compiler Explorer.** Code in languages other than C, JavaScript, TypeScript and Lua is sent to
[Compiler Explorer](https://godbolt.org) (compiler-explorer.com, BSD 2-Clause) to be compiled and run;
nothing from it is bundled in the app.
