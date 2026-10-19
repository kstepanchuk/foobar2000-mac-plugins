#!/bin/bash
# Build the nanor.ru foobar2000 plugins and publish new versions to nanor.ru.
#
#   ./release.sh "Что нового"          build, package, upload changed plugins, update updates.json
#   ./release.sh --dry-run "..."       build and package only, show what would be uploaded
#   ./release.sh --install "..."       also install the fresh builds into the local foobar2000
#
# A plugin is published when its version in version.h differs from the one in the live
# updates.json. Every replaced file on the server is kept as <name>.bak-<date>.
set -euo pipefail

# Deployment target comes from the environment or from release/deploy.env (not in git):
#   export NANOR_DEPLOY_HOST="user@host"      SSH login (key auth)
#   export NANOR_DEPLOY_WEBROOT="path/to/docroot"
HERE_ENV="$(cd "$(dirname "$0")" && pwd)/deploy.env"
if [[ -f "$HERE_ENV" ]]; then source "$HERE_ENV"; fi
HOST="${NANOR_DEPLOY_HOST:-}"
WEBROOT="${NANOR_DEPLOY_WEBROOT:-}"
SITE="foobar2000-mac-plugins"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DIST="$HERE/dist"
STAMP="$(date +%Y-%m-%d-%H%M)"

# key | project root | site subfolder | title
PLUGINS=(
  "foo_wave_seekbar|$REPO|waveform-seekbar|Waveform Seekbar"
  "foo_classic_ui|$REPO|classic-ui|Classic UI"
  "foo_aimp_ui|$REPO|aimp-ui|AIMP UI"
)

DRY=0; INSTALL=0
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
  echo "Set NANOR_DEPLOY_HOST and NANOR_DEPLOY_WEBROOT (see the top of this script)." >&2; exit 1
fi

ssh_run() { ssh -o BatchMode=yes "$HOST" "$@" 2>&1 | { grep -v "^Welcome to " || true; }; }

rm -rf "${DIST:?}"; mkdir -p "$DIST/pkg" "$DIST/bundle/foobar2000-mac-plugins"

echo "== Building"
for p in "${PLUGINS[@]}"; do
  IFS='|' read -r key root sub title <<<"$p"
  proj="$root/foobar2000/$key"
  ver=$(sed -n 's/.*COMPONENT_VERSION "\(.*\)".*/\1/p' "$proj/version.h")
  echo "-- $title $ver"
  (cd "$proj" && xcodebuild -workspace "$key.xcworkspace" -scheme "$key" -configuration Release \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u)
  products=$(cd "$proj" && xcodebuild -workspace "$key.xcworkspace" -scheme "$key" -configuration Release -showBuildSettings 2>/dev/null \
      | awk '/ BUILT_PRODUCTS_DIR /{print $3}')
  # foobar2000 for Mac expects the bundle under mac/ inside the .fb2k-component zip.
  mkdir -p "$DIST/pkg/$key/mac"
  cp -R "${products:?}/$key.component" "$DIST/pkg/$key/mac/"
  xattr -cr "$DIST/pkg/$key"
  (cd "$DIST/pkg/$key" && zip -qry "$DIST/$key.fb2k-component" mac -x '*.DS_Store')
  cp "$DIST/$key.fb2k-component" "$DIST/bundle/foobar2000-mac-plugins/"
  echo "$ver" > "$DIST/$key.version"
  if [[ $INSTALL == 1 ]]; then
    dest="$HOME/Library/foobar2000-v2/user-components/$key"
    mkdir -p "$dest"; rm -rf "${dest:?}/${key:?}.component"; cp -R "$products/$key.component" "$dest/"
  fi
done

# README with current versions, then the all-in-one archive.
sed -e "s/Waveform Seekbar [0-9.]*:/Waveform Seekbar $(cat "$DIST/foo_wave_seekbar.version"):/" \
    -e "s/Classic UI [0-9.]*:/Classic UI $(cat "$DIST/foo_classic_ui.version"):/" \
    -e "s/AIMP UI [0-9.]*:/AIMP UI $(cat "$DIST/foo_aimp_ui.version"):/" \
    "$HERE/README.txt" > "$DIST/bundle/foobar2000-mac-plugins/README.txt"
xattr -cr "$DIST/bundle"
(cd "$DIST/bundle" && ditto -c -k --norsrc --noextattr --keepParent foobar2000-mac-plugins "$DIST/foobar2000-mac-plugins.zip")

echo "== Comparing with nanor.ru"
ssh_run "cat $WEBROOT/foobar/updates.json" > "$DIST/updates.remote.json"
CHANGED=$(python3 - "$DIST" <<'PY'
import json, sys, os
dist = sys.argv[1]
remote = json.load(open(os.path.join(dist, "updates.remote.json")))
for key in ("foo_wave_seekbar", "foo_classic_ui", "foo_aimp_ui"):
    local = open(os.path.join(dist, key + ".version")).read().strip()
    if remote.get(key, {}).get("version") != local:
        print(key)
PY
)
if [[ -z "$CHANGED" ]]; then
  echo "Nothing to publish: versions on nanor.ru match version.h. Bump COMPONENT_VERSION first."
  exit 0
fi
echo "Will publish: $(echo $CHANGED)"

# Checksums of what is live now, for plugins that are not being republished.
ssh_run "cd $WEBROOT/$SITE && sha256sum waveform-seekbar/foo_wave_seekbar.fb2k-component classic-ui/foo_classic_ui.fb2k-component aimp-ui/foo_aimp_ui.fb2k-component" > "$DIST/remote.sha256"
for p in "${PLUGINS[@]}"; do
  IFS='|' read -r key root sub title <<<"$p"
  shasum -a 256 "$DIST/$key.fb2k-component" | cut -d' ' -f1 > "$DIST/$key.sha256"
  echo "$sub" > "$DIST/$key.sub"
done

python3 - "$DIST" "$NOTES" $CHANGED <<'PY'
import json, sys, os
dist, notes, changed = sys.argv[1], sys.argv[2], sys.argv[3:]
read = lambda name: open(os.path.join(dist, name)).read().strip()
data = json.load(open(os.path.join(dist, "updates.remote.json")))
remote_sha = {}
for line in open(os.path.join(dist, "remote.sha256")):
    parts = line.split()
    if len(parts) == 2: remote_sha[os.path.basename(parts[1]).split(".")[0]] = parts[0]
for key in ("foo_wave_seekbar", "foo_classic_ui", "foo_aimp_ui"):
    e = data.setdefault(key, {"url": "https://nanor.ru/foobar/"})
    # Direct file + checksum let the plugins install updates themselves.
    e["file"] = "https://nanor.ru/foobar2000-mac-plugins/%s/%s.fb2k-component" % (read(key + ".sub"), key)
    if key in changed:
        e["version"] = read(key + ".version")
        e["sha256"] = read(key + ".sha256")
        if notes: e["notes"] = notes
    elif key in remote_sha:
        e["sha256"] = remote_sha[key]
json.dump(data, open(os.path.join(dist, "updates.json"), "w"), ensure_ascii=False, indent=2)
PY

if [[ $DRY == 1 ]]; then
  echo "Dry run: nothing uploaded. New updates.json:"; cat "$DIST/updates.json"; exit 0
fi

echo "== Uploading"
upload() { # local file, remote path relative to webroot
  ssh_run "cd $WEBROOT && if [ -f '$2' ]; then cp '$2' '$2.bak-$STAMP'; fi"
  scp -q -o BatchMode=yes "$1" "$HOST:$WEBROOT/$2"
  echo "   $2"
}
for p in "${PLUGINS[@]}"; do
  IFS='|' read -r key root sub title <<<"$p"
  if grep -qx "$key" <<<"$CHANGED"; then
    upload "$DIST/$key.fb2k-component" "$SITE/$sub/$key.fb2k-component"
    # Old direct link from before the site moved.
    if [[ $key == foo_wave_seekbar ]]; then upload "$DIST/$key.fb2k-component" "waveform-seekbar/$key.fb2k-component"; fi
    # Version labels on the plugin page: <span class="tag">v0.6</span> and <div class="download-meta">v0.6…
    ver=$(cat "$DIST/$key.version")
    ssh_run "cd $WEBROOT/$SITE/$sub && cp index.html index.html.bak-$STAMP && sed -i -E 's#(<span class=\"tag\">)v[0-9.]+(</span>)#\\1v$ver\\2#; s#(<div class=\"download-meta\">)v[0-9.]+#\\1v$ver#' index.html 2>/dev/null; true"
    echo "   $SITE/$sub/index.html → v$ver"
  fi
done
upload "$DIST/foobar2000-mac-plugins.zip" "$SITE/foobar2000-mac-plugins.zip"
upload "$DIST/updates.json" "foobar/updates.json"

echo "== Verifying"
for p in "${PLUGINS[@]}"; do
  IFS='|' read -r key root sub title <<<"$p"
  grep -qx "$key" <<<"$CHANGED" || continue
  remote=$(curl -s "https://nanor.ru/$SITE/$sub/$key.fb2k-component" | md5 -q)
  local=$(md5 -q "$DIST/$key.fb2k-component")
  if [[ "$remote" == "$local" ]]; then echo "   ok        $title $(cat "$DIST/$key.version")"; else echo "   MISMATCH  $title (server returns a different file)"; fi
done
curl -s https://nanor.ru/foobar/updates.json
echo
echo "Done."
