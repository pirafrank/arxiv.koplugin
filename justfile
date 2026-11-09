set shell := ["bash", "-euo", "pipefail", "-c"]

# Generate the changelog with an Unreleased section.
changelog:
    git-cliff --output CHANGELOG.md

# Prepare a versioned changelog before committing and tagging the release.
release version:
    version="{{version}}"; meta_version=$(sed -n 's/^ *version = "\([0-9][0-9.]*\)",$/\1/p' arxiv.koplugin/_meta.lua); test "$version" = "$meta_version" || { echo "release version $version != _meta.lua v$meta_version" >&2; exit 1; }; git-cliff --tag "v$version" --output CHANGELOG.md
