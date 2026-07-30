#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run_all.sh — оркестратор стека UI-тестов десктоп-клиента Paranoia.
#   ./run_all.sh              — все сценарии
#   ./run_all.sh 02           — только сценарии, чьё имя матчит «02»
#   UITEST_KEEP=1 ./run_all.sh   — не убивать клиент в конце (для отладки)
#
# Каждый сценарий гоняется на клиенте, запущенном со сторожем GUI-потока
# (PARANOIA_PROFILE=1) — объективный детектор dead-фризов. Проверки: столлы +
# OCR-содержимое (имя диалога, текст сообщения). Артефакты (скрины, лог) — в
# $UITEST_OUT. Итог — таблица PASS/FAIL, ненулевой код при падении.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"
source "$HERE/lib/driver.sh"
source "$HERE/lib/ocr.sh"
source "$HERE/lib/app.sh"
source "$HERE/lib/assert.sh"

FILTER="${1:-}"
mkdir -p "$UITEST_OUT"
: >"$UITEST_LOG"

echo "═══════════════ Paranoia UI-tests ═══════════════"
echo "bin=$UITEST_APP_BIN"
echo "display=$UITEST_DISPLAY profile=$UITEST_PROFILE dialog=$UITEST_DIALOG"
echo "out=$UITEST_OUT  log=$UITEST_LOG"
echo

[ -x "$UITEST_APP_BIN" ] || { echo "!! нет бинаря $UITEST_APP_BIN (собери build_client)"; exit 2; }

# --- один общий запуск + вход ------------------------------------------------
echo "▶ launch + unlock + profile"
app_launch || { echo "!! запуск не удался"; exit 2; }
app_unlock
app_select_profile "$UITEST_PROFILE" || echo "  (профиль не переключился — возможно уже активен)"

# --- прогон сценариев ---------------------------------------------------------
shopt -s nullglob
for f in "$HERE"/scenarios/*.sh; do
  [ -n "$FILTER" ] && [[ "$(basename "$f")" != *"$FILTER"* ]] && continue
  unset -f scenario 2>/dev/null; SCENARIO_NAME=""
  source "$f"
  echo
  echo "▶ ${SCENARIO_NAME:-$(basename "$f")}"
  scenario
done

# --- финал --------------------------------------------------------------------
if [ "${UITEST_KEEP:-0}" != "1" ]; then app_kill; fi
uitest_summary
