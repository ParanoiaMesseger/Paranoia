#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ocr.sh — распознавание текста в области окна (tesseract eng+rus). Даёт
# СОДЕРЖАТЕЛЬНЫЕ проверки: имя открытого диалога, имя профиля, наличие текста
# сообщения — а не только «не зафризило». Устойчиво к смене порядка строк.
# ─────────────────────────────────────────────────────────────────────────────

# OCR прямоугольника окна (x y w h) → строка текста (в одну строку, схлопнуты пробелы).
ocr_region() {
  local rx="$1" ry="$2" rw="$3" rh="$4"
  local png="/tmp/_uitest_ocr.png"
  drv_shot_region "$rx" "$ry" "$rw" "$rh" "$png" || return 1
  # апскейл ×3 + грейскейл — заметно поднимает точность на мелком UI-шрифте
  convert "$png" -colorspace Gray -resize 300% -normalize "/tmp/_uitest_ocr2.png" 2>/dev/null
  tesseract "/tmp/_uitest_ocr2.png" stdout -l rus+eng --psm 6 2>/dev/null \
    | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//'
}

# Есть ли подстрока (без учёта регистра) в OCR области?
ocr_region_has() {
  local rx="$1" ry="$2" rw="$3" rh="$4" needle="$5"
  local txt; txt="$(ocr_region "$rx" "$ry" "$rw" "$rh")"
  echo "$txt" | grep -qiF -- "$needle"
}

# Найти в списке строк (по их y-центрам) ПЕРВУЮ, чей OCR содержит needle.
# Args: needle  x  w  "y1 y2 y3..."   → echo y-центр найденной строки (или пусто).
ocr_find_row_y() {
  local needle="$1" rx="$2" rw="$3"; shift 3
  local ys="$*" y txt
  for y in $ys; do
    txt="$(ocr_region "$rx" "$(( y - 22 ))" "$rw" 44)"
    if echo "$txt" | grep -qiF -- "$needle"; then echo "$y"; return 0; fi
  done
  return 1
}
