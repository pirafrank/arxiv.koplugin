# Storefront publishing guide

This guide covers preparing a release and checking that KOReader Storefront can
discover and install it. For device installation steps, see
[installation-kindle.md](installation-kindle.md).

## Prepare a release

1. Run the checks, including both integration configurations listed in
   [testing.md](testing.md), then package the plugin. Review the generated ZIP
   and checksum:

   ```sh
   scripts/check.sh
   scripts/package.sh
   ```

2. Use Conventional Commit messages (`feat:`, `fix:`, `docs:`, etc.) and keep
   user-facing features and limitations current in the README. The changelog is
   generated from committed history; do not edit its entries by hand.
3. Set the version in `arxiv.koplugin/_meta.lua`, then commit the release source
   changes. Generate and review the versioned changelog with:

   ```sh
   just release X.Y.Z
   ```

   This checks the version against `_meta.lua` and runs git-cliff. Commit the
   generated `CHANGELOG.md`, then create and push an annotated `vX.Y.Z` tag for
   that commit. A tag push triggers `.github/workflows/release.yml`; the workflow
   verifies the version, runs checks, builds the ZIP and checksum, and publishes
   a GitHub Release. It does not commit generated files back to the repository.

   To refresh the development changelog with an Unreleased section, run
   `just changelog`.

4. Confirm the GitHub Release and both downloadable assets are available. The
   release notes link to the changelog at the tagged revision.

## Check Storefront discovery

Storefront's catalog builder can discover repositories by topic or by
`.koplugin` in the repository name, and normal listing requires a usable release
or prerelease. After publishing, allow a catalog refresh, then check search,
README display, installation, and update detection on a device. The refresh may
not happen immediately, so do not promise immediate listing.

Storefront can also install from a repository URL before normal catalog
discovery. For this plugin, use:
`https://github.com/pirafrank/arxiv.koplugin`.

The community plugin index is a separate discovery route. Adding an entry there
does not guarantee Storefront listing; follow that index's current contribution
instructions if you choose to submit it.

## Device validation

Device testing has been performed on a Kindle 7th Basic with KOReader v2026.07.1
and v2026.07.2 and ZenOS 4.3.0-beta3; see [compatibility.md](compatibility.md).
Storefront installation on Kindle and operation without ZenOS remain untested.
Record any additional device, firmware, KOReader and Storefront versions, ZenOS
configuration, and individual results in [compatibility.md](compatibility.md).

## References

- [Storefront catalog builder](https://github.com/misko903/storefront.koplugin/blob/main/tools/build_catalog.py)
- [Storefront installer](https://github.com/misko903/storefront.koplugin/blob/main/storefront.koplugin/storefront_installer.lua)
- [Community plugin index](https://github.com/omer-faruq/koreader-plugin-index)
