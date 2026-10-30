# Shared helpers for the Drupal backup / restore scripts.
# Sourced by each script with its arguments: handles the common options
# (-s SITE, -c FILE, -h), loads the site configuration and leaves the
# remaining arguments in the ARGS array.
# shellcheck shell=bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-/etc/drupal-backup}"

log()  { local m; m="[$(date '+%F %T')] $*"; echo "$m"; [[ -n "${LOG_FILE:-}" ]] && echo "$m" >>"$LOG_FILE" || true; }
warn() { log "WARNING: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

trap 'die "failed at line $LINENO (exit code $?): $BASH_COMMAND"' ERR

usage() { sed -n '2,/^$/ s/^#[ ]\{0,1\}//p' "$0"; }

# --- Common options ----------------------------------------------------------
ARGS=()
_site=""
while (( $# )); do
  case "$1" in
    -s|--site)   [[ $# -ge 2 ]] || die "$1 requires a site name"; _site="$2"; shift 2 ;;
    -c|--config) [[ $# -ge 2 ]] || die "$1 requires a file"; BACKUP_CONFIG="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done

# --- Configuration file ------------------------------------------------------
# Priority: -s SITE, then -c FILE / $BACKUP_CONFIG, then the only *.conf in $CONFIG_DIR.
if [[ -n "$_site" ]]; then
  CONFIG_FILE="$CONFIG_DIR/$_site.conf"
elif [[ -n "${BACKUP_CONFIG:-}" ]]; then
  CONFIG_FILE="$BACKUP_CONFIG"
else
  mapfile -t _confs < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | sort)
  case ${#_confs[@]} in
    1) CONFIG_FILE="${_confs[0]}" ;;
    0) die "no configuration found in $CONFIG_DIR (missing, or not readable: run as root?). See backup.conf.example." ;;
    *) die "several sites configured, choose one with -s: $(printf '%s ' "${_confs[@]##*/}" | sed 's/\.conf//g')" ;;
  esac
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
  cat >&2 <<EOF
Configuration not found or not readable: $CONFIG_FILE
Install it with:
  sudo install -d -m 700 $(dirname "$CONFIG_FILE")
  sudo install -m 600 $SCRIPT_DIR/backup.conf.example $CONFIG_FILE
The file is only readable by root: run the script with sudo.
EOF
  exit 1
fi
# shellcheck source=../backup.conf.example
source "$CONFIG_FILE"

# --- Defaults ----------------------------------------------------------------
for _v in SITE_NAME SITE_ROOT BACKUP_DIR; do
  [[ -n "${!_v:-}" ]] || die "$_v is not set in $CONFIG_FILE"
done
DRUSH="${DRUSH:-$SITE_ROOT/vendor/bin/drush}"
SITE_USER="${SITE_USER:-}"
RESTORE_OWNER="${RESTORE_OWNER:-}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-7}"
S3_RETENTION_DAYS="${S3_RETENTION_DAYS:-30}"
S3_PREFIX="${S3_PREFIX-drupal/$SITE_NAME}"
LOG_FILE="${LOG_FILE-$BACKUP_DIR/backup.log}"   # empty = stdout only
[[ -v EXCLUDES ]] || EXCLUDES=()

mkdir -p "$BACKUP_DIR"
[[ -n "$LOG_FILE" ]] && mkdir -p "$(dirname "$LOG_FILE")"

# --- Helpers -----------------------------------------------------------------
# Prevents two scripts from running at the same time on the same site.
acquire_lock() {
  exec 9>"$BACKUP_DIR/.lock"
  flock -n 9 || die "another backup/restore script is running for $SITE_NAME"
}

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done
}

# Drupal docroot of a project directory: $DOCROOT if set, else web/
# (Composer layout) if present, else the project directory itself.
docroot_of() {
  if [[ -n "${DOCROOT:-}" ]]; then
    echo "$1/$DOCROOT"
  elif [[ -f "$1/web/index.php" ]]; then
    echo "$1/web"
  else
    echo "$1"
  fi
}

# Runs drush from the site root; as root, runs it as SITE_USER
# (default: owner of SITE_ROOT).
drush() {
  local cmd=("$DRUSH" --root="$(docroot_of "$SITE_ROOT")" "$@") user
  if (( EUID == 0 )); then
    user="${SITE_USER:-$(stat -c %U "$SITE_ROOT")}"
    [[ "$user" != root ]] && cmd=(runuser -u "$user" -- "${cmd[@]}")
  fi
  (cd "$SITE_ROOT" && "${cmd[@]}")
}

# Configures rclone through environment variables: remote "s3:".
setup_rclone() {
  require_cmd rclone
  local v
  for v in S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY; do
    [[ -n "${!v:-}" ]] || die "$v is not set in $CONFIG_FILE"
  done
  # Everything comes from the environment: no rclone.conf (empty = in-memory
  # config, avoids the "Config file ... not found" notice).
  export RCLONE_CONFIG=""
  export RCLONE_CONFIG_S3_TYPE=s3
  export RCLONE_CONFIG_S3_PROVIDER="${S3_PROVIDER:-Other}"
  export RCLONE_CONFIG_S3_ENDPOINT="${S3_ENDPOINT:-}"
  export RCLONE_CONFIG_S3_REGION="${S3_REGION:-}"
  export RCLONE_CONFIG_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY"
  export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
  export RCLONE_CONFIG_S3_ACL=private
  export RCLONE_CONFIG_S3_NO_CHECK_BUCKET=true
  # No HEAD after each upload: R2 rejects "HEAD ?versionId=" (501) with older
  # rclone; 2-upload-s3.sh checks the uploaded sizes with "rclone check".
  export RCLONE_CONFIG_S3_NO_HEAD=true
  S3_REMOTE="s3:$S3_BUCKET${S3_PREFIX:+/$S3_PREFIX}"
}

# Name of the most recent local backup (YYYYMMDD-HHMMSS directories).
latest_local_backup() {
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*' -printf '%f\n' | sort | tail -n1
}

# Checks the checksums of a backup.
verify_backup() {
  local dir="$1"
  [[ -f "$dir/SHA256SUMS" ]] || die "SHA256SUMS missing in $dir"
  (cd "$dir" && sha256sum --quiet -c SHA256SUMS) || die "invalid checksums in $dir"
  log "Checksums OK: $dir"
}
