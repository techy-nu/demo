#!/usr/bin/env bash
# deploy/update-agent.sh
#
# On-device updater for the pyupdate-demo service.
# Run manually for the demo, or via the pyupdate-updater.timer systemd unit.
#
# REQUIRED: set GITHUB_REPO below to "yourusername/pyupdate-demo"
set -euo pipefail

GITHUB_REPO="techy-nu/demo"
APP_ROOT="/opt/pyupdate-demo"
SERVICE_NAME="pyupdate-demo.service"
STATE_FILE="${APP_ROOT}/state.json"
LOG_FILE="${APP_ROOT}/update.log"
HEALTH_URL="http://127.0.0.1:8080/healthz"
BAKE_SECONDS=30
KEEP_RELEASES=2

log() { echo "$(date -Iseconds) $1" | tee -a "$LOG_FILE"; }

mkdir -p "${APP_ROOT}/releases"
[[ -f "$STATE_FILE" ]] || echo '{"version":"none"}' > "$STATE_FILE"

current_version() { python3 -c "import json;print(json.load(open('${STATE_FILE}')).get('version','none'))"; }

# --- 1. Find latest release on GitHub ---
LATEST_JSON="$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")"
NEW_TAG="$(echo "$LATEST_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'])")"
NEW_VERSION="${NEW_TAG#v}"
CUR_VERSION="$(current_version)"

if [[ "$NEW_VERSION" == "$CUR_VERSION" ]]; then
  log "No update needed (current=${CUR_VERSION})"
  exit 0
fi

log "Update available: ${CUR_VERSION} -> ${NEW_VERSION}"

TARBALL_URL="$(echo "$LATEST_JSON" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for a in data['assets']:
    if a['name'].endswith('.tar.gz'):
        print(a['browser_download_url']); break
")"
CHECKSUM_URL="${TARBALL_URL}.sha256"

# --- 2. Download to a staging area, verify checksum BEFORE touching anything live ---
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

curl -fsSL "$TARBALL_URL" -o "${STAGE_DIR}/pkg.tar.gz"
curl -fsSL "$CHECKSUM_URL" -o "${STAGE_DIR}/pkg.tar.gz.sha256"

( cd "$STAGE_DIR" && sha256sum -c <(awk '{print $1"  pkg.tar.gz"}' pkg.tar.gz.sha256) ) \
  || { log "CHECKSUM VERIFICATION FAILED, aborting"; exit 1; }

# --- 3. Extract into a brand-new, independent release directory ---
NEW_DIR="${APP_ROOT}/releases/v${NEW_VERSION}"
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"
tar -xzf "${STAGE_DIR}/pkg.tar.gz" -C "$NEW_DIR" --strip-components=1

# --- 4. Atomic switch of the 'current' symlink ---
OLD_TARGET="$(readlink -f "${APP_ROOT}/current" 2>/dev/null || true)"
ln -sfn "$NEW_DIR" "${APP_ROOT}/current.tmp"
mv -Tf "${APP_ROOT}/current.tmp" "${APP_ROOT}/current"

# --- 5. Restart the service on the new version ---
systemctl restart "$SERVICE_NAME"

# --- 6. Health check with bounded bake time ---
sleep 2
END=$((SECONDS + BAKE_SECONDS))
HEALTHY=false
while [[ $SECONDS -lt $END ]]; do
  if curl -fsS "$HEALTH_URL" 2>/dev/null | grep -q '"status": "ok"'; then
    HEALTHY=true
    break
  fi
  sleep 3
done

if [[ "$HEALTHY" == true ]]; then
  python3 -c "
import json
json.dump({'version': '${NEW_VERSION}', 'previous_version': '${CUR_VERSION}'}, open('${STATE_FILE}', 'w'))
"
  log "Update to ${NEW_VERSION} SUCCESSFUL"
  ls -1dt "${APP_ROOT}"/releases/*/ | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf
else
  log "HEALTH CHECK FAILED for ${NEW_VERSION}, rolling back to ${CUR_VERSION}"
  if [[ -n "$OLD_TARGET" ]]; then
    ln -sfn "$OLD_TARGET" "${APP_ROOT}/current.tmp"
    mv -Tf "${APP_ROOT}/current.tmp" "${APP_ROOT}/current"
    systemctl restart "$SERVICE_NAME"
    log "Rollback complete, service restored to ${CUR_VERSION}"
  else
    log "No previous version to roll back to -- manual intervention required"
  fi
  exit 1
fi
