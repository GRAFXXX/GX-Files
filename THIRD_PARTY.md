# Third-party components

| Component | Where | License |
|---|---|---|
| [TinyCC](https://github.com/TinyCC/tinycc) (commit e23dabe) | `tcc/src`, `tcc/res/include` | GNU LGPL 2.1 — see `tcc/src/COPYING`, `tcc/res/LICENSE-TinyCC.txt` |
| libarchive headers (`archive.h`, `archive_entry.h`) | `src/la` | BSD 2-Clause — license text in the file headers |
| libarchive, zlib, sqlite3 | linked dynamically from iOS | system libraries, not included |

GX Files changes to TinyCC are marked with `#ifdef GX_IOS` in `tcc/src/tccmacho.c` (see `tcc/src/UPSTREAM.txt`).

**Apple SDK files are not included.** Headers and `.tbd` stubs for the on-device compiler
are generated at build time from your own iPhoneOS SDK by `tools/sdk/make_sdk.py`.
