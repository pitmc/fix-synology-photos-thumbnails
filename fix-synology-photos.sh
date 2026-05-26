#!/bin/sh
# Synology Photos Thumbnail Fix
# Fixes: thumbnails not showing, empty folders, video conversion loop
# Tested on: DSM 7.x, Synology Photos 1.9.x
# WARNING: This script modifies Synology Photos database and cache files.
#          Original photos/videos are NEVER touched.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { printf "${CYAN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_ok() { printf "${GREEN}[ OK ]${NC} %s\n" "$1"; }
log_err() { printf "${RED}[ERR ]${NC} %s\n" "$1"; }

confirm() {
  printf "${YELLOW}>> %s [y/N]: ${NC}" "$1"
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    log_info "Run: sudo sh fix-synology-photos.sh"
    exit 1
  fi
}

check_package_installed() {
  if ! synopkg status SynologyPhotos > /dev/null 2>&1; then
    log_err "Synology Photos package not found."
    exit 1
  fi
}

get_photo_paths() {
  PHOTO_SHARED="/volume1/photo"
  PHOTO_HOMES="/volume1/homes"

  if [ ! -d "$PHOTO_SHARED" ]; then
    log_warn "$PHOTO_SHARED not found. Checking alternate paths..."
    PHOTO_SHARED=""
  fi

  if [ ! -d "$PHOTO_HOMES" ]; then
    log_warn "$PHOTO_HOMES not found."
    PHOTO_HOMES=""
  fi
}

run_psql() {
  su - postgres -s /bin/sh -c "psql -d synofoto -t -A -c \"$1\"" 2>/dev/null
}

show_status() {
  log_info "Current status:"
  UNITS=$(run_psql "SELECT COUNT(*) FROM unit;")
  THUMBS=$(run_psql "SELECT COUNT(*) FROM thumbnail;")
  QUEUE=$(run_psql "SELECT COUNT(*) FROM index_queue;")
  printf "  Units in DB:     %s\n" "$UNITS"
  printf "  Thumbnails:      %s\n" "$THUMBS"
  printf "  Index queue:     %s\n" "$QUEUE"
  echo ""
}

step_stop_photos() {
  log_info "Step 1: Stopping Synology Photos..."
  STATUS=$(synopkg status SynologyPhotos 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)
  if echo "$STATUS" | grep -q "running"; then
    synopkg stop SynologyPhotos > /dev/null 2>&1
    log_ok "Synology Photos stopped."
  else
    log_ok "Synology Photos already stopped."
  fi
}

step_delete_film_files() {
  log_info "Step 2: Deleting video conversion files (SYNOPHOTO_FILM)..."
  log_info "These are transcoded video copies, not originals."
  echo ""
  log_info "To monitor in another terminal:"
  printf "  ${CYAN}ps aux | grep \"find.*SYNOPHOTO\" | grep -v grep${NC}\n"
  echo ""

  if [ -n "$PHOTO_SHARED" ]; then
    find "$PHOTO_SHARED" -name "SYNOPHOTO_FILM_H.mp4" -exec rm -rf {} + 2>/dev/null || true
    find "$PHOTO_SHARED" -name "SYNOPHOTO_FILM.fail" -exec rm -rf {} + 2>/dev/null || true
  fi

  if [ -n "$PHOTO_HOMES" ]; then
    find "$PHOTO_HOMES" -name "SYNOPHOTO_FILM_H.mp4" -exec rm -rf {} + 2>/dev/null || true
    find "$PHOTO_HOMES" -name "SYNOPHOTO_FILM.fail" -exec rm -rf {} + 2>/dev/null || true
  fi

  log_ok "Video conversion files deleted."
}

step_delete_eadir() {
  log_info "Step 3: Deleting all @eaDir directories (thumbnail/metadata cache)..."
  log_warn "This forces full thumbnail regeneration. May take 30-60 min on large libraries."
  log_info "@eaDir NEVER contains original photos — only cache data."
  echo ""
  log_info "To monitor progress in another terminal:"
  printf "  ${CYAN}ps aux | grep \"find.*eaDir\\|rm.*eaDir\" | grep -v grep | cut -c1-120${NC}\n"
  log_info "When no output appears, it finished."
  echo ""

  if [ -n "$PHOTO_SHARED" ]; then
    log_info "Cleaning $PHOTO_SHARED ..."
    find "$PHOTO_SHARED" -name "@eaDir" -type d -exec rm -rf {} + 2>/dev/null || true
  fi

  if [ -n "$PHOTO_HOMES" ]; then
    log_info "Cleaning $PHOTO_HOMES ..."
    find "$PHOTO_HOMES" -name "@eaDir" -type d -exec rm -rf {} + 2>/dev/null || true
  fi

  log_ok "@eaDir directories deleted."
}

step_clean_db() {
  log_info "Step 4: Cleaning database tables..."

  run_psql "TRUNCATE thumbnail;" > /dev/null
  run_psql "TRUNCATE thumbnail_version;" > /dev/null
  run_psql "TRUNCATE thumb_preview;" > /dev/null
  run_psql "TRUNCATE convert_thumbnail_allocation;" > /dev/null
  run_psql "TRUNCATE video_convert;" > /dev/null

  log_ok "Database tables cleaned."
}

step_reset_index_stage() {
  log_info "Step 5: Resetting index_stage to force thumbnail regeneration..."
  log_warn "This updates ~250k+ rows. May take 5-10 minutes. Do not interrupt."
  echo ""
  log_info "To verify progress in another terminal:"
  printf "  ${CYAN}sudo -u postgres psql -d synofoto -c \"SELECT index_stage, COUNT(*) FROM unit GROUP BY index_stage;\"${NC}\n"
  log_info "When index_stage 79/127/255 disappear and 71 grows, it's working."
  echo ""

  UPDATED=$(run_psql "UPDATE unit SET index_stage = 71 WHERE index_stage IN (79, 127, 255); SELECT COUNT(*) FROM unit WHERE index_stage = 71;")
  log_ok "Index stage reset complete. Units pending: $UPDATED"
}

step_start_photos() {
  log_info "Step 6: Starting Synology Photos..."
  synopkg start SynologyPhotos > /dev/null 2>&1
  log_ok "Synology Photos started."
  echo ""
  log_info "Now trigger reindex from the web UI:"
  log_info "  Photos -> Settings -> Reindex (both personal + shared space)"
}

step_delete_zero_byte() {
  log_info "Step 7 (optional): Deleting 0-byte files..."

  ZERO_COUNT=0
  if [ -n "$PHOTO_SHARED" ]; then
    COUNT=$(find "$PHOTO_SHARED" -type f -size 0 -not -path "*@eaDir*" -not -path "*#recycle*" 2>/dev/null | wc -l)
    ZERO_COUNT=$((ZERO_COUNT + COUNT))
  fi
  if [ -n "$PHOTO_HOMES" ]; then
    COUNT=$(find "$PHOTO_HOMES" -path "*/Photos/*" -type f -size 0 -not -path "*@eaDir*" -not -path "*#recycle*" 2>/dev/null | wc -l)
    ZERO_COUNT=$((ZERO_COUNT + COUNT))
  fi

  if [ "$ZERO_COUNT" -eq 0 ]; then
    log_ok "No 0-byte files found."
    return
  fi

  log_warn "Found $ZERO_COUNT files with 0 bytes (corrupted/incomplete transfers)."
  if confirm "Delete them?"; then
    if [ -n "$PHOTO_SHARED" ]; then
      find "$PHOTO_SHARED" -type f -size 0 -not -path "*@eaDir*" -not -path "*#recycle*" -delete 2>/dev/null || true
    fi
    if [ -n "$PHOTO_HOMES" ]; then
      find "$PHOTO_HOMES" -path "*/Photos/*" -type f -size 0 -not -path "*@eaDir*" -not -path "*#recycle*" -delete 2>/dev/null || true
    fi
    log_ok "0-byte files deleted."
  else
    log_info "Skipped."
  fi
}

show_monitoring() {
  echo ""
  echo "========================================"
  log_info "REGENERATION IN PROGRESS"
  echo "========================================"
  echo ""
  log_info "Thumbnail generation will take 12-48 hours depending on library size."
  log_info "CPU will run at ~99% during this time. This is normal."
  echo ""
  log_info "Monitor thumbnail progress (thumbnails should grow, queue should drain to 0):"
  printf "  ${CYAN}sudo -u postgres psql -d synofoto -c \"SELECT (SELECT COUNT(*) FROM thumbnail) as thumbnails, (SELECT COUNT(*) FROM index_queue) as queue;\"${NC}\n"
  echo ""
  log_info "Monitor queue breakdown by type:"
  printf "  ${CYAN}sudo -u postgres psql -d synofoto -c \"SELECT type, COUNT(*) FROM index_queue GROUP BY type;\"${NC}\n"
  log_info "  type 0 = metadata, type 2/3 = thumbnails. Metadata processes first."
  echo ""
  log_info "Check logs for errors:"
  printf "  ${CYAN}sudo tail -20 /var/packages/SynologyPhotos/var/log/synofoto.log${NC}\n"
  echo ""
  log_info "Validate filesystem vs DB when done (excludes @eaDir and #recycle):"
  printf "  ${CYAN}find /volume1/photo -type f -not -path \"*@eaDir*\" -not -path \"*#recycle*\" | wc -l${NC}\n"
  printf "  ${CYAN}find /volume1/homes -path \"*/Photos/*\" -type f -not -path \"*@eaDir*\" -not -path \"*#recycle*\" | wc -l${NC}\n"
  printf "  ${CYAN}sudo -u postgres psql -d synofoto -c \"SELECT COUNT(*) FROM unit;\"${NC}\n"
  log_info "  FS total will be slightly higher than DB (THM, WAV, LRV, PDF not indexed)."
  echo ""
  log_warn "DO NOT press 'Generate AVC previews' in Photos UI — it causes the video loop."
  echo ""
}

# ============================================================
# MAIN
# ============================================================

echo ""
echo "========================================"
echo "  Synology Photos Thumbnail Fix"
echo "========================================"
echo ""
log_warn "This script will:"
echo "  1. Stop Synology Photos"
echo "  2. Delete video conversion files (not originals)"
echo "  3. Delete @eaDir cache directories (not originals)"
echo "  4. Clean thumbnail database tables"
echo "  5. Reset index stage to force regeneration"
echo "  6. Start Photos (you trigger reindex manually)"
echo "  7. Optionally delete 0-byte corrupted files"
echo ""
log_warn "Original photos and videos are NEVER modified or deleted."
log_warn "Albums, shares, and user configuration are preserved."
echo ""

check_root
check_package_installed
get_photo_paths

show_status

if ! confirm "Proceed with the fix?"; then
  log_info "Aborted."
  exit 0
fi

echo ""
step_stop_photos
echo ""

if confirm "Delete video conversion files? (fixes video loop)"; then
  step_delete_film_files
else
  log_info "Skipped step 2."
fi
echo ""

if confirm "Delete all @eaDir? (forces full thumbnail regeneration)"; then
  step_delete_eadir
else
  log_info "Skipped step 3."
fi
echo ""

if confirm "Clean database thumbnail tables?"; then
  step_clean_db
else
  log_info "Skipped step 4."
fi
echo ""

if confirm "Reset index_stage? (forces re-processing, takes several minutes)"; then
  step_reset_index_stage
else
  log_info "Skipped step 5."
fi
echo ""

step_start_photos
echo ""

step_delete_zero_byte
echo ""

show_monitoring
log_ok "Fix complete. Thumbnails will regenerate in background."
echo ""
