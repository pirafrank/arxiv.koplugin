# Architecture

Three small Lua files, each with one responsibility:

| File | Role | KOReader dependencies |
| --- | --- | --- |
| `arxiv.koplugin/arxiv.lua` | Parse/normalize input, build the canonical URL and filename. Pure. | none |
| `arxiv.koplugin/download.lua` | Bounded streaming transfer, redirect policy, PDF validation, temp-file/rename finalization. | only inside `real_fs()` / `koreader_request()`, loaded lazily at call time |
| `arxiv.koplugin/main.lua` | Menu entry, dialogs, download folder, network gating, open-after-download. | widgets, `UIManager`, `NetworkMgr`, `lfs`, `logger`, `gettext` |

`main.lua` loads the two helpers with `dofile(<plugin dir>/…)` rather than `require`, because
KOReader's `package.loaded` is shared by all plugins and a generic name like `download` could
resolve to someone else's module.

Nothing performs network or disk I/O at load time or in `init()`.

## Flow

1. File Manager → menu → **Download arXiv PDF** → `InputDialog`.
2. `arxiv.parse()` runs synchronously. On failure an `InfoMessage` is shown above the still-open
   dialog, so the text can be corrected. No network or file activity happens.
3. Download folder: `folder_shortcuts:expandPath("%D%")` (KOReader's shared download folder, the
   same one OPDS uses), falling back to the `download_dir`/`lastdir` settings. It must be an
   existing absolute directory other than `/`.
4. If `<dir>/<id>.pdf` exists: **Read existing / Overwrite / Cancel**.
5. `NetworkMgr:runWhenConnected()` gates the transfer. A `busy` flag (UI) and a per-destination
   guard (download.lua) stop concurrent transfers of the same file.
6. "Downloading…" is shown and the blocking transfer runs one second later (`scheduleIn(1)`, as OPDS
   does), so the e-ink screen can draw the message first. There is no cancel during a transfer in v0.1.
7. On success: File Manager moves to the file, then **Read now / Later**. **Read now** calls
   `ui:openFile()`.

## Security and robustness

- **Input**: printable ASCII only; `%` and `\` rejected outright, so percent-encoded traversal never
  gets through. URLs must use an `http(s)` scheme with host exactly `arxiv.org`, `www.arxiv.org` or
  `export.arxiv.org`, and an `/abs/<id>` or `/pdf/<id>[.pdf]` path. Userinfo, ports and look-alike
  hosts all fail. The user's URL is never fetched; the plugin always downloads
  `https://arxiv.org/pdf/<normalized id>`.
- **TLS**: the certificate chain is verified against KOReader's bundled `data/ca-bundle.crt`, and
  the certificate's DNS names are checked against the host (left-most wildcard only). LuaSec's
  default does neither. If the bundle is missing, the download fails; it never falls back to
  unverified TLS.
- **Redirects**: handled manually (`redirect = false`). At most 5. Each hop must be `https` on
  `arxiv.org` or a subdomain, default port, no userinfo. Loops, missing `Location`, downgrades and
  relative-path `Location` values (other than `/absolute-path` and `//host`) are rejected.
- **Size**: the stream is aborted once it exceeds 100 MiB (`download.MAX_BYTES`). A `Content-Length`
  above the cap, or one that does not match the received bytes, is rejected. LuaSocket only exposes
  headers after the body, so the streamed byte count is the real guard. `Accept-Encoding: identity`
  is sent; compressed or other non-PDF bodies fail the magic check.
- **Validation**: HTTP 200, at least 64 bytes, starts with `%PDF-`, and `%%EOF` within the last
  1 KiB. This catches HTML/JSON error pages and truncation, but it is not a full PDF parse.
- **Files**: bytes go only to `<dir>/.<id>.pdf.arxiv-<random>.part`. The name is checked to be
  absent (including dangling symlinks) right before opening. The handle is closed (flushing, so a
  full disk surfaces) before validation. A new file is finalized with `os.rename`. For an overwrite,
  the original is renamed to `.<id>.pdf.arxiv-backup`, the temp file is renamed into place, then the
  backup is removed. If the second rename fails, the backup is renamed back.
- **Recovery** after a crash or power loss, run at the start of the next attempt for the same file:
  stale `.<id>.pdf.arxiv-<hex>.part` files for *that id only* are removed. If a backup exists and
  the target is missing, the backup is restored; if both exist, the backup is removed (the target
  is the new, validated file).
- **Filename**: derived only from the validated id (characters `[0-9.v]`). Response headers never
  influence it.
- **Logging**: one line per success or failure. URLs contain only the public arXiv id. No credentials
  exist.

## Not done (by design for v0.1)

Reader-UI entry, Dispatcher action, settings screens, legacy ids, metadata, cancel during transfer,
OPDS feed emulation.
