# Troubleshooting

| Symptom | What to check |
| --- | --- |
| No **Download arXiv PDF** entry | The zip layout must give `koreader/plugins/arxiv.koplugin/main.lua` (not nested). Fully restart KOReader. Check **Tools → More tools → Plugin management** (enable **arXiv Downloader**). The entry is in the File Manager's search (magnifier) menu only, not in the reader menu. Look in `koreader/crash.log` for `Error when loading … arxiv.koplugin`. Compare your KOReader version with [compatibility.md](compatibility.md). |
| "Not a valid arXiv identifier or URL" | Only post-2007 ids (`2609.16338`, `2609.16338v2`) and `arxiv.org` abs/pdf links. Old ids such as `cs/9901001` are not supported in v0.1. |
| "HTTP 404" | The id or version does not exist on arXiv. Check it at `https://arxiv.org/abs/<id>`. |
| "Network error" / "timed out" | Wi-Fi must be on and connected with internet access. Retry; nothing partial is kept. |
| "Secure connection … failed (certificate check)" | Usually a wrong device date/time (certificates look expired or not yet valid). Fix the clock. Also confirm `koreader/data/ca-bundle.crt` exists. **Do not** look for ways to disable TLS verification. |
| "redirected to an insecure/unexpected address" | arXiv (or something in between, such as a captive portal) redirected outside `https://*.arxiv.org`. Log in to the Wi-Fi portal in a browser, or retry later. |
| "exceeds the 100 MiB size limit" | The cap is deliberate for e-readers. |
| "did not return a PDF" / "incomplete" | arXiv served an error page or the transfer was cut. Retry later. The previous copy, if any, is unchanged. |
| "Could not write the file" | Check free space and that the download folder exists and is writable. Set KOReader's download folder (the one OPDS uses) to a folder under `documents/`. |
| PDF won't open | Check the file starts with `%PDF-` (`head -c 5 file.pdf`) and try it in a desktop viewer. |
| OPDS misbehaves | To establish causality, remove *only* `koreader/plugins/arxiv.koplugin`, restart and reproduce. This plugin never reads or writes `settings/opds.lua` or credentials. Never clear another plugin's settings to "fix" this one. |
| KOReader itself does not start | **BLOCKED BY KOReader LAUNCHER / JAILBREAK**. Outside this project's scope; fix KOReader/jailbreak first. |

Hidden leftovers named `.<id>.pdf.arxiv-*.part` or `.<id>.pdf.arxiv-backup` can only remain after
a crash or power loss. The next download of the same id cleans them up (restoring the backup if the
PDF is missing). Deleting them by hand is also safe when the plain `<id>.pdf` is present.

## Reporting issues

Include the KOReader version (Help → About), Kindle model and firmware, the arXiv id you used,
the exact message, reproduction steps, and the `arXiv:` lines from `koreader/crash.log` (check
them for anything private first).
