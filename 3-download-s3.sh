#!/usr/bin/env bash
# 3 - Download a backup from S3-compatible object storage.
#
# Usage: 3-download-s3.sh [-s SITE | -c CONFIG_FILE] --list
#            list the backups available on S3
#        3-download-s3.sh [-s SITE | -c CONFIG_FILE] [BACKUP_NAME|latest]
#            download into $BACKUP_DIR/BACKUP_NAME (default: latest)

source "$(dirname "$(readlink -f "$0")")/lib/common.sh" "$@"
set -- "${ARGS[@]}"

require_cmd sha256sum flock
setup_rclone

# Only "no backup found" is tolerated: an rclone error (credentials, network)
# makes the script fail.
list_remote() {
  local dirs
  dirs="$(rclone lsf --dirs-only "$S3_REMOTE")" || die "cannot list $S3_REMOTE"
  sed 's#/$##' <<<"$dirs" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort || true
}

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
  list_remote
  exit 0
fi

acquire_lock

NAME="${1:-latest}"
if [[ "$NAME" == "latest" ]]; then
  NAME="$(list_remote | tail -n1)"
  [[ -n "$NAME" ]] || die "no backup found in $S3_REMOTE"
fi

DEST="$BACKUP_DIR/$NAME"
[[ -d "$DEST" ]] && warn "$DEST already exists locally: only missing/changed files are downloaded."

log "=== Downloading $S3_REMOTE/$NAME -> $DEST ==="
rclone copy "$S3_REMOTE/$NAME" "$DEST" --retries 5 --stats-one-line --stats 1m
verify_backup "$DEST"
log "Backup available: $DEST"
log "To restore: $SCRIPT_DIR/4-restore.sh -c $CONFIG_FILE $NAME"
