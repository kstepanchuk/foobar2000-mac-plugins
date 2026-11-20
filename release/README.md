# Publishing

`release.sh` builds changed components, creates `.fb2k-component` packages and compares their versions with `https://nanor.ru/foobar/updates.json`.

Changed legacy UI components are uploaded to nanor.ru as before. Behringer Multichannel Output gets a GitHub Release asset named `foo_behringer_output.fb2k-component`; the site detail page links to that asset. The release updates the plugin catalog and `updates.json`. The combined all-plugins archive is no longer generated or linked.

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

The script keeps timestamped copies of every replaced nanor.ru file, creates the GitHub Release `foo_behringer_output-v<VERSION>`, publishes the site page and update manifest, then verifies the release asset checksum.

Use `--dry-run` to build and show the resulting update manifest without creating a GitHub Release or uploading files.
