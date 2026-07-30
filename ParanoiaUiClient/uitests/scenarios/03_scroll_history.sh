#!/usr/bin/env bash
# 03 — Прокрутка вглубь истории (инверт-лента, ленивая инкубация делегатов +
# догрузка окна). Ожидание: без столла GUI-потока при активной прокрутке тяжёлых
# markdown/фото-делегатов.
SCENARIO_NAME="03 scroll history"
scenario() {
  app_open_dialog "$UITEST_DIALOG" || { fail "открытие диалога"; return; }
  sleep 3
  mark "scroll_history"
  read -r cx cy <<<"$CHAT_MSG_AREA"
  local i
  for i in $(seq 1 8); do                 # вверх = к более старым (drag сверху вниз в инверт-ленте)
    drv_swipe "$cx" $(( cy-160 )) "$cx" $(( cy+180 )) 160
  done
  sleep 1
  for i in $(seq 1 6); do drv_swipe "$cx" $(( cy+160 )) "$cx" $(( cy-180 )) 160; done  # обратно к низу
  sleep 2
  drv_shot "$UITEST_OUT/03_scroll.png"
  assert_no_stall "прокрутка истории вверх/вниз"
  app_back
}
