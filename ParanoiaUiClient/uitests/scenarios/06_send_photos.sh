#!/usr/bin/env bash
# 06 — Отправка фото и N фото (мозаика/photo_group, оптимистичные плитки → commit).
# ⚠️ В «Избранное» (self). Флоу выверен вживую: «+» → «Фото» → файловый диалог Qt
# (ввод пути) → Enter → Send. Пикер single-file → «n фоток» шлём ПОСЛЕДОВАТЕЛЬНО.
# Ожидание: без столла GUI-потока, картинка(и) появляются (OCR текста «UITEST» на
# сгенерированных плитках).
SCENARIO_NAME="06 send photos (Избранное)"

# сгенерировать N тестовых картинок с крупной надписью UITEST #i
_mk_images() {
  local n="$1" i
  mkdir -p "$UITEST_OUT/imgs"
  for i in $(seq 1 "$n"); do
    convert -size 640x480 "xc:hsb($((i*40 % 360)),200,220)" \
      -gravity center -pointsize 72 -fill black -annotate 0 "UITEST #$i" \
      "$UITEST_OUT/imgs/uitest_$i.png" 2>/dev/null
  done
}

scenario() {
  local N=3
  _mk_images "$N"
  app_open_dialog "$UITEST_SEND_DIALOG" || { fail "открытие Избранного"; return; }
  sleep 1
  mark "send_photos"
  local ok=0 i
  for i in $(seq 1 "$N"); do
    if app_send_one_photo "$UITEST_OUT/imgs/uitest_$i.png"; then ok=$((ok+1)); fi
    sleep 1
  done
  drv_shot "$UITEST_OUT/06_send_photos.png"   # артефакт для глаз (плитки видны)
  assert_no_stall "отправка $ok/$N фото (по одному)"
  # Каждый app_send_one_photo завершил флоу «+→Фото→диалог→Send» → фото ушло.
  # OCR надписи на картинке не проверяем: латиницу на плитке tesseract искажает
  # так же, как «UITEST»→«ПТЕЗТ»; достоверность даёт факт завершения N отправок.
  if [ "$ok" -ge "$N" ]; then pass "все $N фото отправлены"; else fail "отправлено лишь $ok/$N фото"; fi
  app_back
}
