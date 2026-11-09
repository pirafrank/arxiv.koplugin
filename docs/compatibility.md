# Compatibility

KOReader plugin APIs are internal Lua interfaces, not a stable public API. This plugin
was written against, and tested with, the release below.

| KOReader release | commit | API checked | local test result | Kindle result |
| --- | --- | --- | --- | --- |
| v2026.07.1 (Linux x86_64 release tarball, sha256 `299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`) | `9192014d8bd82a91dc1012473be0f238dedfdb54` | yes (list below) | PASS: unit 60/60; headless integration 14/14 incl. real arxiv.org download (2026-11-09) | NOT TESTED (no device accessible) |
| master (reference only) | `739291bfbb52b23e430cf1ff92b3a0e2e16d3e6a` (2026-11-09) | diffed (see below) | not run (no matching runtime build) | NOT TESTED |

Coexistence was tested with the built-in OPDS plugin of that release.

## Storefront readiness audit (2026-11-09)

Results reproduced after the recovery and packaging changes:

- `scripts/check.sh`: 62 unit tests passed; LuaJIT syntax, luacheck and shellcheck passed.
- `KOREADER_DIR=/tmp/kor/lib/koreader scripts/check.sh --integration`: 12 passed
  with built-in OPDS, including a real arXiv download opened in ReaderUI and rejection
  of wrong-host and expired certificates.
- Release ZIP: six files under `arxiv.koplugin/`, including repository README and
  LICENSE; packaging checks compare every archived file with its source.
- Storefront installer at commit `298941bd1e3a387bb0abe4c35d1eca0aa3f6f563`:
  executed its archive-detection functions with the actual release ZIP entries and
  a source ZIP wrapped in `arxiv.koplugin-main/`. Both yielded directory
  `arxiv.koplugin` and the correct extraction prefix.
- Adding `name` to `_meta.lua` produced a KOReader deprecation warning; it remains
  omitted. The main module and folder already identify the plugin as `arxiv`.

Publication, catalog discovery, Storefront README rendering/full installation on
Kindle, and Kindle operation with and without Zenos remain **NOT TESTED**.
The checkout has no configured Git remote; no public release was created by this audit.
The earlier baseline table records the original implementation's results, not the
post-change unit-test count.

## APIs used and where they were verified (v2026.07.1)

| API | Source | Notes |
| --- | --- | --- |
| `WidgetContainer:extend{ name = … }`, `self.ui.menu:registerToMainMenu(self)`, `addToMainMenu(menu_items)` | `plugins/opds.koplugin/main.lua`, `frontend/apps/filemanager/filemanagermenu.lua` | Same pattern as OPDS. `self.ui.document == nil` means File Manager. |
| `sorting_hint = "search"` | `frontend/ui/menusorter.lua`, `frontend/ui/elements/filemanager_menu_order.lua` | Places the entry in the search menu next to OPDS, without a `NEW:` prefix. |
| `self.ui.folder_shortcuts:expandPath("%D%")` | `frontend/apps/filemanager/filemanagershortcuts.lua` | Returns the shared download folder (`download_dir` setting, else `lastdir`). Fallback: `G_reader_settings` `download_dir`, then `lastdir`, exactly as OPDS's `getCurrentDownloadDir()` in this release. |
| `InputDialog` (`title`, `input_hint`, `description`, `buttons`, `getInputText`, `onShowKeyboard`) | `frontend/ui/widget/inputdialog.lua` | |
| `MultiConfirmBox` (`choice1_*`, `choice2_*`, Cancel) | `frontend/ui/widget/multiconfirmbox.lua` | Read existing / Overwrite / Cancel. |
| `ConfirmBox`, `InfoMessage`, `UIManager:show/close/scheduleIn/nextTick` | `frontend/ui/widget/*.lua`, `frontend/ui/uimanager.lua` | Same "Downloading…" → `scheduleIn(1)` → `nextTick` result pattern as OPDS. |
| `NetworkMgr:runWhenConnected(cb)` | `frontend/ui/network/manager.lua` | Runs `cb` now if connected, else defers to KOReader's Wi-Fi prompt/turn-on logic. |
| `self.ui:openFile(path)`, `self.ui.file_chooser:changeToPath(dir, path)` | `frontend/apps/filemanager/filemanager.lua`, `frontend/ui/widget/filechooser.lua` | |
| `socket.http.request{…, redirect = false, create = …}` | bundled LuaSocket `common/socket/http.lua` | `create` receives the request table; LuaSec's `https.tcp(params)` reads `verify`/`cafile` from it. |
| `ssl.https.tcp`, `conn.sock:getpeercertificate():extensions()` | bundled LuaSec 1.3.2 `common/ssl/https.lua` | LuaSec defaults to `verify = "none"` and does not check host names; the plugin enables both. |
| `socketutil:set_timeout(FILE_BLOCK_TIMEOUT, FILE_TOTAL_TIMEOUT)`, `reset_timeout()`, `USER_AGENT` | `frontend/socketutil.lua` | |
| `data/ca-bundle.crt` | shipped in the release package | Relative to the KOReader install dir (KOReader's working directory). |
| Plugin loading (`_meta.lua`, `main.lua` via `dofile`, `plugins_disabled` keyed by `name`) | `frontend/pluginloader.lua` | Siblings are loaded by path with `dofile`, not `require`, to avoid `package.loaded` collisions with other plugins. |

## Differences between v2026.07.1 and master (checked 2026-11-09)

- `plugins/opds.koplugin/opdsclient.lua` exists only on master; v2026.07.1 OPDS does HTTP inside
  `opdsbrowser.lua`. This plugin uses neither.
- On master, OPDS resolves its default folder via `folder_shortcuts:expandPath("%D%")` and the
  `download_dir` provider falls back to the home folder instead of `lastdir`. The plugin calls
  `expandPath("%D%")` first, so it follows either behaviour.
- `MenuSorter` on master logs a warning for an unknown `sorting_hint`; `"search"` exists in both.
- `FileManagerMenu`, `InputDialog` and `socketutil` changed internally on master, but the calls
  used here are unchanged (`registerToMainMenu`, `getInputText`, `set_timeout`/`reset_timeout`).
  Not run-tested on master.

## arXiv behaviour observed (2026-11-09)

- `https://arxiv.org/pdf/<id>` and `…/pdf/<id>vN` answer `200 application/pdf` directly (no CDN redirect).
- `…/pdf/<id>.pdf` answers `301` with a relative `Location: /pdf/<id>`.
- Unknown ids/versions answer `404 text/html`.
- `export.arxiv.org/pdf/<id>` also serves PDFs. The certificate covers `arxiv.org` and `*.arxiv.org`.
