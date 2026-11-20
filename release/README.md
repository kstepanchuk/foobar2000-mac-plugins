# Publishing

`release.sh` builds changed components, creates `.fb2k-component` packages and compares their versions with `https://nanor.ru/foobar/updates.json` and GitHub Releases.

Every plugin version has a GitHub Release with its `.fb2k-component` asset. The nanor.ru detail pages link to those assets; `updates.json` also points to GitHub. Existing legacy download files remain on nanor.ru as mirrors. The combined all-plugins archive is no longer generated or linked.

## Configure deployment

Create `release/deploy.env` locally; this file is ignored by Git:

```sh
NANOR_DEPLOY_HOST="user@host"
NANOR_DEPLOY_WEBROOT="/path/to/nanor.xyz/public_html"
```

SSH key authentication must work in batch mode. GitHub Releases require `gh` to be authenticated as a repository writer.

## Release

Run from the repository root after committing and pushing the version change:

```sh
./release/release.sh "Release notes"
```

The script keeps timestamped copies of every replaced nanor.ru file, creates missing GitHub Releases in the form `<component>-v<VERSION>`, publishes the affected detail page, catalog and update manifest, then verifies release asset checksums.

Use `--dry-run` to build and show the resulting update manifest without creating a GitHub Release or uploading files.
