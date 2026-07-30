#!/usr/bin/env bash
# 04 — «Убить приложение → зайти → снова открыть» (сценарий Иванова). Проверяет,
# что после холодного старта вход в огромный диалог по-прежнему без фриза и
# история на месте (кэш строится с нуля через appendMessages — самый нагруженный
# путь). Перезапускает клиент внутри сценария.
SCENARIO_NAME="04 kill relaunch reopen"
scenario() {
  app_kill
  app_launch || { fail "перезапуск клиента"; return; }
  app_unlock
  app_select_profile "$UITEST_PROFILE" || { fail "выбор профиля после рестарта"; return; }
  mark "reopen_after_kill"
  app_open_dialog "$UITEST_DIALOG" || { fail "открытие диалога после рестарта"; return; }
  sleep 3
  drv_shot "$UITEST_OUT/04_reopen.png"
  assert_no_stall "вход в диалог после холодного рестарта"
  assert_in_dialog
  app_back
}
