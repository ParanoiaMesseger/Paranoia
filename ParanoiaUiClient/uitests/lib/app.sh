#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# app.sh — жизненный цикл и навигация: запуск (с профайлинг-сторожем), убийство,
# разблокировка PIN, выбор профиля (OCR — устойчиво к смене порядка строк),
# открытие диалога (OCR), назад. Держит PID в APP_PID.
# ─────────────────────────────────────────────────────────────────────────────

# Запуск клиента с включённым сторожем GUI-потока (детектор фризов).
app_launch() {
  : >"$UITEST_LOG"
  ( cd "$(dirname "$UITEST_APP_BIN")" && \
    DISPLAY="$UITEST_DISPLAY" QT_QPA_PLATFORM=xcb \
    PARANOIA_PROFILE=1 PARANOIA_PROFILE_STALL_MS="$UITEST_STALL_MS" \
    nohup "$UITEST_APP_BIN" >>"$UITEST_LOG" 2>&1 & echo $! >/tmp/_uitest_pid )
  APP_PID="$(cat /tmp/_uitest_pid)"
  drv_wait_window 25 || { echo "  !! окно не появилось"; return 1; }
  sleep 2
  echo "  app launched pid=$APP_PID win=$WIN_ID"
}

# Аккуратно завершить. По явному PID + добить по ТОЧНОМУ ИМЕНИ процесса
# (pkill -x Paranoia — матчит comm=="Paranoia", НЕ cmdline; свой bash-шелл не заденет,
# в отличие от pkill -f build_client/Paranoia → exit 144). Клиент single-instance:
# без полного добивания relaunch переактивирует старое окно (тот же win-id).
app_kill() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
  sleep 1
  pkill -x -9 Paranoia 2>/dev/null
  [ -n "${APP_PID:-}" ] && kill -9 "$APP_PID" 2>/dev/null
  sleep 1.5
}

# Ввести PIN и разблокировать.
app_unlock() {
  local pin="${1:-$UITEST_PIN}" d
  for (( i=0; i<${#pin}; i++ )); do
    d="${pin:$i:1}"; drv_tap ${PIN_KEY[$d]} 0.35
  done
  drv_tap $PIN_UNLOCK 2.5
}

# Выбрать профиль по имени (OCR строк попапа — порядок строк варьируется!).
# ⚠️ БЕЗ Escape: клиент трактует «назад» с КОРНЯ (списка) как moveTaskToBack →
# окно СВЕРНУЛОСЬ бы, ломая всё дальше. Вызывать из списка диалогов.
app_select_profile() {
  local name="${1:-$UITEST_PROFILE}"
  drv_tap $SW_TOGGLE 1.3
  read -r sx ex <<<"$SW_ROW_X"
  local y
  if ! y="$(ocr_find_row_y "$name" "$sx" "$(( ex - sx ))" $SW_ROWS_Y)"; then
    echo "  !! профиль «$name» не найден в попапе"
    drv_shot "$UITEST_OUT/dbg_switcher_miss.png"
    return 1
  fi
  drv_tap $(( (sx+ex)/2 )) "$y" 3
  echo "  profile → $name (row y=$y)"
}

# Открыть диалог по подстроке имени (OCR строк списка). С верификацией входа:
# после тапа шапка НЕ должна быть логотипом списка «PARANOIA» (иначе тап промахнулся
# по осевшему списку — ретрай). Список re-сортится по свежести → y плавает, потому OCR.
app_open_dialog() {
  local name="${1:-$UITEST_DIALOG}"
  read -r sx ex <<<"$DLG_ROW_X"
  read -r hx hy hw hh <<<"$CHAT_HEADER_REGION"
  local y attempt
  for attempt in 1 2 3; do
    if ! y="$(ocr_find_row_y "$name" "$sx" "$(( ex - sx ))" $DLG_ROWS_Y)"; then
      sleep 1; continue
    fi
    drv_tap $(( (sx+ex)/2 )) "$y" 2.5
    if ! ocr_region_has "$hx" "$hy" "$hw" "$hh" "PARANO"; then
      echo "  dialog → $name (row y=$y, try $attempt)"; return 0
    fi
    sleep 1   # ещё в списке — тап осевшего ряда промахнулся, повторить
  done
  echo "  !! диалог «$name» не открылся (3 попытки)"; return 1
}

# Назад из чата в список. Escape маппится на back-хендлер приложения надёжнее,
# чем тап по мелкой стрелке «‹» (её x/y плавали). Проверено: чат → список.
app_back() { xdotool key Escape; sleep 1.5; }

# Отправить ОДНО фото: «+» → «Фото» → файловый диалог (ввод пути) → Enter → Send.
# Флоу выверен вживую: пикер «Фото» — single-file, путь вводится в поле «Имя файла».
app_send_one_photo() {
  local path="$1"
  local dlg="" w DW DH DX DY menutry
  # до 2 попыток раскрыть «+»→«Фото» и дождаться файлового диалога (тап меню флакает)
  for menutry in 1 2; do
    drv_tap $CHAT_ATTACH 1.0
    drv_tap $ATTACH_MENU_PHOTO 1.8
    local deadline=$(( SECONDS + 6 ))
    while [ $SECONDS -lt $deadline ] && [ -z "$dlg" ]; do
      for w in $(xdotool search --name "$FILEDLG_NAME" 2>/dev/null); do
        eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)"
        if [ "${WIDTH:-0}" -ge 700 ]; then dlg="$w"; DW="$WIDTH"; DH="$HEIGHT"; DX="$X"; DY="$Y"; break; fi
      done
      [ -z "$dlg" ] && sleep 0.4
    done
    [ -n "$dlg" ] && break
  done
  [ -z "$dlg" ] && { echo "  !! файловый диалог не открылся"; return 1; }
  local fx fy
  fx=$(awk "BEGIN{print int($DX + $DW*$FILEDLG_FIELD_RX)}")
  fy=$(awk "BEGIN{print int($DY + $DH*$FILEDLG_FIELD_RY)}")
  xdotool mousemove "$fx" "$fy" click 1; sleep 0.4
  xdotool type --delay 12 "$path"; sleep 0.3
  xdotool key Return; sleep 2
  drv_tap $CHAT_SEND 3
}

# Полный вход: unlock → профиль → (в списке).
app_enter() {
  app_unlock
  # если уже нужный профиль — переключение не навредит; но проверим наличие цели
  app_select_profile "$UITEST_PROFILE" || true
}
