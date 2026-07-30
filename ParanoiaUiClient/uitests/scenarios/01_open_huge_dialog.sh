#!/usr/bin/env bash
# 01 — Вход в ОГРОМНЫЙ диалог: главный тест dead-фриза (appendMessages O(N²)).
# Ожидание: открылся быстро, БЕЗ столла GUI-потока, шапка = имя диалога.
SCENARIO_NAME="01 open huge dialog"
scenario() {
  mark "open_huge_dialog"
  app_open_dialog "$UITEST_DIALOG" || { fail "открытие диалога"; return; }
  sleep 3                                  # дать осесть загрузке истории
  drv_shot "$UITEST_OUT/01_open.png"
  assert_no_stall "вход в огромный диалог"
  assert_in_dialog
  app_back
}
