#!/bin/bash
set -e

INBOX="/data/inbox"
PHOTOS="/data/photos"
NFS="/data/nfs"
CONFIG_DIR="/config"
CONFIG_FILE="${CONFIG_DIR}/config.hjson"

POLL_INTERVAL="${POLL_INTERVAL:-60}"
# Files must be untouched for this many minutes before processing
STABLE_MINS="${STABLE_MINS:-1}"

IMAGE_PATTERNS=(-iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.arw" -o -iname "*.png" -o -iname "*.heif" -o -iname "*.mp4")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Notify Home Assistant (or any webhook) on fatal failure. Set NOTIFY_WEBHOOK_URL in env.
notify_failure() {
    local msg="$1"
    if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
        local json_msg; json_msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
        wget -q -O /dev/null --post-data="{\"title\":\"GPhotos\",\"message\":\"$json_msg\",\"source\":\"photo-processor\"}" \
            --header="Content-Type: application/json" \
            "$NOTIFY_WEBHOOK_URL" 2>/dev/null || true
    fi
}

if [ ! -f "$CONFIG_FILE" ]; then
    log "FATAL: config not found at $CONFIG_FILE — cannot upload to Google Photos"
    notify_failure "Photo processor failed: config not found at $CONFIG_FILE"
    exit 1
fi

log "Photo watcher starting"
log "  Inbox:   $INBOX"
log "  Photos:  $PHOTOS"
log "  NFS:     $NFS"
log "  Poll:    ${POLL_INTERVAL}s"
log "  Stable:  ${STABLE_MINS}m"

while true; do
    # Count image files that are old enough (upload finished)
    ready_count=$(find "$INBOX" -type f \( "${IMAGE_PATTERNS[@]}" \) -mmin +"$STABLE_MINS" 2>/dev/null | wc -l)

    # Check if any files are still being written (modified recently)
    uploading=$(find "$INBOX" -type f \( "${IMAGE_PATTERNS[@]}" \) -mmin -"$STABLE_MINS" 2>/dev/null | head -1)

    if [ "$ready_count" -gt 0 ] && [ -z "$uploading" ]; then
        log "Processing $ready_count file(s)..."

        # 0. Remove any existing file in photos/ with same name as an inbox file (retry/duplicate case)
        while IFS= read -r f; do
            base=$(basename "$f")
            find "$PHOTOS" -type f -name "$base" -delete 2>/dev/null || true
        done < <(find "$INBOX" -type f \( "${IMAGE_PATTERNS[@]}" \))

        # 1. Organize: move files into /data/photos/YYYY-MM-DD/ by EXIF date
        #    Fallback chain: DateTimeOriginal → CreateDate → FileModifyDate
        if ! exiftool -d "%Y-%m-%d" \
            "-directory<${PHOTOS}/\$FileModifyDate" \
            "-directory<${PHOTOS}/\$CreateDate" \
            "-directory<${PHOTOS}/\$DateTimeOriginal" \
            -r "$INBOX"; then
            log "WARN: exiftool reported errors (some files may have been skipped)"
        fi

        # 2. Upload to Google Photos (non-destructive; DeleteAfterUpload=false)
        gphotos_ok=false
        log "Uploading to Google Photos (config: $CONFIG_FILE)..."
        if gphotos-uploader-cli push --config "$CONFIG_DIR"; then
            gphotos_ok=true
        else
            notify_failure "WARN: Google Photos upload failed — files kept locally"
        fi

        # 3. Copy to NFS if the target is mounted (detected via marker file)
        nfs_ok=false
        if [ -f "$NFS/.mounted" ]; then
            log "NFS available — copying..."
            if rsync -a "$PHOTOS/" "$NFS/"; then
                nfs_ok=true
            else
                log "WARN: NFS copy failed — files kept locally"
            fi
        else
            log "NFS offline — files kept locally for next cycle"
        fi

        # 4. Delete from local ONLY when confirmed in BOTH destinations
        if [ "$gphotos_ok" = true ] && [ "$nfs_ok" = true ]; then
            deleted=0
            while IFS= read -r f; do
                rel="${f#$PHOTOS/}"
                if [ -f "$NFS/$rel" ]; then
                    rm "$f"
                    deleted=$((deleted + 1))
                fi
            done < <(find "$PHOTOS" -type f)
            find "$PHOTOS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
            log "Cleanup: removed $deleted file(s) confirmed on both Google Photos and NFS"
        else
            log "Skipping cleanup — files not yet in both destinations (gphotos=$gphotos_ok nfs=$nfs_ok)"
        fi

        # 5. Clean up empty dirs left by SFTPGo/exiftool in inbox
        find "$INBOX" -mindepth 1 -type d -empty -delete 2>/dev/null || true

        log "Cycle complete"
    elif [ -n "$uploading" ]; then
        log "Upload in progress — waiting for camera to finish"
        sleep 30
        continue
    fi

    sleep "$POLL_INTERVAL"
done
