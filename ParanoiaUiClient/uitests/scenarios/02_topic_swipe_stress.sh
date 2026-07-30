#!/usr/bin/env bash
# 02 — Стресс свайпа тем на огромном диалоге: быстрые перелистывания ленты
# влево/вправо (переход к соседней теме). Ожидание: ни одного столла GUI-потока
# (репро Иванова «свайп с Главной на вкладку на непрогруженном диалоге»).
SCENARIO_NAME="02 topic swipe stress"
scenario() {
  app_open_dialog "$UITEST_DIALOG" || { fail "открытие диалога"; return; }
  sleep 1                                  # НАМЕРЕННО свайпаем «на непрогруженном»
  mark "topic_swipe"
  read -r cx cy <<<"$CHAT_MSG_AREA"
  local i
  for i in $(seq 1 10); do
    if (( i % 2 )); then drv_swipe $(( cx+140 )) "$cy" $(( cx-140 )) "$cy" 140   # влево → след. тема
    else                drv_swipe $(( cx-140 )) "$cy" $(( cx+140 )) "$cy" 140 ; fi # вправо → пред.
  done
  sleep 2
  drv_shot "$UITEST_OUT/02_swipe.png"
  assert_no_stall "стресс свайпа тем (10x на непрогруженном)"
  app_back
}
