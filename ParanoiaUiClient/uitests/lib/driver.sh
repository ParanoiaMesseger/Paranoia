#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# driver.sh — низкоуровневый драйв X-окна клиента: поиск окна, тапы, свайпы,
# ввод текста, скриншоты. Все клики принимают WINDOW-RELATIVE координаты и
# добавляют смещение окна (окно можно двигать — тесты не поплывут).
# ─────────────────────────────────────────────────────────────────────────────
export DISPLAY="$UITEST_DISPLAY"

# Геометрия главного окна: "WIN X Y W H". Кэш в переменных WIN_*.
drv_find_window() {
  local w
  for w in $(xdotool search --name "$UITEST_WIN_NAME" 2>/dev/null); do
    eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)"
    if [ "${WIDTH:-0}" -ge "$UITEST_WIN_MINW" ] 2>/dev/null; then
      WIN_ID="$w"; WIN_X="$X"; WIN_Y="$Y"; WIN_W="$WIDTH"; WIN_H="$HEIGHT"
      return 0
    fi
  done
  return 1
}

# Ждать появления окна (сек).
drv_wait_window() {
  local deadline=$(( SECONDS + ${1:-20} ))
  while [ $SECONDS -lt $deadline ]; do drv_find_window && return 0; sleep 0.5; done
  return 1
}

# Абсолютные экранные координаты из window-relative.
_drv_abs() { echo "$(( WIN_X + $1 )) $(( WIN_Y + $2 ))"; }

# Тап по window-relative (x y) с паузой после.
drv_tap() {
  drv_find_window || return 1
  read -r ax ay <<<"$(_drv_abs "$1" "$2")"
  xdotool mousemove "$ax" "$ay" click 1
  sleep "${3:-0.4}"
}

# Свайп window-relative (x1 y1 x2 y2 [ms]).
drv_swipe() {
  drv_find_window || return 1
  read -r ax1 ay1 <<<"$(_drv_abs "$1" "$2")"
  read -r ax2 ay2 <<<"$(_drv_abs "$3" "$4")"
  local ms="${5:-180}"
  xdotool mousemove "$ax1" "$ay1" mousedown 1
  # плавно, чтобы Flickable распознал жест, а не клик
  local steps=12 i
  for ((i=1;i<=steps;i++)); do
    xdotool mousemove $(( ax1 + (ax2-ax1)*i/steps )) $(( ay1 + (ay2-ay1)*i/steps ))
    sleep "$(awk "BEGIN{print $ms/1000/$steps}")"
  done
  xdotool mouseup 1
  sleep 0.3
}

# Ввод текста в сфокусированное поле.
drv_type() { xdotool type --delay 25 "$1"; sleep 0.3; }

# Скрин окна → PNG. Аргумент: путь.
drv_shot() {
  drv_find_window || return 1
  xwd -root -silent -out /tmp/_uitest_root.xwd 2>/dev/null
  ffmpeg -y -loglevel error -i /tmp/_uitest_root.xwd \
    -vf "crop=${WIN_W}:${WIN_H}:${WIN_X}:${WIN_Y}" "$1" 2>/dev/null
}

# Скрин ПРЯМОУГОЛЬНИКА окна (x y w h) → PNG. Для OCR-кропа строки/шапки.
drv_shot_region() {
  drv_find_window || return 1
  local rx="$1" ry="$2" rw="$3" rh="$4" out="$5"
  xwd -root -silent -out /tmp/_uitest_root.xwd 2>/dev/null
  ffmpeg -y -loglevel error -i /tmp/_uitest_root.xwd \
    -vf "crop=${rw}:${rh}:$(( WIN_X + rx )):$(( WIN_Y + ry ))" "$out" 2>/dev/null
}
