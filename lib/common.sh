# Shared helpers for the Drupal backup / restore scripts.
# Sourced by each script with its arguments: handles the common options
# (-s SITE, -c FILE, -h), loads the site configuration and leaves the
# remaining arguments in the ARGS array.
# shellcheck shell=bash

set -Eeuo pipefail
umask 077
# cron runs with PATH=/usr/bin:/bin; runuser and other admin tools are in sbin.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

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
# Settings a configuration file may define. They are cleared before a file is
# loaded, so that clone.sh can load a second (target) configuration.
CONFIG_VARS=(SITE_NAME SITE_ROOT DOCROOT DRUSH SITE_USER EXCLUDES BACKUP_DIR
  LOCAL_RETENTION_DAYS LOG_FILE RESTORE_OWNER S3_PROVIDER S3_ENDPOINT S3_REGION
  S3_BUCKET S3_PREFIX S3_ACCESS_KEY S3_SECRET_KEY S3_RETENTION_DAYS
  CLONE_HOST CLONE_DB_NAME CLONE_DB_USER CLONE_DB_HOST CLONE_DB_GRANT_HOST
  CLONE_MYSQL CLONE_STAGING CLONE_UNINSTALL_MODULES CLONE_KEEP_SETTINGS)

# Loads a configuration file (sets CONFIG_FILE) and applies the defaults.
load_config() {
  CONFIG_FILE="$1"
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
  unset "${CONFIG_VARS[@]}"
  # shellcheck source=../backup.conf.example
  source "$CONFIG_FILE"

  # Defaults
  local v db_default
  for v in SITE_NAME SITE_ROOT BACKUP_DIR; do
    [[ -n "${!v:-}" ]] || die "$v is not set in $CONFIG_FILE"
  done
  DRUSH="${DRUSH:-$SITE_ROOT/vendor/bin/drush}"
  SITE_USER="${SITE_USER:-}"
  RESTORE_OWNER="${RESTORE_OWNER:-}"
  LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-7}"
  S3_RETENTION_DAYS="${S3_RETENTION_DAYS:-30}"
  S3_PREFIX="${S3_PREFIX-drupal/$SITE_NAME}"
  LOG_FILE="${LOG_FILE-$BACKUP_DIR/backup.log}"   # empty = stdout only
  [[ -v EXCLUDES ]] || EXCLUDES=()
  # Clone target (clone.sh): database and user named after SITE_NAME.
  db_default="$(tr -c 'A-Za-z0-9_\n' '_' <<<"$SITE_NAME")"
  CLONE_HOST="${CLONE_HOST:-}"
  CLONE_DB_NAME="${CLONE_DB_NAME:-${db_default:0:64}}"
  CLONE_DB_USER="${CLONE_DB_USER:-${db_default:0:32}}"
  CLONE_DB_HOST="${CLONE_DB_HOST:-localhost}"
  CLONE_DB_GRANT_HOST="${CLONE_DB_GRANT_HOST:-localhost}"
  [[ -v CLONE_MYSQL ]] || CLONE_MYSQL=(mysql)
  CLONE_STAGING="${CLONE_STAGING:-1}"
  [[ -v CLONE_UNINSTALL_MODULES ]] || CLONE_UNINSTALL_MODULES=()
  CLONE_KEEP_SETTINGS="${CLONE_KEEP_SETTINGS:-0}"

  mkdir -p "$BACKUP_DIR"
  [[ -z "$LOG_FILE" ]] || mkdir -p "$(dirname "$LOG_FILE")"
}

# Priority: -s SITE, then -c FILE / $BACKUP_CONFIG, then the only *.conf in $CONFIG_DIR.
if [[ -n "$_site" ]]; then
  load_config "$CONFIG_DIR/$_site.conf"
elif [[ -n "${BACKUP_CONFIG:-}" ]]; then
  load_config "$BACKUP_CONFIG"
else
  mapfile -t _confs < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | sort)
  case ${#_confs[@]} in
    1) load_config "${_confs[0]}" ;;
    0) die "no configuration found in $CONFIG_DIR (missing, or not readable: run as root?). See backup.conf.example." ;;
    *) die "several sites configured, choose one with -s: $(printf '%s ' "${_confs[@]##*/}" | sed 's/\.conf//g')" ;;
  esac
fi

# --- Helpers -----------------------------------------------------------------
# Prevents two scripts from running at the same time on the same site. Each
# call opens its own descriptor (clone.sh locks both the source and the target).
acquire_lock() {
  local fd
  exec {fd}>"$BACKUP_DIR/.lock"
  flock -n "$fd" || die "another backup/restore script is running for $SITE_NAME"
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
  # rclone; upload-s3.sh checks the uploaded sizes with "rclone check".
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
