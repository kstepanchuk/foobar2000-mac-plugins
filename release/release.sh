#!/bin/bash
# Build and publish changed foobar2000 for Mac plugins.
# GitHub Release assets are used for Behringer Multichannel Output downloads.
# Legacy plugins continue to be mirrored to nanor.ru for their existing updater.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERE_ENV="$HERE/deploy.env"
if [[ -f "$HERE_ENV" ]]; then source "$HERE_ENV"; fi
HOST="${NANOR_DEPLOY_HOST:-}"
WEBROOT="${NANOR_DEPLOY_WEBROOT:-}"
SITE="foobar2000-mac-plugins"
DIST="$HERE/dist"
STAMP="$(date +%Y-%m-%d-%H%M)"

PLUGINS=(
  "foo_wave_seekbar|waveform-seekbar|Waveform Seekbar|xcode"
  "foo_classic_ui|classic-ui|Classic UI|xcode"
  "foo_aimp_ui|aimp-ui|AIMP UI|xcode"
  "foo_behringer_output|behringer-output|Behringer Multichannel Output|cmake"
)

DRY=0
INSTALL=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
  shift
done
NOTES="${1:-}"
if [[ -z "$HOST" || -z "$WEBROOT" ]]; then
  echo "Set NANOR_DEPLOY_HOST and NANOR_DEPLOY_WEBROOT (see release/deploy.env.example)." >&2
  exit 1
fi

ssh_run() { ssh -o BatchMode=yes "$HOST" "$@" 2>&1 | { grep -v "^Welcome to " || true; }; }

mkdir -p "$DIST"
rm -rf "${DIST:?}"/*
mkdir -p "$DIST/pkg"

echo "== Comparing versions with nanor.ru"
ssh_run "cat $WEBROOT/foobar/updates.json" > "$DIST/updates.remote.json"
CHANGED=$(python3 - "$DIST" "$REPO" <<'PY'
import json, os, re, sys
dist, repo = sys.argv[1:]
remote = json.load(open(os.path.join(dist, "updates.remote.json")))
for key in ("foo_wave_seekbar", "foo_classic_ui", "foo_aimp_ui", "foo_behringer_output"):
    text = open(os.path.join(repo, "foobar2000", key, "version.h")).read()
    match = re.search(r'^#define COMPONENT_VERSION "([^"]+)"', text, re.M)
    if not match:
        raise SystemExit("Could not read COMPONENT_VERSION for " + key)
    version = match.group(1)
    open(os.path.join(dist, key + ".version"), "w").write(version + "\n")
    if remote.get(key, {}).get("version") != version:
        print(key)
PY
)
if [[ -n "$CHANGED" ]]; then echo "Will publish: $(echo "$CHANGED" | tr '\n' ' ')"; fi
if [[ -z "$CHANGED" && $INSTALL == 0 ]]; then
  echo "Nothing to publish: plugin versions match updates.json."
  exit 0
fi

echo "== Building and packaging"
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r key sub title builder <<<"$entry"
  proj="$REPO/foobar2000/$key"
  ver=$(sed -n 's/.*COMPONENT_VERSION "\(.*\)".*/\1/p' "$proj/version.h")
  [[ -n "$ver" ]] || { echo "Could not read COMPONENT_VERSION for $key" >&2; exit 1; }
  if ! grep -qx "$key" <<<"$CHANGED" && [[ $INSTALL == 0 ]]; then
    echo "-- $title $ver (unchanged, skip build)"
    continue
  fi
  echo "-- $title $ver"

  if [[ "$builder" == "cmake" ]]; then
    products="$DIST/build-$key"
    cmake -S "$proj" -B "$products" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    cmake --build "$products" --parallel
  else
    (cd "$proj" && xcodebuild -workspace "$key.xcworkspace" -scheme "$key" -configuration Release \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u)
    products=$(cd "$proj" && xcodebuild -workspace "$key".xcworkspace -scheme "$key" \
        -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')
  fi

  mkdir -p "$DIST/pkg/$key/mac"
  cp -R "${products:?}/$key.component" "$DIST/pkg/$key/mac/"
  xattr -cr "$DIST/pkg/$key"
  (cd "$DIST/pkg/$key" && zip -qry "$DIST/$key.fb2k-component" mac -x '*.DS_Store')
  shasum -a 256 "$DIST/$key.fb2k-component" | cut -d' ' -f1 > "$DIST/$key.sha256"
  echo "$ver" > "$DIST/$key.version"

  if [[ $INSTALL == 1 ]]; then
    dest="$HOME/Library/foobar2000-v2/user-components/$key"
    mkdir -p "$dest"
    rm -rf "${dest:?}/${key:?}.component"
    cp -R "$products/$key.component" "$dest/"
  fi
done

if [[ -z "$CHANGED" ]]; then
  echo "Build and local install complete; no site version changed."
  exit 0
fi

# Legacy binaries stay on nanor.ru; the new plugin's download is its GitHub Release asset.
ssh_run "cd $WEBROOT/$SITE && sha256sum waveform-seekbar/foo_wave_seekbar.fb2k-component classic-ui/foo_classic_ui.fb2k-component aimp-ui/foo_aimp_ui.fb2k-component" > "$DIST/remote.sha256"
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r key sub title builder <<<"$entry"
  echo "$sub" > "$DIST/$key.sub"
done

python3 - "$DIST" "$NOTES" $CHANGED <<'PY'
import json, os, sys
dist, notes, *changed = sys.argv[1:]
read = lambda name: open(os.path.join(dist, name)).read().strip()
data = json.load(open(os.path.join(dist, "updates.remote.json")))
remote_sha = {}
for line in open(os.path.join(dist, "remote.sha256")):
    parts = line.split()
    if len(parts) == 2:
        remote_sha[os.path.basename(parts[1]).split(".")[0]] = parts[0]
for key in ("foo_wave_seekbar", "foo_classic_ui", "foo_aimp_ui", "foo_behringer_output"):
    e = data.setdefault(key, {"url": "https://nanor.ru/foobar/"})
    version = read(key + ".version")
    if key == "foo_behringer_output":
        e["url"] = "https://nanor.ru/foobar2000-mac-plugins/behringer-output/"
        e["file"] = "https://github.com/kstepanchuk/foobar2000-mac-plugins/releases/download/%s-v%s/%s.fb2k-component" % (key, version, key)
    else:
        e["file"] = "https://nanor.ru/foobar2000-mac-plugins/%s/%s.fb2k-component" % (read(key + ".sub"), key)
    if key in changed:
        e["version"] = version
        e["sha256"] = read(key + ".sha256")
        if notes:
            e["notes"] = notes
    elif key in remote_sha:
        e["sha256"] = remote_sha[key]
json.dump(data, open(os.path.join(dist, "updates.json"), "w"), ensure_ascii=False, indent=2)
PY

python3 - "$DIST" "$HERE" <<'PY'
import os, sys
from pathlib import Path
dist, here = map(Path, sys.argv[1:])
page = (here / "site" / "index.html").read_text()
for key in ("foo_wave_seekbar", "foo_classic_ui", "foo_aimp_ui", "foo_behringer_output"):
    page = page.replace("{{" + key + "}}", (dist / (key + ".version")).read_text().strip())
(dist / "site-index.html").write_text(page)
version = (dist / "foo_behringer_output.version").read_text().strip()
detail = (here / "site" / "behringer-output" / "index.html").read_text()
(dist / "site-behringer-output.html").write_text(detail.replace("{{VERSION}}", version))
PY

if [[ $DRY == 1 ]]; then
  echo "Dry run: nothing published. New updates.json:"
  cat "$DIST/updates.json"
  exit 0
fi

if grep -qx "foo_behringer_output" <<<"$CHANGED"; then
  key=foo_behringer_output
  ver=$(cat "$DIST/$key.version")
  tag="$key-v$ver"
  notes="${NOTES:-Behringer Multichannel Output $ver}"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$DIST/$key.fb2k-component" --clobber
  else
    gh release create "$tag" "$DIST/$key.fb2k-component" --title "Behringer Multichannel Output $ver" --notes "$notes"
  fi
fi

echo "== Uploading"
upload() {
  ssh_run "cd $WEBROOT && mkdir -p \"$(dirname "$2")\" && if [ -f '$2' ]; then cp '$2' '$2.bak-$STAMP'; fi"
  scp -q -o BatchMode=yes "$1" "$HOST:$WEBROOT/$2"
  echo "   $2"
}
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r key sub title builder <<<"$entry"
  if grep -qx "$key" <<<"$CHANGED" && [[ "$key" != "foo_behringer_output" ]]; then
    upload "$DIST/$key.fb2k-component" "$SITE/$sub/$key.fb2k-component"
    if [[ "$key" == "foo_wave_seekbar" ]]; then
      upload "$DIST/$key.fb2k-component" "waveform-seekbar/$key.fb2k-component"
    fi
    ver=$(cat "$DIST/$key.version")
    ssh_run "cd $WEBROOT/$SITE/$sub && cp index.html index.html.bak-$STAMP && sed -i -E 's#(<span class=\"tag\">)v[0-9.]+(</span>)#\\1v$ver\\2#; s#(<div class=\"download-meta\">)v[0-9.]+#\\1v$ver#' index.html"
  fi
done
if grep -qx "foo_behringer_output" <<<"$CHANGED"; then
  upload "$DIST/site-behringer-output.html" "$SITE/behringer-output/index.html"
fi
upload "$DIST/site-index.html" "$SITE/index.html"
upload "$DIST/updates.json" "foobar/updates.json"

echo "== Verifying"
for entry in "${PLUGINS[@]}"; do
  IFS='|' read -r key sub title builder <<<"$entry"
  grep -qx "$key" <<<"$CHANGED" || continue
  if [[ "$key" == "foo_behringer_output" ]]; then
    gh release view "$key-v$(cat "$DIST/$key.version")" --json assets --jq '.assets[].name'
    remote=$(curl -fsSL "https://github.com/kstepanchuk/foobar2000-mac-plugins/releases/download/$key-v$(cat "$DIST/$key.version")/$key.fb2k-component" | shasum -a 256 | cut -d' ' -f1)
  else
    remote=$(curl -fsSL "https://nanor.ru/$SITE/$sub/$key.fb2k-component" | shasum -a 256 | cut -d' ' -f1)
  fi
  local=$(cat "$DIST/$key.sha256")
  if [[ "$remote" == "$local" ]]; then echo "   ok        $title $(cat "$DIST/$key.version")"; else echo "   MISMATCH  $title (download checksum differs)"; exit 1; fi
done
curl -fsSL https://nanor.ru/foobar/updates.json
printf '\nDone.\n'
