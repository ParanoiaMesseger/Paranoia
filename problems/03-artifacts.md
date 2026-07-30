# Артефакты и избыточные конструкции

Следы поиска решения: вторая реализация того же самого, мёртвый код, отладочные остатки.

---

## 1. [HIGH] Регистрация сохраняет конфиг по захардкоженному пути, игнорируя `PARANOIA_CONFIG`

**Файл:** `ParanoiaServer/src/routes/reg.rs:71`

`main.rs` и admin-роуты берут путь конфига из env `PARANOIA_CONFIG` (есть готовый helper `routes::admin::config_path()`), а `/reg` пишет по захардкоженному `"./configs/Paranoia.json"` — вторая, старая реализация того же самого не удалена. Если сервер запущен с `PARANOIA_CONFIG`, новые пользователи записываются в файл, который сервер никогда не читает: **после рестарта регистрация теряется**, пользователь перестаёт проходить аутентификацию на всех роутах.

Это не только артефакт, но и фактический баг корректности — самый приоритетный пункт плана.

```rust
// reg.rs:71
if let Err(e) = cfg.save("./configs/Paranoia.json") {

// admin/mod.rs:211-213 — уже есть правильный helper
pub fn config_path() -> String {
    std::env::var("PARANOIA_CONFIG").unwrap_or_else(|_| "./configs/Paranoia.json".to_string())
}
```

**План:** заменить в `do_reg` на `cfg.save(&crate::routes::admin::config_path())` — как уже сделано в `admin/users.rs` и `admin/server_config.rs`. (Заодно см. `problems/01-freezes.md` п. 2 — save под локом.)

---

## 2. [MEDIUM] Рукописные раскладки клавиатуры мертвы: движок распознавания не собирается

**Файл:** `ParanoiaUiClient/ui/keyboard/layouts/fallback/handwriting.qml:11` (+ `ru_RU/handwriting.qml`, `en_US/handwriting.fallback`)

Раскладки handwriting требуют QML-тип `HandwritingInputMethod`, который существует только при сборке Qt VirtualKeyboard с коммерческим движком распознавания (Cerence/T9Write). В репозитории нет соответствующих флагов: `scripts/rebuild_qtvkb_hunspell.sh` включает только `FEATURE_hunspell`, grep по cerence/t9write/vkb_handwriting пуст. Без фичи Keyboard не предлагает режим рукописи (HandwritingModeKey скрыт), т.е. файлы никогда не загружаются, но пакуются в qrc всех сборок (`CMakeLists.txt:975,981,983`) на всех 5 платформах. Мёртв и `handwritingKeyPanel` + ветка «Рукопись» в `functionPopupListDelegate` в `ui/keyboard/Paranoia/style.qml:179,337`.

**План:** удалить handwriting-раскладки и их строки из `qt_add_resources` в `ParanoiaUiClient/CMakeLists.txt`, а также `handwritingKeyPanel` и ветку `ToggleHandwritingMode` из `ui/keyboard/Paranoia/style.qml`. Если рукопись когда-то планируется — оставить файлы вне qrc до появления движка.

---

## 3. [LOW] Отладочный `dbg!` вместо `tracing` в продакшен-коде

**Файл:** `ParanoiaServer/src/routes/pull.rs:76-80`

Оставленный артефакт отладки: `dbg!` не удаляется в release-сборке и пишет напрямую в stderr мимо tracing-подписчика. Причём макрос даже не форматирует строку — печатает все три выражения по отдельности (строку-шаблон с `{}` и оба имени пользователя как отдельные значения с файлом/строкой). Все остальные роуты в этом же месте используют `warn!`. Свип дублей добавил контекст: весь блок «подписать может любой из участников» (чтение двух pubkey → format! → verify_signature ×2, ~25 строк) скопирован в ТРИ роута — `pull.rs:55-82` ≡ `map.rs:59-81` ≡ `determinate.rs:55-77`, и dbg! — это разъехавшаяся копия.

```rust
dbg!(
    "Invalid pull signature for dialogue {}<->{}",
    req.sender,
    req.recver
);
```

**План:** вынести хелпер `verify_pair_signature(state, sender, recver, signed_msg, sig)` в routes/mod.rs (или crypto.rs) с единым warn!-логированием — закрывает и dbg!, и тройной дубль; минимум — заменить dbg! на `warn!` как в map.rs/determinate.rs.

---

## 4. [LOW] Избыточные `unsafe impl Send/Sync` для PacketStore

**Файл:** `ParanoiaServer/src/store.rs:36-37`

`rocksdb::DB` уже `Send + Sync` (о чём говорит сам комментарий над строками), поэтому `PacketStore { db: DB }` получает эти трейты автоматически — `unsafe impl` ничего не добавляют. Хуже того, это опасный рудимент: если в PacketStore появится не-Sync поле (кэш, `RefCell`), компилятор промолчит, и получится реальная гонка.

**План:** удалить оба `unsafe impl` — авто-вывод Send/Sync сделает то же самое безопасно и продолжит проверяться компилятором.

---

## 5. [LOW] CenteredPane — компонент-сирота

**Файл:** `ParanoiaUiClient/ui/Components/CenteredPane.qml` (+ `CMakeLists.txt:552`)

Компонент зарегистрирован в сборке, но не инстанцируется ни в одном QML/C++ файле репозитория (grep за вычетом каталогов сборки находит только определение и строку в CMakeLists). Мёртвый файл компилируется в qmlcache и таскается во всех дистрибутивах; при этом описанный в его шапке паттерн «центрированная форма» страницы реализуют сами.

**План:** удалить `ui/Components/CenteredPane.qml` и его строку из `CMakeLists.txt`, либо реально применить компонент на страницах-формах, ради которых он писался.

---

## 6. [LOW] Дубли глифов в AppIcon: `"x"` повторяет `"close"`, micOff/videoOff — копипаста mic/video

**Файл:** `ParanoiaUiClient/ui/Components/AppIcon.qml:367` (и 445-536)

Иконка `"x"` (строка 367) — тот же крест, что `"close"` (строка 196), с разницей в 0.5px по координатам; `"close"` используется в 11 местах, `"x"` — в одном (`EmojiPanel.qml:112`). Кроме того, ветки `micOff` (472-496) и `videoOff` (516-536) целиком дублируют пути `mic` (445-469) и `video` (303-323) перед добавлением перечёркивания. На производительность 892-строчный if-chain не влияет (выполняется только при requestPaint) — это вопрос сопровождения: правка формы иконки требует правки в двух местах.

**План:** удалить ветку `"x"`, заменив в `EmojiPanel.qml` `name: "x"` на `"close"`. Тела mic/video вынести во внутренние функции `drawMic(ctx)`/`drawVideo(ctx)` и вызывать их из `*Off`-веток перед отрисовкой перечёркивания.

---

## 7. [MEDIUM] Мёртвый «жадный» корп-синк: syncCorporateKeyring + applyCorporateKeyring + corporateSyncFinished

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:1471-1494` (+ `:1308`, `MainBackend.hpp:117,300,340`)

Q_INVOKABLE `syncCorporateKeyring()` не вызывается нигде: ни из QML, ни из C++ (grep по всему репо — только объявление/определение; динамических вызовов по строке нет). Приватный `applyCorporateKeyring()` вызывается только из него, сигнал `corporateSyncFinished` никем не слушается. Это старый «жадный» путь раздачи всей связки ключей, полностью заменённый ленивым (`fetchCorporateRoster` + `addCorporateDialogue`) — комментарий в живом пути (`:1391-1393`) прямо это подтверждает («раньше это делала жадная связка. Ключи НЕ качаются»). ~60-90 строк мёртвого кода, включая дублирующее построение names-хэша из ростера, которое уже делает `applyCorporateRosterNames`. Клиентская FFI-обёртка `corp_sync` используется только здесь.

**План:** удалить `syncCorporateKeyring()`, `applyCorporateKeyring()` и сигнал `corporateSyncFinished` из MainBackend; клиентскую FFI-обёртку `corp_sync` — тоже (Rust-сторона `paranoia_corp_sync` остаётся: нужна CLI/examples).

---

## 8. [MEDIUM] checkTurnServer — заглушка, всегда рапортующая «доступен»

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:1065-1086`

Q_INVOKABLE `checkTurnServer` не выполняет никакой проверки достижимости (только `normalizeTurnUrl` + синтаксическое выделение host из host:port) и безусловно эмитит `turnServerCheckFinished` с ok=true и pingMs=0. Использование живое: `ReserveTurnEditor.qml:75` вызывает его (в т.ч. автоматически на все TURN-серверы при открытии редактора), обработчик (`qml:129-132`) ставит state="ok", делегат (`qml:417-421`) рисует зелёный статус для любого, в т.ч. несуществующего, адреса. Артефакт недоделанной фичи (в комментарии TODO про FFI `paranoia_turn_probe`) с ложноположительным UI.

```cpp
// Заглушка: эмитим «ok с 0ms» — UI покажет «доступен»
emit turnServerCheckFinished(profileId, normalized, true, MainBackend::tr("сохранён"), 0);
```

**План:** до появления FFI `paranoia_turn_probe` убрать вводящий в заблуждение положительный результат: скрыть кнопку проверки в `ReserveTurnEditor` или эмитить нейтральный статус «сохранён, не проверялось» (ok=false/отдельный флаг), чтобы UI не рисовал «доступен».

---

## 9. [LOW] Мёртвые методы session-слоя: sessionFor, loadDialogs, deriveKey

**Файл:** `ParanoiaUiClient/src/session/SessionStore.cpp:30` (+ `ServerSession.cpp:46`, `Dialog.cpp:28`)

Три метода без единого вызова во всём репозитории (не Q_INVOKABLE и не слоты — динамический вызов из QML/invokeMethod исключён): `SessionStore::sessionFor(server, username)` — вытеснен `sessionForProfile` (все 12 реальных вызовов идут через него); `ServerSession::loadDialogs()` — заменён предзагрузкой на воркере при логине (комментарий `MainBackend.cpp:604` «расшифровано на воркере (вместо синхронного loadDialogs)»); `Dialog::deriveKey(sharedSecret)` — от старой схемы вывода ключа из shared secret. ~15 строк.

**План:** удалить все три метода вместе с объявлениями в `SessionStore.hpp:15`, `ServerSession.hpp:29` и `Dialog.hpp:13`.

---

## 10. [MEDIUM] m_seenIds — write-only структура: поддерживается в семи местах, нигде не читается

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.hpp:221` (записи: `ChatBackend.cpp:505`, `:1728`, `:1847`, `:2269`, `:2280`, `:2572`, `:2700`, `:2766`, `:2786-2790`)

`QMap<QString, QSet<QString>> m_seenIds` аккуратно наполняется и чистится в deleteTopic, deleteMessagesUntil, deleteMessages, onDialogRemoved, onSessionReset, loadHistory и appendMessages — причём appendMessages в конце ещё и полностью пересобирает сет по всему кэшу на каждый вызов (лишний O(n)-проход с `toMap()`+QString-аллокациями на каждый poll-батч, на GUI-потоке). Ни одного чтения (contains/value) в проекте нет — дедупликация давно делается линейным find_if по кэшу (см. `02-redundant.md` п. 7). Остаток старого механизма дедупликации: мёртвое состояние + лишняя работа в горячем пути.

```cpp
// ChatBackend.cpp:2786-2790 — пересборка на каждый батч
seen.clear();
for (const auto &msg : cache) { const QString id = …; if (!id.isEmpty()) seen.insert(id); }
```

**План:** удалить поле m_seenIds и все места его поддержки (включая пересборку в appendMessages и keptIds-ветки в delete*-методах).

---

## 11. [LOW] Три мёртвые функции тем от старой (до-«корзинной») реализации

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:1028` (также `:981`, `:1042`)

`filterByTopic` (`:1028`), `computeTopicNames` (`:981`) и `recomputeTopicUnread` (`:1042`) нигде не вызываются (grep по репо — только определения + 2 упоминания в комментариях): их заменили `_rescanTopics`/`_bucketFor`, а логика «первый показ — всё просмотрено» продублирована инлайном в updateMessageModel (`:1121-1129`). Комментарий у filterByTopic «оставлен для совместимости/разовых вызовов» не подтверждается ни одним вызовом. Две версии подсчёта бейджей — легко править не ту; ~60 строк в 5400-строчном файле.

**План:** удалить все три функции; актуальной остаётся только инлайн-реализация в updateMessageModel.

---

## 12. [LOW] Диалог выбора папки сохранения — сирота после перехода на «сохранение одним тапом»

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:1897-1905` (свойства `:38-39`)

`ParaFileDialog saveDialog` никогда не открывается: `openSaveDialog` (`:291-300`) после #33/#34 сразу зовёт `Chat.saveAttachmentToDefault`, `saveDialog.open()` не вызывается нигде. Вместе с ним мертвы `pendingDownloadId`/`pendingDownloadName` (пишутся в openSaveDialog, читаются только внутри мёртвого onAccepted — pendingDownloadName не читается вообще). Это же единственный QML-вызов `Chat.saveAttachment(id, folder)`. ⚠️ Нюанс (верификатор): C++ `ChatBackend::saveAttachment` удалять нельзя — его вызывает `saveAttachmentToDefault` (`ChatBackend.cpp:1395`); можно лишь снять Q_INVOKABLE/сделать приватным.

**План:** удалить saveDialog и оба свойства; в openSaveDialog оставить requestFileAccessPermissions + saveAttachmentToDefault; у C++ saveAttachment снять Q_INVOKABLE.

---

## 13. [LOW] Мёртвая функция sendSelectedPhotos — заменена стейджингом вложений

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:474-486`

`sendSelectedPhotos` нигде не вызывается (grep — только определение + упоминание в комментарии `ChatBackend.cpp:2250`). Её маршрутизация «одно фото без подписи → sendFile, иначе sendPhotoGroup» теперь живёт в sendBtn.doSend (`:4966-4971`), выбор фото идёт через stageAttachment (`:1683-1690`, `:1885`). Остаток до-стейджинговой реализации.

**План:** удалить функцию; поправить комментарий в `ChatBackend.cpp:2250`, ссылающийся на неё как на живую.

---

## 14. [LOW] Мёртвая функция tileProgress с устаревшим void-трюком

**Файл:** `ParanoiaUiClient/ui/Components/PhotoMosaic.qml:33-38`

`tileProgress(key)` не вызывается никем: плитки читают прогресс напрямую в биндинге `tile.prog` (`:104-109`), что зафиксировано комментарием «ЯВНО читаем … прямо в биндинге (не через void-трюк в функции)» — осознанный отказ от подхода из-за нерабочего отслеживания зависимости. Функция — артефакт первой реализации, вводит в заблуждение.

**План:** удалить функцию tileProgress.

---

## 15. [LOW] Отладочный флаг _mosaicDebug всегда false и два мёртвых дамп-блока в composeMessages

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:116` (блоки `:492-503`, `:571-585`)

Флаг помечен «ВРЕМЕННО: диагностика мозаики … Снять после фикса» — баг мозаики давно исправлен (стабильный messageKey по group_id, `:914-926`), присваиваний true нет нигде: оба дамп-блока (~28 строк с циклами, JSON.parse и console.log) в горячей composeMessages недостижимы.

**План:** удалить свойство и оба `if (root._mosaicDebug)`-блока.

---

## 16. [LOW] Вторая (устаревшая) реализация эмодзи-выбора с хардкод-набором и Text-глифами

**Файл:** `ParanoiaUiClient/ui/Components/EmojiPicker.qml:28-72` (рендер `:121-126`)

В проекте два параллельных эмодзи-пикера: EmojiPanel (полный CLDR-набор из emojidata.js, рендер через `image://emoji` — введён из-за переполнения цветного glyph-кэша scene-graph на Android, комментарий `EmojiPanel.qml:165-167`) и EmojiPicker для настройки реакций (`ChatPage.qml:5152`) — со своим захардкоженным сокращённым набором (8 массивов) и рендером обычным Text, т.е. тем самым путём с известной Android-проблемой. Данные дублируются, наборы расходятся, поиска нет. Смягчение: диалог редкий, на вкладке ≤96 глифов (кэш переполнялся на 1914).

**План:** перевести пикер реакций на EmojiData.categories + `image://emoji` (или переиспользовать EmojiPanel внутри Popup), удалив хардкод-массивы.

---

## 17. [MEDIUM] Мёртвая пара paranoia_service_notify_count / _wait — заменена multi-notify, но не удалена (4 слоя)

**Файл:** `ParanoiaLibrary/src/ffi.rs:3256` (`:3333`; + `paranoia_lib.h:202,211`, `paranoia_service_jni.c:45,79`, `ParanoiaForegroundService.java:174,178`)

Обе stateless-функции одиночного notify (~150 строк) никем не вызываются: Java-сервис декларирует native-методы, но реально зовёт только `paranoiaServiceNotifyMultiWait` (`:891`, `:1002`) — миграция на multi-notify 0.2.20. Мёртвый код в четырёх слоях: Rust, заголовок, JNI-шимы, Java-декларации. Вдобавок функции — почти построчные копии друг друга (разница только long_poll_ms) с подвисшим TODO «параметризовать для Android-цикла» (`:3307`).

**План:** удалить обе функции из ffi.rs, декларации из paranoia_lib.h, JNI-обёртки из paranoia_service_jni.c и native-декларации из ParanoiaForegroundService.java. Боевой путь один — multi_wait.

---

## 18. [MEDIUM] Мёртвый старый путь отправки файлов: send_file / send_file_with_progress / send_large_file / blob_limits

**Файл:** `ParanoiaLibrary/src/ffi.rs:1067` (`:1099`, `:1253`, `:1290`; деклы `paranoia_lib.h:125,133,153,157`, обёртки `ParanoiaFFI:57,66,92,97`)

После введения `paranoia_send_file_auto_json_keyring_with_progress` (док на `:1343`: «C++-сторона зовёт ТОЛЬКО эту функцию») четыре старых FFI-входа остались без единого вызова (~200 строк обёрток): ChatBackend зовёт только auto- и photo-варианты (`ChatBackend.cpp:940,1063,1105`). Внутренние Rust-методы dialogue.rs (blob_limits, send_large_file_path_with_progress) живы — используются auto-путём; мёртв только FFI-слой.

**План:** удалить четыре функции из ffi.rs, их декларации из paranoia_lib.h и методы-обёртки из include/ParanoiaFFI; оставить auto- и photo-group-варианты.

---

## 19. [LOW] Мёртвый paranoia_fetch_and_apply_signed_profile — клиент качает профиль сам через QNetworkAccessManager

**Файл:** `ParanoiaLibrary/src/ffi.rs:2127` (+ `lib.rs:145-163`, `ParanoiaFFI:421-422`, `paranoia_lib.h:590`)

Функция «скачать+проверить+применить» и её основа `ParanoiaClient::fetch_and_apply_signed_profile` (с `reqwest::Client::new()` на каждый вызов) никем не вызываются: MainBackend качает профиль асинхронно через QNetworkAccessManager (`MainBackend.cpp:1647`), а применяет отдельным `set_signed_masking_profile` (`:1666`). Незадействованная альтернативная реализация того же сценария в 4 точках.

**План:** удалить всю цепочку (ffi.rs, lib.rs, ParanoiaFFI, paranoia_lib.h). Если когда-то нужен авто-апдейт профиля из ядра — реализация восстановима из истории, держать обе не нужно.

---

## 20. [LOW] Мёртвый одиночный paranoia_notify_unread_count_keyring — заменён multi-вариантом

**Файл:** `ParanoiaLibrary/src/ffi.rs:1559` (+ `paranoia_lib.h:191`, `ParanoiaFFI:131`)

Одиночный unread-notify никем не вызывается: NotificationCoordinator перешёл на `paranoia_notify_unread_multi_keyring` (`NotificationCoordinator.cpp:364`), чей док прямо говорит «вместо N отдельных». ~40 строк FFI-обвязки; Rust-метод `dialogue.notify_unread_count` (`dialogue.rs:666`) вызывается только отсюда — при удалении осиротеет и он. Живые одиночные `notify_count_keyring` (ChatBackend) и `notify_count_wait_keyring` (ActiveChatNotifier) — другие функции, не затрагиваются.

**План:** удалить paranoia_notify_unread_count_keyring из ffi.rs (+ декл и обёртку) и осиротевший dialogue.notify_unread_count.

---

## 21. [LOW] Мёртвая FFI-пара paranoia_vault_encrypt_attachment / decrypt_attachment

**Файл:** `ParanoiaLibrary/src/ffi.rs:3176` (`:3210`; + `paranoia_lib.h:642-643`, `ParanoiaFFI:482-486`)

Экспортированные C-обёртки шифрования вложений per-file ключом не вызываются ни из C++, ни из JNI, ни из панели — шифрование вложений живёт внутри Rust (`local_vault::encrypt/decrypt_attachment` зовутся из dialogue-кэша `dialogue.rs:777,981,1000,1016,1044`, vault.rs и тестов). Из группы реально используется только `paranoia_vault_rekey_attachment` (`MainBackend.cpp:422`). ~70 строк мёртвой FFI-поверхности, обе к тому же читают весь файл в память.

**План:** удалить обе FFI-функции (+ деклы и обёртки); внутренние local_vault-функции оставить.

---

## 22. [MEDIUM] delete_dialogue не чистит outbound_transfers — зомби-передачи переживают удаление диалога (privacy!)

**Файл:** `ParanoiaLibrary/src/store.rs:921-930`

При удалении диалога чистятся 4 таблицы (messages, seq_map, dialogue_state, incoming_chunks), но журнал resumable-передач — добавленный позже — забыт. Приватность: filename/mime/cache_path/timestamp удалённого диалога остаются в БД навсегда. Поведение: при пересоздании диалога с тем же партнёром (тот же детерминированный DialogueKey) `resume_pending_transfers` — вызывается при каждом открытии чата (`ChatBackend.cpp:403/2385` → `ffi.rs:1441` → `dialogue.rs:1515`) — подхватит устаревший журнал и начнёт заново заливать старый файл на сервер, либо будет жечь /map+push до RESUME_MAX_ATTEMPTS=10.

**План:** добавить `"outbound_transfers"` в список таблиц delete_dialogue (колонки dialogue_a/dialogue_b в ней есть).

---

## 23. [MEDIUM] Мёртвое in-RAM семейство отправки: send_chunked + send_file/send_image/send_voice

**Файл:** `ParanoiaLibrary/src/dialogue.rs:1192-1289` (обёртки `:173`, `:452`, `:463`)

Старая реализация файловой отправки из `Vec<u8>` живёт параллельно боевой `send_path_chunked`, но БЕЗ журнала outbound_transfers (обрыв = навсегда недокачанная передача) и без прогресса. Продовых вызовов нет: FFI зовёт только path/auto/photo-варианты, EasyCli — auto; `send_image`/`send_voice` не вызываются нигде, `.send_file(` — только в тестах `two_clients.rs:328,420`. ~110 строк второй реализации — правки формата FileHeader/FileChunk приходится дублировать.

**План:** удалить send_chunked/send_image/send_voice; send_file свести к временному файлу + send_path_chunked (или перевести тесты на send_file_path) — останется один резюмируемый путь.

---

## 24. [LOW] seqs_for_topic — мёртвый код: единственный вызов в собственном тесте

**Файл:** `ParanoiaLibrary/src/store.rs:481` (тест `:1158-1159`)

Функция задумывалась для пакетного удаления темы (прямо сказано в доке), но delete_topic и trim_topic_keep_last пошли через `list_topic_messages` (нужны полные сообщения для учёта чанков тел файлов). Единственное использование — ассерт в собственном тесте. Артефакт поиска решения с вводящей в заблуждение документацией.

**План:** удалить функцию вместе с ассертом в тесте topic_columns_roundtrip_and_queries.

---

## 25. [LOW] Тройная копия HTTP-обвязки в transport.rs

**Файл:** `ParanoiaLibrary/src/transport.rs:492`, `:534`, `:578` (+ циклы `:432`, `:449`, `:470`)

`put_json_once` / `put_json_once_authorized` / `get_json_once_authorized` — побайтно одинаковая обработка ошибок builder/сети и классификация статусов (5xx/429 → Retry, прочее → Stop, JSON-парс), ~40 строк × 3; отличия только в Authorization и body/query. Плюс три копии цикла перебора резервных endpoint'ов. Правка ретрай-логики = три синхронные правки.

**План:** один хелпер `send_once(method, url, body, auth, query)` + один generic-цикл перебора endpoint'ов; публичные обёртки — тонкие.

---

## 26. [LOW] Пять независимых реализаций атомарной записи файла в одном крейте

**Файл:** `ParanoiaLibrary/src/dialogue.rs:2049` (+ `:2078`, `:2086`; `local_vault/io.rs:16`, `local_vault/vault.rs:616`, `ffi.rs:3527`, `local_vault/state.rs:104`)

Семантика «tmp + rename» реализована пятикратно (верификатор нашёл на 2 больше ревьюера): uuid-tmp вариант dialogue.rs безопасен при параллельной записи, `.tmp`-варианты затирают tmp друг друга при конкурентных писателях, а `replace_file` делает remove+rename — неатомарное окно (на POSIX remove вообще лишний). Смягчение: FFI сериализован мьютексом, конкурентные писатели маловероятны.

**План:** один общий хелпер (uuid-tmp + чистый rename) в утилитном модуле, использовать во всех пяти местах.

---

## 27. [LOW] Поле ArrivedResponse.ts заполняется, но нигде не читается

**Файл:** `ParanoiaLibrary/src/transport.rs:100-105` (парсинг `:379`, `:386`)

`arrived_get` парсит "ts" из ответа сервера и кладёт в структуру; оба вызова (`dialogue.rs:700`, `:724-733`) читают только own_last_seq/partner_last_seq. Чтений `.ts` нет нигде (pub-поле — компилятор молчит). Мёртвый багаж протокола.

**План:** удалить поле и его парсинг.

---

## 28. [LOW] ATTACHMENT_HKDF_INFO — константа-обманка: реальная info-строка захардкожена в crypto.rs

**Файл:** `ParanoiaLibrary/src/local_vault/io.rs:12` (реэкспорт `mod.rs:13`; литерал `crypto.rs:47`)

Константа объявлена и реэкспортирована, но не используется ни в одном месте: фактическая HKDF-info per-file ключей вложений захардкожена литералом `b"attachment-v1"` в `derive_attachment_key`. Опасность именно в обманке: правка «источника истины» ничего не изменит — ключи продолжат выводиться по старому литералу.

**План:** использовать константу в derive_attachment_key (перенести в crypto.rs) либо удалить константу и реэкспорт.

---

## 29. [LOW] Мёртвые pub-функции local_vault: check_token и current_root (+ осиротевшее поле)

**Файл:** `ParanoiaLibrary/src/local_vault/pkcs11.rs:109` (+ `vault.rs:691`)

`pkcs11::check_token` («проверка токена для UX перед инициализацией» — обёртка над login) и `vault::current_root` не имеют ни одного вызова во всём репо — задел под неподключённые UX-фичи. Поле `app_data_root` в ActiveVault (`vault.rs:56`) читается ровно один раз — внутри мёртвого current_root: удаление функции делает мёртвым и поле.

**План:** удалить обе функции и поле app_data_root из ActiveVault (вернуть при реальном подключении UX-проверки токена).

---

## 30. [MEDIUM] Мёртвая ветка combinedCount==0 — сброс счётчика при обнулении на сервере никогда не срабатывает (висящий бейдж)

**Файл:** `ParanoiaUiClient/src/backend/NotificationCoordinator.cpp:424-427` (фильтр `:377-379`)

`applyNotifyCounts` содержит ветку удаления ключа из m_notifiedPendingByPeer при combinedCount==0, но она недостижима: pollCountsGrouped кладёт в counts только записи с n>0 → serverCount ≥ 1 всегда. Остаток старой схемы «по одному notify на диалог». Последствие не косметическое: диалог, чей счётчик обнулился на сервере (прочитан с другого устройства/CLI), вообще не попадает в counts — его запись не удаляется, total завышен, бейдж и notificationHint висят до clearPeer (открытие диалога) или полного clear() при переходе в Active — т.е. могут жить всю фоновую сессию.

**План:** либо возвращать из pollCountsGrouped счётчики по всем опрошенным peer'ам (включая n=0) и оживить ветку, либо в applyNotifyCounts удалять ключи m_notifiedPendingByPeer, отсутствующие в ответе (при anyFailed=false); мёртвый код в текущем виде убрать.

---

## 31. [LOW] Мёртвые функции takeOpenPeerFromNotification и clearServiceSnapshot

**Файл:** `ParanoiaUiClient/src/platform/PlatformNotifications.cpp:222`, `:327-331` (+ `PlatformNotifications.hpp:27`, `:57`)

Обе не вызываются никем (свободные функции в namespace, из QML недостижимы). `takeOpenPeerFromNotification` — остаток старого API до NotificationTarget (все перешли на takeOpenTargetFromNotification). `clearServiceSnapshot` задуман для logout, но фактически logout идёт через publishServiceSnapshot по sessionsChanged (публикует снапшот без разлогиненной сессии) — вызов так и не подключили; Java-метод `clearSnapshot` (`ParanoiaForegroundService.java:331`) при удалении тоже становится мёртвым.

**План:** удалить обе функции + объявления + Java-метод clearSnapshot; если очистка снапшота при logout нужна отдельно — подключить вызов, иначе снести.

---

## 32. [LOW] Мёртвая non-blocking машинерия в SshWorker: waitSocket и все ветки LIBSSH2_ERROR_EAGAIN недостижимы

**Файл:** `ParanoiaUiClient/src/utils/ClientSSH.cpp:148-165` (ветки `:237-240`, `:251`, `:264-267`, `:281-284`)

libssh2-сессия нигде не переводится в неблокирующий режим (`libssh2_session_set_blocking` — 0 вхождений в репо) — в блокирующем режиме API не возвращает EAGAIN (при таймауте будет LIBSSH2_ERROR_TIMEOUT). `waitSocket()` с fd_set/select и все ветки ретрая по EAGAIN — недостижимый остаток брошенной неблокирующей реализации, ~40 строк, маскирующих простой блокирующий поток управления.

**План:** удалить waitSocket() и EAGAIN-ветки, оставив прямые блокирующие вызовы с session timeout (worker-поток это допускает); либо осознанно перевести сессию в non-blocking.

---

## 33. [LOW] Legacy-парсер строкового формата «domain;key» в initAdmins вопреки политике проекта

**Файл:** `ParanoiaUiClient/src/utils/adminStorage.cpp:45-48` (+ `adminStorage.hpp:14`)

Если vault-шифрованный admins.crypt не распарсился как JSON-массив, initAdmins молча падает в построчный разбор старого формата «domain;key». Единственный писатель файла (saveAdmins) пишет ТОЛЬКО JSON — это чистый legacy-fallback, прямо противоречащий принятому правилу «никаких legacy-fallback'ов для несовместимого on-disk формата». Побочно: повреждённый/недорасшифрованный контент тихо породит мусорные записи админов. Заодно `Q_INVOKABLE` на методе не-QObject структуры (`adminStorage.hpp:14`) — без Q_GADGET/Q_OBJECT макрос ничего не делает.

**План:** удалить строковый fallback (не-JSON = ошибка: лог + пустой список); убрать бессмысленный Q_INVOKABLE.

---

## 34. [LOW] Отладочный std::cout-дамп всего SSH-скрипта и удалённого вывода в stdout

**Файл:** `ParanoiaUiClient/src/utils/ClientSSH.cpp:226-227` (`:286-287`)

`runScript` печатает в stdout полный текст исполняемого скрипта (`RUN>`) и весь вывод удалённого канала (`$>`) — единственные std::cout во всём ParanoiaUiClient (остальное — qDebug). В дамп уходят домен, порт, публичный админ-ключ и произвольный stdout удалённых скриптов установки сервера — в stdout/journald на машине пользователя (приватный ключ не попадает — проверено верификатором). Путь холодный (мастер развёртывания).

**План:** убрать дамп тела скрипта; вывод канала — через qCDebug с отдельной выключенной по умолчанию logging-категорией.

---

## 35. [LOW] QML_ELEMENT-регистрация SpellChecker без единого использования из QML

**Файл:** `ParanoiaUiClient/src/spell/SpellChecker.hpp:12` (`:24-25`)

SpellChecker зарегистрирован как QML-тип с Q_INVOKABLE checkWord/suggestWords, но в ui/ нет ни одного `SpellChecker {}` — из QML работает только SpellHighlighter, который держит SpellChecker как внутренний C++-член; снаружи вызывается только статический prepareBundledDictionaries (`main.cpp:172`). Остаток раннего подхода «дёргать орфографию из QML напрямую».

**План:** убрать QML_ELEMENT (и Q_INVOKABLE-маркеры, если QML-доступ не планируется).

---

## 36. [MEDIUM] Мёртвый легаси-механизм trySwitchToTurn с тремя полями-сиротами

**Файл:** `ParanoiaUiClient/src/voip/CallController.cpp:852` (единственный вызов — self-reschedule `:866`; комментарий `:843-846`)

`trySwitchToTurn()` больше никем не вызывается — единственный вызов внутри него самого (QTimer::singleShot), код недостижим; комментарий в onTurnRelayReady прямо говорит, что легаси-вызов убран в пользу promoteBestPath. Вместе с методом мертвы поля: `turn_route_active_` (пишется в 5 местах, читается только тут), `call_started_ms_` (пишется в обоих стартах звонка, читается только тут), `local_turn_relay_` («legacy-поле для совместимости» — наружу значение не уходит). Создаёт ложное впечатление второго действующего механизма переключения на TURN в критичном VoIP-коде.

**План:** удалить trySwitchToTurn() (+ Q_INVOKABLE-декларацию), все три поля и их записи (resetCallState/onTurnRelayReady/promoteBestPath/pollRxPath), поправить комментарии про grace-window.

---

## 37. [LOW] Неиспользуемая обёртка CallEngine::start(prepare+setPeer+attachAudio)

**Файл:** `ParanoiaUiClient/src/voip/CallEngine.cpp:648` (`CallEngine.hpp:183`)

Q_INVOKABLE `start(localBind, peerAddr, masterKeyB64, sessionIdB64, role)` не вызывается ни из C++, ни из QML (поток звонка идёт через CallController::prepare/setPeer/attachAudio); комментарий сам признаёт «для случая, когда peer известен заранее (например, при тесте)». Вдобавок сомнительное условие `prepare(...) == 0 && !session_` (ошибка молча игнорируется) — но код мёртв.

**План:** удалить метод (cpp и hpp) вместе с упоминанием в doc-комментарии класса.

---

## 38. [LOW] Неиспользуемый AVFrame rgb в extractPosterFrame

**Файл:** `ParanoiaUiClient/src/voip/VideoTranscoder.cpp:107` (`:159`)

В extractPosterFrame аллоцируется `AVFrame *rgb`, который нигде не используется (конверсия пишется напрямую в QImage через sws_scale с dstData из result.bits()) и лишь освобождается в конце — остаток промежуточной реализации через отдельный RGB-кадр. Утечки нет, только лишняя пара alloc/free и шум.

**План:** удалить переменную и её av_frame_alloc/av_frame_free.

---

## 39. [LOW] UnlockPin дублирует keypad и PIN-ввод из SetPin (~110 строк копипаста)

**Файл:** `ParanoiaUiClient/ui/Pages/UnlockPin.qml:194-246` (= `SetPin.qml:407-458`; также `:74-76`, `:139-173`)

Экранный цифровой keypad (Grid + Repeater с моделью ["1"…"backspace"], «пилюли», иконка backspace, MouseArea) скопирован из SetPin один-в-один (разница — только opacity при busy/lockout); продублированы sanitizePin (посимвольно), appendDigit/removeDigit, блок ParaInput с двумя Binding и onTextChanged-санитизацией, и даже Flickable-каркас центрирования с теми же комментариями. При этом ChangePin уже правильно переиспользует SetPin целиком (три инстанса) — паттерн в проекте есть, UnlockPin остался несведённой копией: правки клавиатуры (как недавние фиксы VKB) приходится вносить в два места. Свип дублей независимо подтвердил: это крупнейший QML-дубль репозитория по shingle-скану (28 совпадающих 12-строчных окон, ~130 строк).

**План:** вынести keypad в `Components/PinKeypad.qml` (enabled/dimmed, сигналы digit/backspace) + общий PIN-input блок; либо расширить SetPin режимом «unlock» и собрать UnlockPin на нём, как ChangePin.

---

## 40. [LOW] Таймер 80 мс перед vaultChangePin — workaround, уже решённый в C++

**Файл:** `ParanoiaUiClient/ui/Pages/ChangePin.qml:27-32` (`:37`)

Вызов Backend.vaultChangePin отложен QML-таймером на 80 мс «чтобы успел отрисоваться busy-overlay», но C++-сторона уже решает ровно это сама: vaultChangePin откладывает работу через QueuedConnection (комментарий в `MainBackend.cpp:329-341` — прямо про отрисовку overlay) и выполняет её в QtConcurrent-воркере. Таймер лишь добавляет 80 мс задержки; `changePinTimer.stop()` в обработчике результата — мёртвый код (одноразовый таймер к приходу результата гарантированно отработал).

**План:** убрать таймер (вызов напрямую из onAccepted) и строку stop().

---

## 41. [LOW] Неиспользуемое свойство releasesUrl при захардкоженном URL в кнопке

**Файл:** `ParanoiaUiClient/ui/Pages/VersionInfoPage.qml:13` (`:198`)

`property string releasesUrl: VersionInfo.releasePageUrl` объявлено, но нигде не читается; кнопка «GitHub» на той же странице открывает захардкоженный URL мимо свойства, дублируя константу kReleasePageUrl бэкенда — при переезде репозитория менять в двух местах. ⚠️ Нюанс (верификатор): URL'ы различаются (корень репо vs /releases) — простая подстановка свойства в кнопку изменит поведение; уместнее удалить свойство или завести отдельный repoUrl.

**План:** удалить мёртвое свойство (или ввести repoUrl-геттер и использовать его в кнопке).

---

## 42. [LOW] QrCodeBox: свойство caption нигде не отображается, но резервирует 28px высоты

**Файл:** `ParanoiaUiClient/ui/Components/QrCodeBox.qml:17` (`:9`)

Компонент объявляет caption и добавляет за него 28px к implicitHeight, но в теле нет ни одного Text — подпись под QR никогда не рендерится (остаток удалённого элемента). Все четыре вызова (`ClientRegistrationPage.qml:319,349`, `QrExchangePage.qml:194,300`) прилежно передают caption («Invitation QR», обрезанный ключ…) — пользователь получает пустую полосу под QR-кодом вместо подписи.

**План:** либо вернуть Text с caption под Image, либо удалить свойство, слагаемое «+28» и caption-аргументы у вызывателей.

---

## 43. [LOW] Выражение высоты списка экспорта всегда даёт константу 160

**Файл:** `ParanoiaUiClient/ui/Pages/ExportImportPage.qml:272`

`Math.min(160, Math.max(160, contentHeight + 2))` тождественно равно 160 при любом contentHeight — вложенные min/max аннулируются. Остаток эксперимента с динамической высотой: биндинг зависит от contentHeight и пересчитывается при каждом изменении списка, всегда возвращая одно и то же.

**План:** `height: 160`; если высота задумывалась адаптивной — исправить границы (например `Math.min(240, Math.max(160, …))`).

---

## 44. [LOW] Мёртвые поля статуса маскировки: tariff в QML и hasTrusted в ответе бэкенда

**Файл:** `ParanoiaUiClient/ui/Pages/MaskingPage.qml:22` (+ `MainBackend.cpp:1560`)

Свойство tariff объявлено и больше нигде в файле не упоминается; симметрично maskingStatus() вычисляет и возвращает hasTrusted, которое не читает ни один QML (MaskingPage — единственный потребитель). Остатки ранней версии страницы, различавшей тарифы/подпись в UI.

**План:** удалить оба (или реально показать в UI, если различие тарифов планируется).

---

## 45. [LOW] Тройная копипаста обвязки сканирования QR камерой

**Файл:** `ParanoiaUiClient/ui/Pages/RegisterUserPage.qml:11`, `:49-71` (= `QrExchangePage.qml:25`, `:66-83` = `ClientRegistrationPage.qml:45-46`, `:144-159`)

Идентичный блок «платформенный гейт cameraQrScan + Loader с QrScanPage + ручные item.back/qrScanned.connect + fallback на файловый диалог» скопирован в три страницы; платформенное условие доступности камеры продублировано дословно — при изменении политики (например, включение webcam на Linux/Windows) править три места, легко разъедутся (~25 строк × 3).

**План:** переиспользуемый компонент QrScanFlow (title/instructions, сигнал scanned, внутри Loader+fallback); платформенный гейт — в singleton (AppCapabilities).

---

## 46. [MEDIUM] Corp/dist-трафик идёт сырым reqwest мимо Transport/HttpMasking — HTTP-конверт не маскируется (ИБ!)

**Файл:** `ParanoiaLibrary/src/corp_api.rs:49-64` (`:279-292`, `:323-329`; node_tunnel `:69-89`)

В corp_api.rs своя параллельная HTTP-обвязка (`put_json`, `http_get_blob`): голый reqwest::Client только с timeout — без User-Agent (reqwest по умолчанию его не шлёт) и Cache-Control. Для тех же admin-операций admin_api.rs уже использует Transport, чей apply_masking ставит ротационный UA и Cache-Control (`transport.rs:223-230`). Хуже всего: `node_tunnel` декларирует «Маскирует distribution-трафик тем же профилем», заворачивает ТЕЛО в cover-конверт — и отправляет его этим же немаскированным клиентом: при включённой маскировке тело замаскировано, а HTTP-конверт без UA выделяется на транспортном уровне. Вторая реализация транспортного слоя, обходящая существующую (masking.rs создавался ровно затем, чтобы конверт не выдавал клиента).

**План:** гонять corp/dist-запросы через Transport (или общий помощник с HttpMasking) и удалить дублирующие put_json/http_get_blob; минимум — ставить заголовки из HttpMasking::default() на оба сырых клиента, включая node_tunnel и фолбэк fetch_blob.

---

## 47. [MEDIUM] Поля профиля user_agents/headers/cache_control парсятся, но нигде не применяются; сеттеры HttpMasking мертвы (ИБ!)

**Файл:** `ParanoiaCover/src/profile.rs:30-38` (+ `transport.rs:186`, `:211`, `:216`; `masking.rs:42-48`, `:66-71`)

MaskingProfile обещает «Пул User-Agent (ротация на стороне транспорта)», статические заголовки и Cache-Control — но ни один потребитель эти поля не читает (headers — вообще нигде; единственное чтение user_agents — тестовая фикстура). Активация профиля вызывает только `transport.set_cover(...)`; `Transport::set_masking`/`with_masking` не вызываются нигде → masking всегда `HttpMasking::default()`: method_overrides пуст, auth_scheme всегда "Bearer", UA-«пул» — один захардкоженный Chrome-UA («ротация» по кругу из одного элемента). Следствие: при любом активном schema-cover ВСЕ клиенты ходят с одним и тем же UA независимо от профиля — заявленная конфигурируемость конверта (недоделанная «Фаза 1» из шапки masking.rs) осталась артефактом.

**План:** при активации SchemaClientCover собирать HttpMasking из profile.user_agents/headers/cache_control и вызывать set_masking; либо честно убрать неиспользуемые поля из формата профиля и мёртвые сеттеры/method_overrides.

---

## 48. [MEDIUM] Мёртвый pub API qr_exchange + неподключённая анти-replay защита exchange_id

**Файл:** `ParanoiaLibrary/src/qr_exchange.rs:198-214` (`:191-196`, `:65-67`, `:345-362`)

Три публичных элемента без единого вызова вне модуля (только собственные тесты; в FFI не экспортированы): `fingerprint_for_payloads` — вторая реализация расчёта fingerprint, дублирующая живой путь complete_exchange (+ приватный validate_payload_pair жив только ради неё); `reject_known_exchange_id` — анти-replay помощник, который никто не подключил (в C++-клиенте exchange_id не отслеживается — задуманная защита от повторного использования приглашения НЕ реализована); `CompletedExchange::session_key()`. ~70 строк мёртвой поверхности с дублем крипто-логики.

**План:** удалить fingerprint_for_payloads + validate_payload_pair и session_key(); по reject_known_exchange_id — решение: либо подключить учёт использованных exchange_id в реальный флоу подтверждения (если анти-replay нужен), либо удалить.

---

## 49. [LOW] «Push failed: {msg}» — плейсхолдер не интерполируется, текст ошибки сервера теряется

**Файл:** `ParanoiaLibrary/src/client_cover_food.rs:182-188`

Аргумент `anyhow!` — if-выражение из &'static str-веток, поэтому ветка else отдаёт строку «Push failed: {msg}» буквально (интерполяция работает только с литералом прямо в макросе). Для любых отказов push, кроме duplicate/invalid_seq, в лог и UI уходит бессмысленный текст — а food-маска является дефолтным cover всех клиентов без профиля. В schema-версии тот же код написан правильно (`client_cover_schema.rs:243`) — рассинхрон двух реализаций.

**План:** ветку else заменить на `format!("Push failed: {msg}")` (лучше — с исходным, не lowercased текстом ответа).

---

## 50. [MEDIUM] Синхронный paranoia_call_signal_send остался после перехода на async-вариант

**Файл:** `ParanoiaLibrary/src/voip_ffi.rs:183-274` (`:266`; + `paranoia_lib.h:421`, `ParanoiaFFI:206-207`)

Синхронная версия (~90 строк) делает `rt.block_on(HTTP POST)` на потоке вызывающего и полностью дублирует логику `paranoia_call_signal_send_async` (`:295`), включая security-чувствительное формирование подписи `{from}{to}{kind}{ts_ms}{payload_b64}` (формат должен совпадать с серверной проверкой — правки в двух местах). В продакшене не вызывается: CallController использует только async, EasyCli зеркалирует сам. Мёртвый экспорт — открытая дверь снова позвать блокирующий сетевой вызов с GUI.

**План:** удалить функцию, декларацию и обёртку; общую часть (seal+подпись+CoreCallSignal) вынести в приватный хелпер async-варианта.

---

## 51. [MEDIUM] Fragmenter/Reassembler в voip::nal мертвы — фрагментация NAL живёт в C++, wire-логика в двух копиях

**Файл:** `ParanoiaLibrary/src/voip/nal.rs` (~350 строк; C++-дубль `CallEngine.cpp:770-799`, константы `:56-62`)

Fragmenter/Reassembler используются только собственными тестами; вне nal.rs модуль упоминается лишь в doc-комментариях. Реальная фрагментация — вручную в CallEngine::onCameraFrameI420, пересборка — тоже на Qt-стороне; синхронизация констант — ручная (комментарий «должны совпадать с Rust»). Поправка верификатора: рантайм-константы пока НЕ разъехались (1168 = 1168), устарел только doc-текст nal.rs («1400/≈1360»). Целый модуль мёртв, wire-логика в двух копиях.

**План:** либо удалить nal.rs (+ упоминания в доках), либо наоборот перенести фрагментацию/пересборку в Rust и выкинуть C++-дубль — в любом случае одна реализация; починить doc-константы.

---

## 52. [MEDIUM] CallSignal и типизированные payload-структуры сигналинга мертвы — wire-контракт в трёх местах и уже дрейфует

**Файл:** `ParanoiaLibrary/src/voip/signaling.rs:21-155`

CallOfferPayload/CallAnswerPayload/CallHangupPayload/CallIcePayload, enum CallSignal с (де)сериализацией и serde-модуль base64_session_id не имеют ни одного продакшен-потребителя: voip_ffi берёт из модуля только seal/open/CallSignalKind и гоняет payload как непрозрачный JSON; C++ и EasyCli собирают/парсят JSON вручную. Дрейф УЖЕ случился: типизированный `CallOfferPayload.session_id` — `[u8;16]`, а EasyCli шлёт 32 байта (`main.rs:671`) — мёртвый «источник правды» отверг бы боевой оффер.

**План:** либо удалить структуры и enum (kind достаточно), либо сделать их единственным источником правды — валидировать payload'ы в voip_ffi и использовать в EasyCli вместо ручного JSON (тогда починить session_id).

---

## 53. [LOW] Модуль voip::jitter (291 строка) мёртв — jitter-буфер переписан на Qt-стороне

**Файл:** `ParanoiaLibrary/src/voip/jitter.rs`

JitterBuffer/JitterConfig/JitterOut используются только собственными тестами; единственная внешняя ссылка — комментарий `CallEngine.hpp:295` («упрощённый порт voip::jitter из Rust»). Живая реализация того же алгоритма — C++ (`CallEngine.cpp:707-740`); растовая — сирота, которую придётся зря сопровождать при изменении политики (initial delay, PLC).

**План:** удалить jitter.rs и `pub mod jitter;`; политику задокументировать в VoipPolicy/комментарии CallEngine.

---

## 54. [LOW] Мёртвый блок long-term credentials TURN (MD5/HMAC-SHA1) — интеграции нет

**Файл:** `ParanoiaLibrary/src/voip/turn.rs:427` (`:293`, `:330`, `:226`, `:163`)

build_allocate_with_auth, auth-вариант build_create_permission, verify_message_integrity, derive_long_term_key, find_string, finish_with_integrity вызываются только из собственных тестов: боевой клиент использует исключительно no-auth варианты под встроенный Paranoia TURN, сервер имеет свою реализацию. Doc модуля сам признаёт: «Полная интеграция — отдельная фаза». ~130 строк + единственные пользователи зависимостей md5/sha1/hmac в voip-стеке.

**План:** удалить auth-хелперы с тестами (и осиротевшие зависимости из Cargo.toml); вернуть из истории git при реальной интеграции с RFC-TURN (coturn).

---

## 55. [LOW] paranoia_stun_discover (отдельный сокет) вытеснен сессионным вариантом и никем не вызывается

**Файл:** `ParanoiaLibrary/src/voip_ffi.rs:1472` (+ `paranoia_lib.h:556`)

Standalone-вариант STUN-discovery без вызовов (в ParanoiaFFI обёртки нет); VoipPolicy.md подтверждает, что для NAT-traversal нужен reflexive именно сессионного порта — вариант концептуально бесполезен для звонков, остался от ранней фазы.

**План:** удалить FFI-экспорт и декларацию; внутренний stun_discover сессии остаётся.

---

## 56. [LOW] Дубли-методы SessionHandle без _owned: turn_allocate/set_turn_peer вообще без вызовов

**Файл:** `ParanoiaLibrary/src/voip/transport.rs:366` (`:385`, `:347`; _owned `:249-318`)

После фикса «не держать mutex во время block_on» появились *_owned-варианты, которыми пользуется FFI, но старые несобственные версии остались: turn_allocate и set_turn_peer не вызываются вообще нигде, stun_discover — только в одном тесте; тела — построчные копии _owned (шесть копий одного паттерна request/oneshot). Комментарий recv_frame «для backward-compat (тесты, EasyCli)» устарел — EasyCli SessionHandle не использует.

**План:** удалить turn_allocate/set_turn_peer; stun_discover в тесте заменить на _owned и удалить (или выразить несобственные через `self.xxx_owned().await` — одна реализация); поправить комментарий recv_frame.

---

## 57. [MEDIUM] topic list дренирует курсор приёма вопреки правилу, зафиксированному в topic trim

**Файл:** `ParanoiaEasyCli/src/main.rs:390` (также `mcp_server.rs:970`; правило — `main.rs:433-435`)

`cmd_topic_trim` (0.2.21) сознательно НЕ вызывает receive() с комментарием «двигать курсор приёма нельзя — параллельный MCP-сервер на той же БД пропустил бы сообщения». Но `cmd_topic_list` и `tool_topics` по-прежнему делают `let _ = dialogue.receive().await` на той же paranoia.db — двигают общий last_pulled_seq, не персистя вытянутое в durable-лог. Уточнение верификатора: сообщения НЕ теряются из локального стора (save_message происходит) — в channel-режиме доставка доедет по своему курсору; реальная потеря доставки — в pull-режиме MCP при гонке с CLI-фолбэком, плюс деградация history/👀-квитанций. Артефакт итерации 0.2.21: правило применили к trim, но не к list/topics.

**План:** убрать receive() из cmd_topic_list/tool_topics (список тем по локальному стору, как в trim); либо персистить вытянутую пачку в durable-лог, как tool_receive.

---

## 58. [LOW] self_hash всегда равен username — дублирующая настройка-наследие

**Файл:** `ParanoiaEasyCli/src/main.rs:1360-1364` (+ `mcp_install.rs:767-768`)

username и self_hash взаимно фолбэкают друг на друга, установщик всегда пишет обе env-переменные одним server_id, README закрепляет «по умолч. = USERNAME». Семантически одна сущность; отдельное поле — наследие python-обёртки: лишняя конфиг-поверхность + повторяющиеся проверки в пяти местах mcp_server.rs. Легитимного сценария различия нет (расхождение дало бы неверную метку from:"me").

**План:** убрать McpConfig.self_hash, сравнивать с username; env — удалить (политика «без legacy-фолбэков») или оставить алиасом.

---

## 59. [LOW] Мастер channel-режима создаёт только старую раскладку плагина

**Файл:** `ParanoiaEasyCli/src/mcp_install.rs:803-804` (детектор `:269-278`, инструкция `:812`, `:844-846`)

Детектор channel_plugin_installed знает две раскладки и называет marketplace/plugins/paranoia «новой», а channel-plugin — «старой»; но установка `--channel` генерирует ТОЛЬКО старую (write_channel_plugin → channel-plugin/), и печатаемая команда запуска привязана к ней. Фактически развёрнутый боевой канал на машине — marketplace-раскладка, каталога channel-plugin на диске нет: мастер не способен воспроизвести актуальную установку.

**План:** генерировать в мастере marketplace-раскладку (+ обновить инструкцию запуска); либо, если канонической остаётся старая, убрать «новую» из детектора — один формат.

---

## 60. [LOW] hex_lower — самописный дубль hex::encode

**Файл:** `ParanoiaEasyCli/src/main.rs:758` (вызов `:673`)

Посимвольное кодирование через `format!("{b:02x}")` (аллокация String на каждый байт) при том, что крейт hex в зависимостях и используется в этом же файле (`:122`). Единственный вызов — call_id в cmd_call_offer.

**План:** удалить, использовать `hex::encode(cid)`.

---

## 61. [LOW] set_owner_only_permissions продублирована в двух файлах

**Файл:** `ParanoiaEasyCli/src/dialogue_store.rs:66-76` (= `main.rs:138-148`)

Идентичная пара cfg(unix)/cfg(not(unix)) функций с политикой 0o600 существует в обоих файлах (отличие — только текст ошибки); обе живые. Изменение политики прав — в два места.

**План:** pub-функция в dialogue_store (или общем utils-модуле), переиспользовать из main.rs.

---

## 62. [MEDIUM] Скелет модального confirm-попапа проштампован ~10 раз в 6 QML-файлах

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:5161` (также `:5215`; `SharedMediaPage.qml:787`, `MainPage.qml:1326/1366/1628/1698`, `ProfileSettingsPage.qml:281`, `Main.qml:505`, `DataManagementPage.qml:258`)

Один и тот же каркас подтверждающего попапа (Popup по центру Overlay, width 300-340, padding, background Rectangle radius+border, ColumnLayout: заголовок + пояснение + пара ParaButton) скопирован минимум 10 раз в 6 файлах — ~400+ строк дублей. Стили уже дрейфуют: bgSecondary против bgCard, padding 24/20/18, где-то только CloseOnEscape, адаптивная width только в Main.qml. Переиспользуемого ConfirmPopup в Components/ нет. Правка вида диалогов = обход 6 файлов.

**План:** `Components/ConfirmPopup.qml` (title/message/acceptText/cancelText/destructive + сигналы accepted/rejected; специфичные тела — через default property alias) и заменить все экземпляры.

---

## 63. [LOW] Обвязка handle() и ApiResponse/ok/fail скопированы в 7-8 route-файлах сервера

**Файл:** `ParanoiaServer/src/routes/push.rs:23-40` (≡ pull/map/notify/determinate/call_signal/call_poll; ApiResponse ×4: `push.rs:104-115`, `determinate.rs:89-100`, `call_signal.rs:98-109`, `reg.rs:79-90`)

Шаблон «unwrap cover → do_x → wrap response» (~16 строк) вставлен в 7 обработчиков; структура ApiResponse{success,message} с ok()/fail() определена заново в 4 файлах (+ свои fail() ещё в 5). ~150 строк дублей, и копии уже разъехались: в push.rs у cover-ошибки НЕТ warn!, который есть во всех остальных — «Bad cover» на /push в логах не виден.

**План:** общий ApiResponse + ok()/fail() в routes/mod.rs и generic-обёртка covered_route(unwrap_fn, do_fn, wrap_fn) с единообразным warn!; роуты оставляют только своё do_x().

---

## 64. [LOW] JNI-вызовы SAF (copyUriToCache/copyFileToUri) продублированы в Utils.cpp и ChatBackend.cpp

**Файл:** `ParanoiaUiClient/src/utils/Utils.cpp:275-336` (≡ `ChatBackend.cpp:280-306`)

Полный JNI-маршалинг вызовов Java-хелпера ParanoiaAndroidUtils (сигнатуры, ExceptionCheck/Describe/Clear) повторён дословно в двух файлах; комментарий в Utils.cpp прямо признаёт копию («тот же что использует ChatBackend»). В ChatBackend очистка исключений вынесена в хелпер, в Utils — снова инлайн. Смена Java-сигнатуры = правка в 2 местах.

**План:** вынести JNI-хелперы (androidContext, clearPendingAndroidException, copyUriToCache, copyFileToUri, copyFileToDirectoryUri) в utils/ и вызывать из обоих мест.

---

## 65. [LOW] STUN-примитивы (XOR-MAPPED-ADDRESS, message-type, MAGIC_COOKIE) реализованы трижды, дважды — в одном крейте

**Файл:** `ParanoiaLibrary/src/voip/turn.rs:377-411` (≡ `stun.rs:163-196`; сервер `voip_stun.rs:94-123`, `:228`)

MAGIC_COOKIE объявлен трижды; turn.rs заново определяет id атрибута и полный XOR-декодер адреса вместо импорта из соседнего stun.rs того же модуля; битовая математика message-type повторена и на сервере. Смягчение: RFC-математика стабильна, серверный дубль отчасти вынужден (нет общего крейта, кроме ParanoiaCover). Риск — багфикс в одном декодере (напр., IPv6-ветка) не попадёт в остальные.

**План:** turn.rs импортирует cookie/атрибуты/XOR-кодек из voip/stun.rs (расширить pub-API); для сервера — мини-крейт paranoia-stun либо осознанный комментарий-ссылка на первоисточник.

---

## 66. [LOW] TUI дублирует конструирование клиента/диалога вместо переиспользования main.rs

**Файл:** `ParanoiaEasyCli/src/tui.rs:174-182` (≡ `dialogue_store.rs:187-194` + `main.rs:316-326`)

TUI инлайном повторяет base64→[u8;32]-конверсию dialogue-ключа, уже вынесенную в `dialogue_store::base64_entry_to_key` (совпадают даже тексты ошибок), тогда как mcp_server.rs корректно переиспользует crate::build_client/build_dialogue. Поправка верификатора: build_ui_client — не дубль (другой источник ключа), реальный дубль — только keyring-петля ~8 строк. При изменении формата keyring TUI-ветку легко забыть.

**План:** использовать base64_entry_to_key из dialogue_store в tui.rs (или вынести конверсию (u64, base64) → Vec<DialogueKeyEntry> целиком).

---

## 67. [MEDIUM] Мёртвая цепочка «удалить сообщения до seq» в четырёх слоях: deleteMessagesUntil + пара FFI-экспортов

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:1679-1750` (+ `ParanoiaFFI:180,197`, `ffi.rs:1882,2020`, `paranoia_lib.h:285,307`, `dialogue.rs:789`)

Q_INVOKABLE `deleteMessagesUntil` (~70 строк) не вызывается ниоткуда — QML-вызов исчез после 0.2.8 (частичную очистку заменили мультивыбором deleteMessages(ids) и clearDialogHistory через другой FFI). Метод — единственный потребитель обёрток delete_local_until_keyring/determinate_keyring, те — единственные вызыватели соответствующих C-экспортов; при удалении осиротеет и `dialogue.delete_local_until` (clear_server_history жив — используется EasyCli). Мёртвый пласт в четырёх слоях: C++ → обёртки → C-экспорты → Rust.

**План:** удалить всю цепочку. ⚠️ Если частичная обрезка планируется в UI (бэклог keep-last-N) — восстановить из истории при реализации.

---

## 68. [LOW] Мёртвая цепочка ручной блокировки vault: vaultLock никем не вызывается, обработчики недостижимы

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:318-327` (+ `main.cpp:232`, `Main.qml:255-257`)

Q_INVOKABLE `vaultLock()` не вызывается ниоткуда; сигнал vaultLocked эмитится только внутри него → мертва вся машинерия реакции: connect на очистку plaintext-кэша превью EncryptedImageProvider и QML-обработчик замены стека на UnlockPin. Фича «заблокировать хранилище вручную» реализована на трёх уровнях, но не подключена ни к одной кнопке. Смягчение: очистка кэша при выходе работает через отдельный connect к aboutToQuit — security-утечки нет, это неподключённая фича.

**План:** либо подключить к UI (пункт «Заблокировать» в настройках/трее — осмысленно для security-продукта), либо удалить все три уровня.

---

## 69. [LOW] Dialogue::save_attachment — старая реализация, вытесненная download_attachment

**Файл:** `ParanoiaLibrary/src/dialogue.rs:761-787`

~30 строк без единого вызова; боевой путь — `paranoia_save_attachment_keyring` → `download_attachment`, который строгое надмножество (те же ветки + докачка чанков + эфемерные блобы), тогда как старая версия при недокачанном вложении падает с «attachment_not_downloaded».

**План:** удалить; единственной реализацией остаётся download_attachment.

---

## 70. [LOW] paranoia_call_session_start («bound»-вариант) мёртв — клиент использует только _unbound

**Файл:** `ParanoiaLibrary/src/voip_ffi.rs:932` (+ `paranoia_lib.h:486`)

FFI-экспорт старта VoIP-сессии с заранее известным peer не вызывается из C++ (CallEngine использует start_unbound + set_peer); живёт только в собственном тесте ffi_voip.rs. Тонкая обёртка над общим start_session_impl — мёртв только экспорт-переходник (~38 строк).

**План:** удалить экспорт и декларацию; тесты перевести на start_unbound + set_peer (заодно начнут гонять боевой путь).

---

## 71. [LOW] send_read_receipt никем не вызывается — in-band квитанции о прочтении больше никто не шлёт

**Файл:** `ParanoiaLibrary/src/dialogue.rs:473-476`

Единственный отправитель MessageContent::ReadReceipt — 0 вызовов; статус «прочитано» давно живёт через /arrived (arrived_put/arrived_get). Приёмная ветка ReadReceipt — wire-совместимость со старыми клиентами (как соседний legacy-Delete). Мёртвый отправитель выглядит как живой второй механизм квитанций.

**План:** удалить send_read_receipt; у приёмной ветки — комментарий «legacy-приём, отправка удалена» по образцу Delete.

---

## 72. [LOW] Сигнал vaultSetPinResult эмитится, но никто не слушает — ошибка установки PIN молча теряется

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:283` (+ `MainBackend.hpp:296`)

Ни одного onVaultSetPinResult/connect в репо. Побочный эффект не только косметический: при rc != 0 не эмитится даже vaultStatusChanged — SetPin-диалог при ошибке создания хранилища просто «молчит», пользователь без какой-либо реакции UI.

**План:** подключить обработчик в SetPin/Main.qml (показ ошибки при rc != 0) — предпочтительно; либо удалить сигнал.

---

## 73. [LOW] Россыпь мёртвых мелких Q_INVOKABLE: loginClient, openReleasePage, commitInputMethod, activeTopic

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:499` (+ `VersionInfoBackend.cpp:349`, `ChatBackend.cpp:2259`, `ChatBackend.hpp:47`)

Четыре Q_INVOKABLE без единого вызова (включая по строке): `loginClient` — старая версия без меты (QML зовёт только loginClientWithMeta); `openReleasePage` — кнопка GitHub открывает URL мимо метода (дополняет мёртвое releasesUrl, п. 41); `commitInputMethod` — заменён чтением preeditText прямо в QML; getter `activeTopic()` — никто не читает (QML только пишет).

**План:** удалить все четыре (loginClient — тело переиспользуется через loginClientInternal).

---

## 74. [LOW] Свойство MessageText.outgoing передаётся всеми вызывателями, но внутри не читается

**Файл:** `ParanoiaUiClient/ui/Components/MessageText.qml:19` (сеттеры `ChatPage.qml:3663`, `TextMessageViewer.qml:238`)

Остаток ранней версии, где цвет текста зависел от направления (сейчас — через textColor снаружи). ⚠️ Границы фикса (верификатор): `ChatPage.qml:3648` — сеттер ReplyPreview.outgoing, у которого свойство ЖИВОЕ, не трогать; `TextMessageViewer.qml:23` — собственное свойство вьюера, используется им самим (:58, :112, :115), удалять только проброс `:238`.

**План:** удалить MessageText.qml:19, ChatPage.qml:3663 и TextMessageViewer.qml:238 — ровно три строки.

---

## 75. [LOW] storePickedAttachment (одиночный) — старая версия пикера, вытесненная множественной

**Файл:** `ParanoiaUiClient/android/src/app/paranoia/client/ParanoiaAndroidUtils.java:92`

Не вызывается ни из Java (ParanoiaActivity зовёт только storePickedAttachments), ни из C++ по JNI. Формат разошёлся: одиночная версия кладёт голый URI, читатель ожидает «img|vid\n + список» — метод не только мёртв, но и несовместим с текущим протоколом.

**План:** удалить метод.

---

## 76. [LOW] Мелкая россыпь мёртвых QML-объявлений: toggleZoom, setAllExportDialogs, Theme.fontXl, PhotoMosaic.rows

**Файл:** `ParanoiaUiClient/ui/Components/PhotoViewer.qml:142` (+ `ExportImportPage.qml:29`, `Theme.qml:85`, `PhotoMosaic.qml:30`)

Сплошной скан ui/ на объявления без ссылок: toggleZoom — заменён toggleZoomAt с фокальной точкой; setAllExportDialogs — контрол «выбрать все» удалён из UI; Theme.fontXl — неиспользуемый токен; PhotoMosaic.rows — не читается нигде (все «.rows» в репо — таблицы MessageText).

**План:** удалить все четыре (PhotoMosaic.rows — заодно с tileProgress из п. 14).

---

## 77. [LOW] Мёртвые мелкие pub fn в ParanoiaLibrary: send_file_path, DialogueKey::participants, SessionHandle::shutdown_notify

**Файл:** `ParanoiaLibrary/src/dialogue.rs:183` (+ `types.rs:193`, `voip/transport.rs:320`)

Три pub fn без вызовов по всем 4 крейтам: send_file_path — обёртка без прогресса (FFI зовёт _with_progress напрямую); participants — все читают поля .a/.b; shutdown_notify — снаружи пользуются shutdown(). ⚠️ Если при разборе п. 23 (in-RAM семейство) выберут план «перевести тесты на send_file_path» — её оставить.

**План:** удалить все три.
