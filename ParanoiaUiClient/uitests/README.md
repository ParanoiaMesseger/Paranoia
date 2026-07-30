# UI-тесты десктоп-клиента Paranoia

Иерархический стек авто-тестов, который **драйвит настоящий GUI** десктоп-клиента
(`build_client/Paranoia`) через `xdotool`, снимает экран (`xwd`+`ffmpeg`), читает
его OCR-ом (`tesseract` rus+eng) и **объективно ловит dead-фризы** через встроенный
сторож GUI-потока (`PARANOIA_PROFILE=1` → на столле >порога снимает стек в лог).

Именно этим сторожем найден корень dead-фриза входа в огромный диалог
(`appendMessages` был O(N²) — коммит `b054afa`). Эти тесты его регрессят.

## Зависимости
`xdotool xwd ffmpeg tesseract-ocr tesseract-ocr-rus imagemagick`, X-дисплей
(`:1`), собранный `build_client/Paranoia`, разлоченный профиль с данными.

## Запуск
```bash
cd ParanoiaUiClient/uitests
./run_all.sh              # все сценарии
./run_all.sh 02          # только матчащие «02»
UITEST_KEEP=1 ./run_all.sh   # не убивать клиент в конце (отладка координат)
```
Настройки — через env (см. `config.sh`): `UITEST_DISPLAY`, `UITEST_PIN`,
`UITEST_PROFILE`, `UITEST_DIALOG` (огромная история), `UITEST_SEND_DIALOG`
(куда слать — по умолч. «Избранное», НЕ боевой канал), `UITEST_STALL_MS`.

## Структура
```
config.sh              координаты (window-relative), PIN, профиль, диалоги, пороги
lib/driver.sh          поиск окна, тап/свайп/ввод/скрин (все клики window-relative)
lib/ocr.sh             OCR области + поиск строки списка по тексту (устойчиво к порядку)
lib/app.sh             жизненный цикл: launch(+сторож)/kill/unlock/выбор профиля/диалога
lib/assert.sh          assert_no_stall (лог сторожа) + assert_text (OCR) + учёт PASS/FAIL
scenarios/01_open_huge_dialog.sh    вход в огромный диалог — БЕЗ фриза
scenarios/02_topic_swipe_stress.sh  быстрый свайп тем на непрогруженном — БЕЗ фриза
scenarios/03_scroll_history.sh      прокрутка вглубь истории — БЕЗ фриза
scenarios/04_kill_relaunch_reopen.sh «убить → зайти → открыть» — БЕЗ фриза, история на месте
scenarios/05_send_text.sh           отправка текста (self) — виден, без дубля, без фриза
scenarios/06_send_photos.sh         отправка N фото (self) — best-effort (файл-диалог)
run_all.sh             оркестратор: запуск, вход, прогон, таблица PASS/FAIL
```

## Проверки
- **`assert_no_stall`** — в логе сторожа нет `GUI stall` после маркера сценария.
  Это прямой регресс dead-фриза (главная цель стека).
- **`assert_text` / `assert_in_dialog`** — OCR подтверждает содержимое (имя открытого
  диалога, наличие отправленного текста) — тест ловит и «молча пусто», не только фриз.

## Грабли (важно)
- Координаты выверены на окне **448×846**; при другой геометрии — правь `config.sh`.
- Клиент НЕ убивать `pkill -f build_client/Paranoia` — матчит свой шелл (exit 144);
  `app_kill` бьёт по явному PID.
- Порядок строк в попапе профилей **меняется** → выбор профиля идёт OCR-ом, не по индексу.
- Сценарий 06 (фото) — best-effort: флоу файлового диалога Qt окруже-зависим;
  смотри скрины `06_attach_menu.png` / `06_after_pick.png` и допили координаты меню.
- Артефакты каждого прогона — в `$UITEST_OUT` (по умолч. `/tmp/paranoia_uitests_out`).
