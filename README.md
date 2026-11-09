# arxiv.koplugin: arXiv PDF downloader for KOReader

Type or paste an arXiv identifier or link in KOReader's File Manager, and the paper's PDF is saved
to your KOReader download folder, ready to read.

Example input (syntax only): `2609.16338`, `2609.16338v2`, `arXiv:2609.16338`,
`https://arxiv.org/abs/2609.16338`, `https://arxiv.org/pdf/2609.16338v2.pdf`.

## Requirements and status

Requires KOReader with working Wi-Fi and a writable download folder. The target is a
jailbroken Kindle running KOReader, with or without Zenos; Zenos is not a dependency.
Kindle and Zenos device validation is pending. No device has been tested yet.

Tested locally with KOReader v2026.07.1 on Linux using headless integration tests.
See [compatibility](https://github.com/pirafrank/arxiv.koplugin/blob/main/docs/compatibility.md)
for the recorded results and hardware limitations.

## Install from Storefront

Once a public release is available and listed, open Storefront in KOReader, search for
**arxiv.koplugin**, install it, and restart KOReader. If it is not listed, use
Storefront's **Install plugin from URL** option with `https://github.com/pirafrank/arxiv.koplugin`.
Menu labels vary by Storefront version. A release and catalog refresh are needed for
normal search discovery; the repository name alone does not guarantee a listing.

## Install manually

1. Download `arxiv.koplugin-vX.Y.Z.zip` from [Releases](https://github.com/pirafrank/arxiv.koplugin/releases)
   (a `.sha256` checksum is attached).
2. Quit KOReader. Extract the zip into `koreader/plugins/` so you get
   `koreader/plugins/arxiv.koplugin/main.lua` (no extra folder level).
3. Start KOReader. If needed, enable **arXiv Downloader** in **Tools → More tools → Plugin management**
   and restart.

Kindle specifics, an install helper script and rollback: [docs/installation-kindle.md](https://github.com/pirafrank/arxiv.koplugin/blob/main/docs/installation-kindle.md).
To update, replace the folder the same way. To uninstall, delete `koreader/plugins/arxiv.koplugin`.
Downloaded PDFs stay.

## Use

File Manager → menu → search (magnifier) tab → **Download arXiv PDF** → enter the ID or URL →
**Download** → **Read now** (or **Later**).

If `<id>.pdf` already exists you can **Read existing**, **Overwrite** or **Cancel**. Nothing is
replaced without asking, and a failed overwrite keeps the old file.
Downloads are written to a temporary file and checked for a PDF header and end marker
before being saved under the final filename. Failed interrupted-file recovery stops
the download and retains the existing backup.

## Where files go

The PDF is saved as `<id>.pdf` (for example `2609.16338v2.pdf`) in KOReader's common download folder.
This is the same folder the built-in OPDS catalog uses by default (`%D%`). Changing it there changes
it here. The plugin does not read or modify OPDS settings. It is **not** an OPDS feed and
works with or without the OPDS plugin installed.

## Accepted input and limitations

- Modern ids since April 2007: `YYMM.NNNN` (0704–1412) and `YYMM.NNNNN` (1501+), optional `vN`;
  optional `arXiv:` prefix; `arxiv.org` (also `www.`/`export.`) `/abs/` or `/pdf/` links, with or
  without `.pdf`, query or fragment.
- **Not supported in v0.1:** old-style ids like `cs/9901001`, any non-arXiv host, source files or
  other formats (PDF only), title/author/keyword search, a reader-menu entry, cancelling a transfer in progress.
- Downloads are capped at 100 MiB. The screen waits during the transfer, as OPDS downloads do.

## Network and privacy

The only requests go to `https://arxiv.org/pdf/<id>` and, if arXiv redirects, other `https://*.arxiv.org`
addresses (at most 5 redirects; HTTP downgrades are refused). TLS certificates and host names are verified
using KOReader's bundled CA list. There are no accounts, credentials, analytics or telemetry, no external
binaries (`curl`, Python, …), and nothing runs in the background. Details: [docs/architecture.md](https://github.com/pirafrank/arxiv.koplugin/blob/main/docs/architecture.md).

## Troubleshooting

See [docs/troubleshooting.md](https://github.com/pirafrank/arxiv.koplugin/blob/main/docs/troubleshooting.md). When reporting an issue, include the KOReader version,
device model, the arXiv id, the exact message, steps to reproduce, and the sanitized `arXiv:` lines from
`crash.log`.

## Development

```sh
scripts/check.sh                    # syntax, luacheck, shellcheck, unit tests
scripts/package.sh                  # build + verify dist/arxiv.koplugin-v<version>.zip
KOREADER_DIR=… scripts/check.sh --integration   # headless KOReader runtime, see docs/testing.md
git-cliff --output CHANGELOG.md     # regenerate history using cliff.toml (git-cliff 2.10.1)
```

Storefront publishing guide: [docs/releasing.md](https://github.com/pirafrank/arxiv.koplugin/blob/main/docs/releasing.md).

Write Conventional Commit messages (`feat:`, `fix:`, `docs:`, etc.). CHANGELOG.md is
generated from committed history using [git-cliff](https://git-cliff.org/docs/configuration/);
keep current features and limitations in this README so they are visible in Storefront.
Uncommitted changes do not appear in the generated changelog.

Releases are built by `.github/workflows/release.yml` from an annotated `vX.Y.Z` tag that matches
`_meta.lua`. The workflow generates the changelog and release notes from the tagged history.

## License

MIT, see [LICENSE](https://github.com/pirafrank/arxiv.koplugin/blob/main/LICENSE).

This is independently written code which calls KOReader's runtime APIs.
KOReader is AGPL-3.0, and MIT-licensed code can be combined with it.
