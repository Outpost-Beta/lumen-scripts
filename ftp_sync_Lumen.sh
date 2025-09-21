#!/usr/bin/env bash
set -euo pipefail

REMOTE="Lumen:/public_html/Lumen"
LOCAL="/home/admin/Lumen"
LOG="/home/admin/Lumen_sync.log"

/usr/bin/rclone sync "$REMOTE" "$LOCAL" \
  --progress \
  --create-empty-src-dirs \
  --copy-links \
  --transfers 4 \
  --checkers 8 \
  --retries 5 \
  --low-level-retries 10 \
  --log-file "$LOG" \
  --log-level INFO
