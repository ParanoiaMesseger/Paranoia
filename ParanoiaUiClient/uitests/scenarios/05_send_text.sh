#!/usr/bin/env bash
# 05 — Отправка текста (оптимистичное → committed, дедуп). ⚠️ В «Избранное»
# (self), НЕ в боевой канал Иванова. Ожидание: сообщение появляется (OCR),
# без столла, без дубля (оптимистичная схлопывается с committed —
# pendingTextToIndex-путь фикса appendMessages).
SCENARIO_NAME="05 send text (Избранное)"
scenario() {
  app_open_dialog "$UITEST_SEND_DIALOG" || { fail "открытие Избранного"; return; }
  sleep 1
  local digits; digits="$(date +%H%M%S)"
  local token="UITEST-$digits"
  mark "send_text"
  read -r ix iy <<<"$CHAT_INPUT"
  drv_tap "$ix" "$iy" 0.5
  drv_type "$token"
  drv_tap $CHAT_SEND 2.5
  drv_shot "$UITEST_OUT/05_send_text.png"
  assert_no_stall "отправка текста"
  # Ассерт по ЦИФРАМ токена: латиницу «UITEST» tesseract под rus+eng читает как
  # «ПТЕЗТ», а цифры времени — надёжно. Цифры уникальны в пределах прогона.
  assert_text 20 470 410 300 "$digits" "отправленный текст виден (токен $token)"
  app_back
}
