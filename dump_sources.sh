#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-.}"
OUT_FILE="${2:-dump.txt}"

SRC_DIR_ABS="$(cd "$SRC_DIR" && pwd)"
OUT_FILE_ABS="$(cd "$(dirname "$OUT_FILE")" && pwd)/$(basename "$OUT_FILE")"

echo "Источник: $SRC_DIR_ABS"
echo "Вывод:    $OUT_FILE_ABS"

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

{
  echo "=== DUMP OF '$SRC_DIR_ABS' ==="
  echo
} > "$TMP_OUT"

EXCLUDES=(
  -name ".git" -prune -o
  -name "target" -prune -o
  -name "node_modules" -prune -o
  -name "dist" -prune -o
)

find "$SRC_DIR_ABS" \
  "${EXCLUDES[@]}" \
  -type f \
  ! -path "$OUT_FILE_ABS" \
  ! -name "Cargo.lock" \
  -print0 |
while IFS= read -r -d '' file; do
  rel_path="${file#$SRC_DIR_ABS/}"

  {
    echo "===== FILE: $rel_path ====="
    echo
    cat "$file"
    echo
    echo "===== END FILE: $rel_path ====="
    echo
  } >> "$TMP_OUT"
done

mv "$TMP_OUT" "$OUT_FILE_ABS"
echo "Готово: $OUT_FILE_ABS"
