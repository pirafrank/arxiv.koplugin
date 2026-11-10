# Installing on a Kindle

Prerequisite: a jailbroken Kindle on which KOReader **already launches** and opens a local PDF.
This project does not install or repair jailbreaks, KUAL/KPM or KOReader itself. See the
[KOReader Kindle installation wiki](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices).

ZenOS is optional; the plugin uses KOReader APIs only. The plugin has been tested on a
Kindle 7th Basic with KOReader v2026.07.1 and v2026.07.2 and ZenOS 4.3.0-beta3.
The checklist below can be used to record detailed results for other device or software
configurations; operation without ZenOS has not been tested.

## Steps

1. In KOReader, note **☰ → Help → About** (KOReader version). Quit KOReader completely
   (**☰ → Exit**).
2. Connect USB. The Kindle's USB root (`/mnt/us` on the device) shows `documents/` and `koreader/`.
3. Back up any existing `koreader/plugins/arxiv.koplugin` folder somewhere outside `koreader/plugins/`.
4. Download `arxiv.koplugin-v2026.11.1.zip` and `arxiv.koplugin-v2026.11.1.zip.sha256` from the
   [release page](https://github.com/pirafrank/arxiv.koplugin/releases), and check the checksum
   (`sha256sum -c arxiv.koplugin-v2026.11.1.zip.sha256`).
5. Extract the zip **into `koreader/plugins/`**. The result must be exactly:

   ```text
   koreader/plugins/arxiv.koplugin/_meta.lua
   koreader/plugins/arxiv.koplugin/main.lua
   koreader/plugins/arxiv.koplugin/arxiv.lua
   koreader/plugins/arxiv.koplugin/download.lua
   koreader/plugins/arxiv.koplugin/README.md
   koreader/plugins/arxiv.koplugin/LICENSE
   ```

   Not `arxiv.koplugin/arxiv.koplugin/…`, and not `arxiv.koplugin-main/…`.

   From a Linux/WSL shell you can instead run
   `scripts/install-to-kindle.sh /path/to/Kindle arxiv.koplugin-v2026.11.1.zip`. It checks the target,
   backs up an existing copy, copies only the four files, verifies them, and never unmounts the device.
6. Eject the Kindle safely and start KOReader.
7. If needed, enable **arXiv Downloader** in **☰ → Tools → More tools → Plugin management** and restart.
8. **☰ → (magnifier/search menu) → Download arXiv PDF**.

## Rollback

Quit KOReader, connect USB, delete `koreader/plugins/arxiv.koplugin`, restore your backup if any,
eject and relaunch. Or run `scripts/install-to-kindle.sh --rollback <root> <backup-dir>`. Downloaded
PDFs are ordinary files and are not touched.

## Device checklist (record PASS / FAIL / (outcome here); never infer)

| # | Check | Result |
| --- | --- | --- |
| 1 | KOReader launches independently of the new plugin | (outcome here) |
| 2 | Plugin detected/enabled, exactly one menu entry | (outcome here) |
| 3 | Keyboard accepts a `2609.16338`-style ID | (outcome here) |
| 4 | Full `https://arxiv.org/abs/...` URL accepted | (outcome here) |
| 5 | Existing real PDF downloaded via Kindle Wi-Fi | (outcome here) |
| 6 | PDF stored in shared KOReader download folder | (outcome here) |
| 7 | `Read now` opens PDF and returns to normal UI | (outcome here) |
| 8 | Same ID detected as existing file | (outcome here) |
| 9 | Failed overwrite leaves old bytes intact | (outcome here) |
| 10 | Invalid ID rejected without HTTP/file creation | (outcome here) |
| 11 | Offline result is controlled, no crash | (outcome here) |
| 12 | OPDS menu/navigation still works | (outcome here) |
| 13 | No leftover temp files after controlled failures (`ls -a` the download folder) | (outcome here) |
| 14 | Exit/relaunch works and downloaded PDF persists | (outcome here) |
| 15 | `koreader/crash.log` has no new unhandled Lua exceptions | (outcome here) |

Record device model, firmware, KOReader version, paper ID and results in
[compatibility.md](compatibility.md). Check that logs and screenshots contain no credentials before
sharing them.
