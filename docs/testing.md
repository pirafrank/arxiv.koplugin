# Testing

## Commands

```sh
scripts/check.sh                 # LuaJIT syntax, luacheck, shellcheck, unit tests
scripts/package.sh               # build + verify dist/arxiv.koplugin-v<version>.zip (+ .sha256)

# Headless KOReader integration (real KOReader v2026.07.1 runtime, SDL dummy video):
curl -fLO https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-linux-x86_64-v2026.07.1.tar.xz
echo "299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0  koreader-linux-x86_64-v2026.07.1.tar.xz" | sha256sum -c -
mkdir koreader && tar -xJf koreader-linux-x86_64-v2026.07.1.tar.xz -C koreader
KOREADER_DIR=$PWD/koreader/lib/koreader scripts/check.sh --integration
# add ARXIV_REAL_NETWORK=1 to also download a real paper from arxiv.org
```

Tools: `luajit`, `luacheck`, `shellcheck`, `zip`/`unzip`. The suite uses a minimal busted-style
runner (`spec/runner.lua`, about 50 lines) instead of busted, so it needs no LuaRocks. It runs
unchanged on stock LuaJIT and on KOReader's bundled LuaJIT.

## What is covered

**`spec/arxiv_spec.lua`**: the full input table from the plan. Modern ids at both widths and at
the 1412/1501 boundary; versions (`v0`, `v01` and suffix junk rejected); `arXiv:` prefix and
whitespace; `abs`/`pdf`/`.pdf` URLs with query/fragment; look-alike hosts, userinfo, ports, trailing
dots; other schemes; traversal (plain, percent-encoded, backslash); control and non-ASCII
characters; legacy ids (`unsupported_legacy`); canonical URL and filename.

**`spec/download_spec.lua`** (in-memory filesystem with fault injection plus a scripted transport):

- 200 with/without `Content-Length`, chunked delivery, request headers, temp file location,
  temp name collision and exhaustion.
- 404/403/429/500, TLS and host name errors, timeout, mid-body reset, transport raising,
  truncation (by length and by missing `%%EOF`), empty, HTML/JSON 200, tiny bodies, oversized
  `Content-Length`, stream abort at the cap. Each asserts no final file and no temp file.
- Trusted https redirect, absolute-path `Location`, downgrade, untrusted host, credentials, port,
  scheme, scheme-relative to another host, missing/relative `Location`, loop, too many hops.
- Existing file: refused without overwrite; replaced with overwrite; original kept on every
  failed replacement and when either rename fails.
- Unwritable directory, no space, close/flush error, rename failure, invalid destinations.
- Recovery of interrupted attempts (removes only same-id temp files; restores a backup).
- Failed backup restoration/removal or stale-temp removal stops before opening a new
  temp file or making a network request, retaining the existing bytes.
- Concurrent same-file download refused; guard released after failure; module load is side-effect free.

**`spec/integration_spec.lua`** (real KOReader File Manager, PluginLoader, widgets, ReaderUI):

- arXiv and OPDS plugins load together; one arXiv menu entry placed by `sorting_hint`
  (no `NEW:`); OPDS entry present; no stacking over three File Manager cycles.
- Download folder follows `%D%` and later changes to it.
- Invalid input keeps the dialog and text, with no request and no file; Cancel closes the dialog.
- Full tap path with an injected transport: download, **Read now**, the PDF opens in ReaderUI.
- Existing file: **Read existing** opens it; **Cancel** changes nothing; failed **Overwrite** keeps
  the original bytes, leaves no temp file and shows the error.
- 404 error message; offline defers to `NetworkMgr` without starting a transfer.
- With `ARXIV_REAL_NETWORK=1`: real download of `2609.16338` (checked to exist on 2026-11-09) through
  KOReader's LuaSocket/LuaSec with verification on, then opened in ReaderUI. `wrong.host.badssl.com`
  is rejected for host name mismatch and `expired.badssl.com` for the certificate.

## Not covered here

Real e-ink rendering, the on-screen keyboard's touch input, Kindle Wi-Fi prompts, and the
Kindle FAT filesystem's rename semantics. Those need the device checklist in
[installation-kindle.md](installation-kindle.md).
