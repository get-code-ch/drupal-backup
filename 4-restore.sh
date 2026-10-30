#!/usr/bin/env bash
# 4 - Restore a Drupal site (files and/or database) from a local backup.
#     Also works on a new server where the site does not exist yet
#     (disaster recovery, migration).
#
# Usage: 4-restore.sh [-s SITE | -c CONFIG_FILE] [options] [BACKUP_NAME]
#   BACKUP_NAME      directory in $BACKUP_DIR (default: the most recent)
#   --db-only        restore the database only
#   --files-only     restore the files only
#   --keep-settings  keep the current sites/*/settings*.php and services.yml
#                    (e.g. the target server uses other database credentials)
#   --updb           run "drush updatedb" after the restore
#   --yes            do not ask for confirmation
#
# Safety nets when the site already exists:
#   - the current tree is kept as $SITE_ROOT.before-restore-<date>
#   - the current database is dumped to $BACKUP_DIR/before-restore-<date>.sql.gz

source "$(dirname "$(readlink -f "$0")")/lib/common.sh" "$@"
set -- "${ARGS[@]}"

DO_DB=1 DO_FILES=1 ASSUME_YES=0 KEEP_SETTINGS=0 UPDB=0 NAME=""
while (( $# )); do
  case "$1" in
    --db-only)       DO_FILES=0 ;;
    --files-only)    DO_DB=0 ;;
    --keep-settings) KEEP_SETTINGS=1 ;;
    --updb)          UPDB=1 ;;
    --yes|-y)        ASSUME_YES=1 ;;
    -*)              die "unknown option: $1 (see --help)" ;;
    *)               NAME="$1" ;;
  esac
  shift
done
(( DO_DB || DO_FILES )) || die "--db-only and --files-only are mutually exclusive"

require_cmd tar gzip sha256sum flock
acquire_lock

NAME="${NAME:-$(latest_local_backup)}"
[[ -n "$NAME" ]] || die "no local backup in $BACKUP_DIR (see 3-download-s3.sh)"
SRC="$BACKUP_DIR/$NAME"
[[ -d "$SRC" ]] || die "backup not found: $SRC"
verify_backup "$SRC"

SITE_EXISTS=0
[[ -e "$SITE_ROOT" ]] && SITE_EXISTS=1
if (( ! SITE_EXISTS && ! DO_FILES )); then
  die "$SITE_ROOT does not exist: restore the files first (without --db-only)"
fi
if (( KEEP_SETTINGS && ! (SITE_EXISTS && DO_FILES) )); then
  die "--keep-settings needs an existing site at $SITE_ROOT and a files restore"
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
OLD_ROOT="$SITE_ROOT.before-restore-$STAMP"
NEW_ROOT="$SITE_ROOT.restore-$STAMP"
ORIG_ROOT="$(sed -n 's/^site_root=//p' "$SRC/INFO.txt")"

echo
echo "Restoring backup: $NAME"
sed 's/^/    /' "$SRC/INFO.txt"
echo "Target: $SITE_ROOT"
if (( DO_FILES )); then
  if (( SITE_EXISTS )); then
    echo "  - files: $SITE_ROOT will be replaced (current tree -> $OLD_ROOT)"
  else
    echo "  - files: $SITE_ROOT will be created"
  fi
  (( KEEP_SETTINGS )) && echo "    current settings*.php / services.yml are kept"
fi
(( DO_DB )) && echo "  - database: will be OVERWRITTEN (database configured in settings.php)"
if (( ! ASSUME_YES )); then
  read -r -p "Type 'yes' to confirm: " answer
  [[ "$answer" == "yes" ]] || die "restore cancelled"
fi

log "=== Restoring $NAME into $SITE_ROOT ==="

# --- Safety dump of the current database ------------------------------------
if (( DO_DB && SITE_EXISTS )); then
  SAFETY="$BACKUP_DIR/before-restore-$STAMP.sql.gz"
  log "Safety dump of the current database -> $SAFETY"
  if drush sql:dump --extra-dump="--no-tablespaces" 2>/dev/null | gzip >"$SAFETY" && gzip -t "$SAFETY"; then
    :
  else
    warn "safety dump not possible (empty or unreachable database?)"
    rm -f "$SAFETY"
  fi
fi

# --- Files -------------------------------------------------------------------
if (( DO_FILES )); then
  log "Extracting files into $NEW_ROOT..."
  mkdir -p "$NEW_ROOT"
  # Remove the partial tree on any failure (sites/default is read-only, hence chmod).
  trap 'chmod -R u+w "$NEW_ROOT" 2>/dev/null; rm -rf "$NEW_ROOT"' EXIT
  tar_opts=(-xzf "$SRC/files.tar.gz" -C "$NEW_ROOT")
  (( EUID == 0 )) && tar_opts+=(--same-owner --same-permissions)
  tar "${tar_opts[@]}" || die "extraction failed, current site unchanged"

  if (( KEEP_SETTINGS )); then
    old_doc="$(docroot_of "$SITE_ROOT")"
    new_doc="$(docroot_of "$NEW_ROOT")"
    while IFS= read -r -d '' f; do
      rel="${f#"$old_doc"/}"
      dir="$(dirname "$new_doc/$rel")"
      mkdir -p "$dir"
      mode="$(stat -c %a "$dir")"
      chmod u+w "$dir"
      rm -f "$new_doc/$rel"
      cp -p "$f" "$new_doc/$rel"
      chmod "$mode" "$dir"
      log "Kept current $rel"
    done < <(find "$old_doc/sites" -mindepth 2 -maxdepth 2 \
               \( -name 'settings*.php' -o -name 'services.yml' \) -print0)
  fi

  if [[ -n "$RESTORE_OWNER" ]]; then
    (( EUID == 0 )) || die "RESTORE_OWNER requires running as root"
    log "Setting owner $RESTORE_OWNER"
    chown -R "$RESTORE_OWNER" "$NEW_ROOT"
  elif (( SITE_EXISTS && EUID == 0 )); then
    chown --reference="$SITE_ROOT" "$NEW_ROOT"
  fi
  (( SITE_EXISTS )) && chmod --reference="$SITE_ROOT" "$NEW_ROOT"

  if (( SITE_EXISTS )); then
    drush state:set system.maintenance_mode 1 --input-format=integer >/dev/null 2>&1 || true
    log "Switching: $SITE_ROOT -> $OLD_ROOT"
    mv "$SITE_ROOT" "$OLD_ROOT"
  else
    mkdir -p "$(dirname "$SITE_ROOT")"
  fi
  mv "$NEW_ROOT" "$SITE_ROOT"
  trap - EXIT
  log "Files restored in $SITE_ROOT"

  # Absolute paths of the source server left in settings.php (file_private_path, ...).
  if [[ -n "$ORIG_ROOT" && "$ORIG_ROOT" != "$SITE_ROOT" ]] && (( ! KEEP_SETTINGS )); then
    hits="$(grep -HnF "$ORIG_ROOT" "$(docroot_of "$SITE_ROOT")"/sites/*/settings*.php 2>/dev/null | grep -vE ':[0-9]+:\s*(#|\*|//)' || true)"
    if [[ -n "$hits" ]]; then
      warn "settings.php still references the source path $ORIG_ROOT, adjust these lines:"
      echo "$hits" | sed 's/^/    /' >&2
    fi
  fi
fi

# --- Database ----------------------------------------------------------------
if (( DO_DB )); then
  drush sql:query 'SELECT 1' >/dev/null 2>&1 \
    || die "cannot connect to the database configured in settings.php. Create the database and user, fix settings.php (or use --keep-settings), then run again with --db-only."
  drush state:set system.maintenance_mode 1 --input-format=integer >/dev/null 2>&1 || true
  log "Dropping current tables..."
  drush sql:drop -y
  log "Importing database..."
  gzip -dc "$SRC/database.sql.gz" | drush sql:cli
fi

# --- Finalisation ------------------------------------------------------------
if (( DO_DB || SITE_EXISTS )); then
  log "Rebuilding caches..."
  if drush cache:rebuild; then
    (( UPDB )) && drush updatedb -y
    drush state:set system.maintenance_mode 0 --input-format=integer
    drush status --fields=drupal-version,db-status,bootstrap
  else
    warn "Drupal could not bootstrap: check settings.php and the database, then run: drush cr"
  fi
else
  log "Files only on a new server: check settings.php (database, paths), then run:"
  log "  $0 -c $CONFIG_FILE --db-only $NAME"
fi

log "Restore complete."
(( DO_FILES && SITE_EXISTS )) && log "Previous tree kept: $OLD_ROOT (remove it once the site is checked: chmod -R u+w, then rm -rf)"
(( DO_DB )) && [[ -f "${SAFETY:-}" ]] && log "Previous database dump: $SAFETY"
exit 0
