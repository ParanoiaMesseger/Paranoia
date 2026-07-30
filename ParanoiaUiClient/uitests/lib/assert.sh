#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# assert.sh — проверки и учёт результатов. Главная — assert_no_stall: сверяет
# лог профайлинг-сторожа GUI-потока (env PARANOIA_PROFILE=1) на «GUI stall».
# Это ОБЪЕКТИВНЫЙ детектор dead-фриза (тот же, что нашёл appendMessages-баг).
# ─────────────────────────────────────────────────────────────────────────────

UITEST_PASS=0
UITEST_FAIL=0
declare -ga UITEST_RESULTS=()

_ts() { date +%s.%N; }

# Маркер в лог + запомнить позицию для «столлы ПОСЛЕ этого момента».
mark() {
  echo "=== MARK $1 $(date +%H:%M:%S.%N) ===" >>"$UITEST_LOG"
  UITEST_MARK_LINE="$(wc -l <"$UITEST_LOG")"
}

pass() { UITEST_PASS=$((UITEST_PASS+1)); UITEST_RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
fail() { UITEST_FAIL=$((UITEST_FAIL+1)); UITEST_RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1"; }

# Ни одного «GUI stall» в логе ПОСЛЕ последнего mark? (окно детекта — с mark).
assert_no_stall() {
  local what="$1"
  local from="${UITEST_MARK_LINE:-1}"
  local n
  n="$(tail -n +"$from" "$UITEST_LOG" 2>/dev/null | grep -c 'GUI stall' || true)"
  if [ "${n:-0}" -eq 0 ]; then pass "no GUI stall — $what"
  else
    fail "GUI stall x$n — $what"
    tail -n +"$from" "$UITEST_LOG" | grep -A1 'GUI stall' | head -6 | sed 's/^/     /'
  fi
}

# OCR-проверка: в области (x y w h) присутствует текст.
assert_text() {
  local rx="$1" ry="$2" rw="$3" rh="$4" needle="$5" what="$6"
  if ocr_region_has "$rx" "$ry" "$rw" "$rh" "$needle"; then pass "text «$needle» — $what"
  else
    local got; got="$(ocr_region "$rx" "$ry" "$rw" "$rh")"
    fail "text «$needle» not found — $what (OCR: «$got»)"
  fi
}

# Заголовок чата содержит имя диалога?
assert_in_dialog() {
  read -r hx hy hw hh <<<"$CHAT_HEADER_REGION"
  assert_text "$hx" "$hy" "$hw" "$hh" "$UITEST_DIALOG" "header shows dialog"
}

uitest_summary() {
  echo
  echo "═══════════════ UITEST SUMMARY ═══════════════"
  printf '%s\n' "${UITEST_RESULTS[@]}"
  echo "───────────────────────────────────────────────"
  echo "PASS=$UITEST_PASS  FAIL=$UITEST_FAIL"
  [ "$UITEST_FAIL" -eq 0 ]
}
