#!/usr/bin/env bash
# Stage pricing CSVs + app source into the bundle so `databricks bundle deploy`
# can sync them. Idempotent, non-interactive — safe to run in Jenkins.
#
# This is the staging half of scripts/install.sh, split out so CI can stage,
# then run `databricks bundle validate/deploy/run` itself (with honest exit codes).
#
# Requires: bash, python3, rsync.  Run from anywhere; paths are resolved absolute.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Pricing data (CSVs only; split anything > 9MB for the workspace import limit) ──
PRICING_SRC="$REPO_ROOT/backend/static/pricing"
PRICING_DST="$SCRIPT_DIR/pricing_data"
MAX_FILE_SIZE=$((9 * 1024 * 1024))
rm -rf "$PRICING_DST"
mkdir -p "$PRICING_DST"
for csv_file in "$PRICING_SRC"/*.csv; do
    [ -f "$csv_file" ] || continue
    file_size=$(wc -c < "$csv_file" | xargs)
    if [ "$file_size" -le "$MAX_FILE_SIZE" ]; then
        cp "$csv_file" "$PRICING_DST/"
    else
        base_name=$(basename "$csv_file" .csv)
        echo "  splitting ${base_name}.csv ($(( file_size / 1024 / 1024 ))MB)..."
        python3 - "$csv_file" "$PRICING_DST" "$base_name" "$MAX_FILE_SIZE" <<'PY'
import csv, os, sys
src, dst_dir, stem, max_size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(src, 'r') as f:
    reader = csv.reader(f)
    header_line = ','.join(next(reader)) + '\n'
    part_num = 0
    current_size = max_size + 1
    out = None
    for row in reader:
        line = ','.join(row) + '\n'
        if current_size + len(line.encode()) > max_size:
            if out: out.close()
            part_num += 1
            out = open(os.path.join(dst_dir, f'{stem}_part{part_num}.csv'), 'w')
            out.write(header_line)
            current_size = len(header_line.encode())
        out.write(line)
        current_size += len(line.encode())
    if out: out.close()
    print(f'  split into {part_num} parts')
PY
    fi
done
echo "  pricing data: $(ls -1 "$PRICING_DST"/*.csv 2>/dev/null | wc -l | xargs) CSV files"

# ── App source (backend app + static assets, excluding CSVs) ──
APP_SRC_DST="$SCRIPT_DIR/app_source"
rm -rf "$APP_SRC_DST/backend"
mkdir -p "$APP_SRC_DST/backend"
rsync -a --exclude='__pycache__' --exclude='.pytest_cache' \
    "$REPO_ROOT/backend/app/" "$APP_SRC_DST/backend/app/"
rsync -a --exclude='*.csv' --exclude='manifest.json' \
    "$REPO_ROOT/backend/static/" "$APP_SRC_DST/backend/static/"
cp "$REPO_ROOT/requirements.txt" "$APP_SRC_DST/" 2>/dev/null || true
echo "  app source staged"
echo "Staging complete."
