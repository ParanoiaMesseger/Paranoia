# Фризы и блокировки

Блокирующий I/O и тяжёлый CPU в контекстах, где это останавливает обработку других запросов (tokio-воркеры сервера) или интерфейс.

---

## 1. [HIGH] Блокирующие RocksDB-сканы в async-хендлере самого горячего роута `/notify`

**Файл:** `ParanoiaServer/src/routes/notify.rs:237` (+ `store.rs:107-114`)

`count_new_for_user` — синхронный дисковый I/O: `receipt_state` (DB get + JSON-парс) + `count_after` (итератор, поштучно перебирающий **все** ключи с `seq > cursor`, включая tombstones после determinate-удалений). В multi-режиме это до 512 диалогов × 2 DB-операции × 3 прохода (fast-path, анти-гонка после подписки, после пробуждения) = до ~3000 блокирующих DB-вызовов на один long-poll запрос, выполняемых прямо на tokio-воркере без `spawn_blocking`.

`/notify` — самый частый запрос (каждый клиент раз в ~25 с); при множестве клиентов и/или больших бэклогах (устройство со старым курсором, тяжёлая компакция RocksDB) воркеры tokio блокируются и весь event loop сервера (включая push/pull/call-роуты) деградирует.

```rust
// notify.rs:236-237
for (partner, dialogue_id, seq) in pairs {
    match state.store.count_new_for_user(dialogue_id, *seq, sender) {

// store.rs:107-114 — count_after: поштучный скан ключей
for item in iter {
    ...
    count = count.saturating_add(1);
}
```

**План:**
1. Вынести `scan_pairs`/`count_new_for_user` в `tokio::task::spawn_blocking`.
2. Ускорить сам скан: для ответа «есть ли новые» достаточно O(1) reverse-seek `last_seq(dialogue_id) > max(after_seq, floor)`; точный счётчик считать только для «зажёгшихся» диалогов (или капнуть счёт, если клиенту важно лишь `n > 0`).

---

## 2. [MEDIUM] Синхронный `fs::write` конфига под удерживаемым tokio RwLock

**Файл:** `ParanoiaServer/src/routes/admin/server_config.rs:72` (также `users.rs:44-48`, `reg.rs:70-71`)

`Config::save` (`std::fs::create_dir_all` + `fs::write` — блокирующий диск-I/O) вызывается, пока удерживается `tokio::sync::RwLock` на config: в admin/config/set и admin/users/delete — под WRITE-локом, в `/reg` — под READ-локом. Пока write-лок держится через блокирующую запись на диск, **все** хендлеры сервера (push/pull/notify/blob — каждый начинает с `config.read().await` для проверки ключей) встают в очередь; при медленном диске это фриз всего трафика. Плюс сам блокирующий вызов занимает tokio-воркер без `spawn_blocking`.

```rust
// server_config.rs:53 → :72
let mut cfg = state.config.write().await;
...
if let Err(e) = cfg.save(&config_path()) {
```

**План:** сериализовать конфиг в строку под локом, отпустить гард и писать файл асинхронно:
```rust
let data = serde_json::to_string_pretty(&*cfg)?;
drop(cfg);
tokio::fs::write(path, data).await
```

---

## 3. [MEDIUM] Блокирующая запись/чтение чанков больших файлов в async-хендлере

**Файл:** `ParanoiaServer/src/routes/blob.rs:159, 177-179` (+ `store.rs:393-394`)

`ephemeral_put_chunk` / `ephemeral_get_chunk` — синхронные RocksDB put/get чанков эфемерных файлов (передачи до `large_file_max` = 2 ГиБ) — выполняются прямо на tokio-воркере внутри `pub async fn do_blob` без `spawn_blocking`. Запись крупного чанка может упереться в write-stall/компакцию RocksDB; при параллельной закачке несколькими клиентами блокируется по воркеру на чанк, и страдают соседние long-poll'ы и push/pull на тех же воркерах.

**План:** обернуть операции store в `tokio::task::spawn_blocking` (store уже `Arc` — move клон в замыкание). То же стоит сделать для `store.push`/`pull` в `push.rs`/`pull.rs`.

---

## 4. [LOW] prune: O(n²) SHA256 по всем парам пользователей + полный скан стора в async-хендлере

**Файл:** `ParanoiaServer/src/routes/admin/dialogues.rs:78-83, :54` (+ `store.rs:287`)

`valid_dialogue_ids` строит множество всех пар пользователей — n(n+1)/2 вычислений SHA256 (при 10 тыс. пользователей ~50 млн хешей, секунды чистого CPU), а `list_dialogues` итерирует **весь** RocksDB, материализуя значения всех пакетов (при гигабайтах истории — полное чтение базы). Оба вызова синхронные, в async-хендлере без `spawn_blocking`, и на всё это время занимают tokio-воркер, задерживая пользовательский трафик. Роут админский и редкий, поэтому severity low, но деградация затрагивает всех клиентов сервера.

```rust
for (i, a) in users.iter().enumerate() {
    set.insert(crypto::make_dialogue_id(a, a));
    for b in &users[i + 1..] {
        set.insert(crypto::make_dialogue_id(a, b));
    }
}
```
**План:** инвертировать проверку — не строить множество всех валидных пар, а для каждого `dialogue_id` из стора проверять принадлежность (для этого хранить/выводить участников); либо как минимум завернуть `list_dialogues` + `valid_dialogue_ids` в `spawn_blocking`.

!!!!Прунинг - редкая задача. Хранение участников диалога - неразумный ИБ компромис, поэтому решение Хуйня. Не рассматриваем.!!!!

---

## 5. [HIGH] publishServiceSnapshot: ffiMutex + чтение SQLCipher в цикле на GUI-потоке при каждом pull

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:2899-2906` (+ подключение `main.cpp:202`)

Слот `publishServiceSnapshot` выполняется на GUI-потоке и в цикле по **всем** диалогам всех сессий берёт `session->ffiMutex` и читает `last_pulled_seq` из SQLCipher (`store.rs:259` — SELECT, дисковый I/O через FFI). Подключён к `dialogsChanged`, `sessionsChanged`, `pollModeChanged` и `ChatBackend::pulledNewMessages` (`main.cpp:202`) — срабатывает на каждый батч входящих и любое изменение диалога, причём `pulledNewMessages` эмитится уже на GUI-потоке (доставлен через `invokeMethod`), т.е. соединение прямое, слот синхронный. Воркеры ChatBackend держат тот же `ffiMutex` на время сетевых операций (отправка текста `ChatBackend.cpp:677-692`, каждое фото мозаики на весь аплоад `:1097-1110`, resume-push `:2458-2467`, скачивание вложений) — при совпадении GUI встаёт на мьютексе до конца аплоада, на секунды. Комментарий в конструкторе (`:190` «дешёвый — просто read из RAM + JNI call») устарел и не соответствует коду.

```cpp
for (const Dialog &d : session->dialogs) { ...
    QMutexLocker lock(&session->ffiMutex);
    if (session->ffi) { session->ffi->last_pulled_seq(session->serverId, d.peerServerId, seq); }
```

**План:** кэшировать `last_pulled_seq` в RAM (ChatBackend знает актуальный seq после каждого pull — обновлять поле Dialog/сессии) и собирать снапшот без FFI; либо выносить сбор на QThreadPool-воркер с мгновенным копированием handle (паттерн уже есть: «сетевой poll — БЕЗ ffiMutex», `ChatBackend.cpp:2350-2356`).

---

## 6. [MEDIUM] Применение маскировки под ffiMutex на GUI-потоке (3 места)

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:1664` (также `:1570`, `:1605`)

Обработчик ответа `syncMaskingFromNode` (`:1664`), Q_INVOKABLE `resetMasking` (`:1570`) и `applyMaskingFromFile` (`:1605`) берут `session->ffiMutex` и вызывают `set_signed_masking_profile`/`set_masking_profile` прямо на GUI-потоке. `syncMaskingFromNode` запускается автоматически при логине (`:641`), `switchSession` (`:2761`) и после удаления профиля (`:2805`) — если воркер в этот момент держит `ffiMutex` на сетевой передаче/скачивании вложения (отправка `ChatBackend.cpp:677-692`, resume вложений `:2458-2467`), GUI зависает до её завершения. Пользовательские триггеры — клики на MaskingPage (`MaskingPage.qml:63` onAccepted файла, `:224` «Применить без проверки», `:247` «Вернуть встроенную»). `applyMaskingFromFile` дополнительно делает файловый I/O на GUI (`Utils::resolveImportPath` — копия content:// на Android, `Utils::readAll`). Сами FFI-сеттеры маскировки локальны и быстры — фриз только при контеншне с длинной передачей, потому medium. Сигнал `maskingApplied` уже существует и QML на него подписан — API можно сделать void.

```cpp
QMutexLocker locker(&session->ffiMutex);
if (!session->ffi) return;
rc = session->ffi->set_signed_masking_profile(QString::fromUtf8(body), trusted);
```

**План:** выносить взятие `ffiMutex` + `set_*_masking_profile` на QThreadPool-воркер (паттерн уже есть — `deleteDialogLocal`, `:1697`), результат отдавать сигналом; чтение файла в `applyMaskingFromFile` — тоже на воркер.

---

## 7. [MEDIUM] Синхронный saveDialogs (vault-FFI + полная перезапись dialogs.json) на GUI при каждой мутации диалога

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:2023` (вызовы также `:614`, `:1204`, `:1303`, `:2008`, `:2044`, `:2696`, `:2719`)

`session->saveDialogs()` сериализует **все** диалоги (включая base64-аватары каждого), шифрует через FFI `vault_encrypt_json` и пишет на диск (AEAD-seal + `fs::write` + `fs::rename`, `local_vault/io.rs:46`) — синхронно на GUI-потоке. Остаток известного фриза №40: чтение на логине уже перенесли на воркер (`preloadedDialogs`, `:591-592`), а все записи остались на GUI; в `ChatPage.qml:901-905` проблему `setDraft → saveDialogs` лечили только 600мс-дебаунсом, не выносом записи. Блокировка — миллисекунды-десятки мс на каждую мутацию (переименование, аватар, keyring, логин), на Android-флеше заметнее. QML-триггер пути `:2696` — подтверждение QR-обмена ключом (`QrExchangePage.qml:357`); показательно, что ветка updateExisting того же метода уже ходит на воркер за last_pulled_seq (`:1172`), а запись всё равно возвращается на GUI.

```cpp
dlg->avatar = b64;
session->saveDialogs();   // Dialog::saveToPath → Utils::writeFile → paranoia_vault_encrypt_json
```

**План:** сделать `saveDialogs` асинхронным: снимать копию `QList<Dialog>` по значению и выполнять сериализацию + vault_encrypt + запись на QThreadPool-воркере (последняя запись выигрывает), по образцу `doVaultChangePinAsync`.

---

## 8. [MEDIUM] importProfile: расшифровка, множественный vault-I/O и мерж диалогов синхронно в Q_INVOKABLE

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:2285-2505`

Всё тело `importProfile` выполняется синхронно на GUI-потоке: чтение файла (до `MaxExportFileBytes`), FFI `ecies_decrypt`, затем для каждого профиля бандла — по нескольку vault-шифрованных чтений/записей `client.json`/`corp.json` (`readJsonObjectFile`/`writeJsonObjectFile` → FFI + диск) и `Dialog::loadFromPath`/`saveToPath` (полная расшифровка/перешифровка `dialogs.json`). Вызывается из QML синхронно с использованием возвращаемого значения (`ImportProfilePanel.qml:28`, `ClientRegistrationPage.qml:134`) — на время импорта корпоративного бандла с десятками диалогов UI замирает без индикатора прогресса. Зона qml-pages-reg добавила: перед всем этим `Utils::resolveImportPath` (`:2291`) на Android делает полную JNI-копию content:// через ContentResolver — при облачном DocumentsProvider это сетевое чтение на GUI (риск ANR); ecies_decrypt к тому же может ждать глобальный FFI-мьютекс за long-poll'ом. Редкая, явно инициируемая пользователем операция — потому medium.

**План:** перенести тело в `QtConcurrent::run`, результат возвращать сигналом `importProfileFinished(QVariantMap)` — QML-потоки импорта уже событийные, UI сможет показать busy-индикатор (как для `vaultChangePin`).

---

## 9. [MEDIUM] deleteProfile: рекурсивное удаление каталога профиля на GUI-потоке

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:2789`

Q_INVOKABLE `deleteProfile` синхронно вызывает `QDir::removeRecursively()` на весь каталог профиля, включая attachment-cache (гигабайты, тысячи файлов). На мобильном flash — секунды фриза UI (на Android риск ANR). Показательно, что для того же кэша `clearCaches()` (`:1872-1876`) удаление уже вынесено на QThreadPool-воркер — deleteProfile остался несогласованным. Зона qml-main-pages добавила второй тяжёлый шаг того же пути: `removeSession` + выход локального shared_ptr из скоупа роняют последний ref сессии прямо на GUI → `paranoia_client_free` / закрытие SQLCipher-БД с WAL-checkpoint (`:2773-2775`) — ровно тот teardown, который для vaultChangePin осознанно вынесен в воркер (`doVaultChangePinAsync`, `:344-357`).

```cpp
// 3) Удалить данные профиля с диска (диалоги/ключи/БД/вложения).
QDir(Paths::profileDir(profileId).absolutePath()).removeRecursively();
```

**План:** удалять каталог на QThreadPool-воркере (как в `clearCaches`/`selfDestruct`); шаги 4-6 (обновление UI-состояния) выполнять сразу — запись из манифеста удаляется до шага 3 (`:2779-2786`), порядок безопасен.

---

## 10. [MEDIUM] storageBreakdown: рекурсивный обход всех файлов данных на GUI-потоке

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:1833-1853`

Q_INVOKABLE `storageBreakdown()` синхронно обходит `QDirIterator(..., Subdirectories)` attachment-cache всех профилей (`:1844`) и весь CacheLocation (`:1853`), суммируя размеры (stat каждого файла, `treeSizeBytes:1762-1774`). Вызывается из GUI при открытии «Управления данными» (`DataManagementPage.qml:31 → :17`) — при тысячах вложений на мобильном flash заметный фриз, но путь редкий (не горячий).

**План:** сделать подсчёт асинхронным: `QtConcurrent::run` + сигнал `storageBreakdownReady(QVariantList)`; в QML — спиннер до прихода данных.

---

## 11. [MEDIUM] bakeCircleAvatarBase64: декод полноразмерного фото и SAF-копия на GUI-потоке

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:1970-1977`

Q_INVOKABLE `setDialogAvatar`/`setProfileAvatar` синхронно вызывают `bakeCircleAvatarBase64`: `Utils::resolveImportPath` (на Android — JNI-копия content:// файла в кэш на весь размер фото) и `QImage img(localPath)` — полный декод исходника (12-МП снимок ≈ 48 МБ битмапа), и только потом масштабирование до 64×64. Следом на том же потоке `saveDialogs()`/`updateProfileManifestEntry` (см. п. 7). Сотни миллисекунд фриза при выборе аватара на телефоне; единичное пользовательское действие — потому medium.

```cpp
const QString localPath = Utils::resolveImportPath(fileUrl);
...
QImage img(localPath);
const QImage scaled = img.scaled(kSide, kSide, ...);
```

**План:** выполнять bake на QThreadPool-воркере (результат сигналом/через `QFutureWatcher`); при декоде использовать `QImageReader::setScaledSize`, чтобы декодировать сразу в малый размер, а не грузить полный битмап.

---

## 12. [HIGH] ChatBackend: синхронный saveDialogs (vault-FFI + запись на диск) на GUI при каждом батче сообщений

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:2784` (также Q_INVOKABLE-пути `:1921`, `:2125`, `:2151`)

`appendMessages` всегда исполняется на GUI-потоке (все вызовы из воркер-лямбд приходят через `QMetaObject::invokeMethod(self, …)` — `:724`, `:810-813`, `:978`, `:1067`, `:1118`, `:2015`, `:2089`, `:2474`, `:2549`, `:2580`) и в конце безусловно, без dirty-check, зовёт `session->saveDialogs()`: сериализация ВСЕХ диалогов профиля (включая keyring'и) → FFI `vault_encrypt_json` → запись на диск. Срабатывает на каждый приход сообщений, каждый инкрементальный refresh (loadHistory(false) всегда передаёт непустое окно), каждый коммит отправки. Тот же синхронный вызов — в Q_INVOKABLE `setDraft` (`:2125`), `setLastTopic` (`:2151` — каждое переключение чипа темы) и `setReadReceiptsEnabled` (`:1921`). Симптом известен и лечился со стороны QML 600мс-дебаунсом («шифрование диалогов под ffiMutex на GUI-потоке → залипания при печати», `ChatPage.qml:903-904`, `:4687`) — корень не убран. Родственная находка по MainBackend-вызовам — п. 7. Зона qml-chat независимо подтвердила QML-сторону пути: selectTopic зовёт setLastTopic на каждый тап по чипу (`ChatPage.qml:3109`) и из ScriptAction посреди слайд-анимации тем (`:3166`) — джанк гарантирован прямо в кадрах анимации; черновик — draftSaveTimer 600 мс (`:908`) → saveDraft (`:842`; также при закрытии/деактивации `:1845`, `:1862`).

```cpp
// ChatBackend.cpp:2784 — конец appendMessages
session->saveDialogs();   // Dialog::saveToPath → Utils::writeFile → paranoia_vault_encrypt_json
```

**План:** вынести `saveDialogs` из appendMessages на воркер (образец — login-путь `MainBackend.cpp:614`, где dialogs шифруются на воркере) и/или дебаунсить (lastMsg/lastActivityMs — не чаще раза в N секунд); для setDraft/setLastTopic — асинхронная запись через QThreadPool с коалесингом. Общий фикс с п. 7 (асинхронный saveDialogs) закрывает оба пункта.

---

## 13. [HIGH] parseMessages разбирает JSON полной истории на GUI-потоке (вплоть до всей истории диалога)

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:2543` (также `:2012`, `:2629`)

`loadHistory` получает от FFI JSON окна в 2000 сообщений (`history_keyring(...,2000)`, `:2535`) на воркере, но парсит его в лямбде, замаршаленной на GUI-поток: `QJsonDocument::fromJson` мегабайтного JSON + сборка ~30-ключевых QVariantMap на каждое сообщение (`parseMessages`, `:2809-2913`). Хуже в `loadAllForAttachments`: лимит 1000000 = вся история диалога (`:2624`), парс тоже на GUI (`:2629`) — комментарий «GUI не блокируется» верен только про дешифр. `fetchMessages` — аналогично (`:2012`). Путь горячий: `loadHistory(peer,false)` дёргается на каждый read-receipt/готовность превью/сохранение вложения (`:1214`, `:1321`, `:1474`, `:2434`) и при открытии диалога (`:398`) — десятки-сотни мс пропущенных кадров на мобильных. Контраст: `prefetchAllDialogs` уже вызывает parseMessages на воркере (`:2067-2080`) — метод де-факто потокобезопасен (EncryptedImageProvider::contains под mutex).

**План:** парсить JSON на воркере до invokeMethod (по образцу prefetchAllDialogs), на GUI передавать готовый QVariantList.

---

## 14. [MEDIUM] ChatPage: синхронное создание MediaPlayer+AudioOutput (и компиляция вьюеров) при каждом открытии диалога

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:1771-1784`

`Component.onCompleted` страницы синхронно (`Component.PreferSynchronous`) компилирует CallPage/VideoViewer/VoicePlayer, а VoicePlayer сразу инстанцирует (`createObject` → MediaPlayer + AudioOutput) — на КАЖДОЕ открытие чата (ChatPage пересоздаётся при каждом входе, `Main.qml:413-418`), даже если голосовых в диалоге нет; первый экземпляр ещё и инициализирует медиа-бэкенд. Всё это до первого кадра push-анимации — тщательная отсрочка openChat за frameSwapped частично обесценивается. Поправки верификатора: CallPage и QtMultimedia уже синхронно загружены на старте приложения (`Main.qml:188-197`), так что `createComponent("CallPage.qml")` здесь кэш-хит движка (и дубль `appWindow.callPageComponent` из `Main.qml:583`); главный per-open вклад — инстанцирование MediaPlayer+AudioOutput.

```qml
root.callPageComponent = Qt.createComponent(Qt.resolvedUrl("CallPage.qml"), Component.PreferSynchronous);
…
var vpc = Qt.createComponent(Qt.resolvedUrl("../Components/VoicePlayer.qml"), Component.PreferSynchronous);
if (vpc.status === Component.Ready) root.voicePlayer = vpc.createObject(root);
```

**План:** перейти на `Component.Asynchronous` (все точки использования уже защищены проверками `status !== Component.Ready` — `:369-370`, `:2741`, `Main.qml:588`); VoicePlayer создавать лениво при первом toggleVoice (он null-безопасен, `:388`); дубль callPageComponent убрать в пользу `appWindow.callPageComponent`.

---

## 15. [LOW] rekey_db/rekey_file держат vault-локи на всё время перешифровки (гигиена, не фриз)

**Файл:** `ParanoiaLibrary/src/local_vault/vault.rs:453-487` (также `:415-426`, `:433-446`)

`rekey_db` берёт `PENDING.read()`+`VAULT.read()` и держит их через stage_backup (копия .db+WAL+SHM) и `PRAGMA rekey` (полная перезапись каждой страницы messages.db); `rekey_file`/`rekey_attachment` — на чтение+перешифровку+запись целого файла (вложения до десятков МБ). Верификатор существенно сузил заявленный эффект: rekey идёт на воркере, перед ним ВСЕ сессии снесены (`MainBackend.cpp:348-354`), auto-lock в фоне осознанно отключён («Lock ТОЛЬКО при выходе», `:196-198`), guard держится на один шаг. Остаточный риск: выход/self-destruct во время смены PIN подождёт завершения текущего шага.

**План:** копировать db_key/json_key/files_key в локальные Zeroizing-буферы и дропать guard'ы ДО открытия соединения и дискового I/O — дёшево и снимает остаточную блокировку.

---

## 16. [LOW] Синхронный дисковый I/O внутри async-методов Dialogue — блокирует tokio-LocalSet MCP-сервера EasyCli

**Файл:** `ParanoiaLibrary/src/dialogue.rs:979` (также `:1002`, `:1018`, `:1046`, `:1577-1625`, `:775-783`)

async-методы делают блокирующий I/O между await'ами: `fs::read` целого sealed-вложения (`cache_attachment_bytes`), `write_bytes_atomic`/`fs::copy` целых файлов, синхронные `store.*`-запросы. В клиенте безвредно (block_on на потоке вызывающего), но async-хост существует: MCP-сервер EasyCli живёт на однопоточном tokio `LocalSet` (`mcp_server.rs:212`, spawn_local `:288`) и await'ит `download_attachment` (`:1179`) — блокирующий дисковый I/O стопорит ВЕСЬ LocalSet, включая channel_push_loop (пулер/доставка). Смягчение: операции с вложениями через MCP редки, блокировка — десятки-сотни мс.

**План:** крупные fs-операции и сборку вложений обернуть в `tokio::task::spawn_blocking` (или дать async-хостам блокирующие обёртки); мелкие store-запросы можно оставить.

---

## 17. [MEDIUM] Блокирующие D-Bus вызовы уведомлений на GUI-потоке (Linux desktop)

**Файл:** `ParanoiaUiClient/src/platform/LinuxNotifier.cpp:34` (также `:22`, `:55-60`)

`showMessageCount` и `closeCurrent` исполняются на GUI-потоке (DesktopTray создан в main(), connect'ы `main.cpp:308-311`). Каждый вызов конструирует новый `QDBusInterface` — конструктор делает синхронную интроспекцию удалённого объекта по шине — затем блокирующий `iface.call()` (QDBus::Block, таймаут 25 с). Если демон уведомлений (KDE/GNOME) занят или завис — GUI встаёт до 25 с; `closeCurrent` вызывается из clearAccumulatedNotifications ровно в момент выхода приложения на передний план. Та же блокирующая интроспекция — в конструкторе при старте (`:22`). В норме демон отвечает за миллисекунды — потому medium.

**План:** асинхронные вызовы: `QDBusMessage::createMethodCall` + `asyncCall()` с QDBusPendingCallWatcher для id из Notify; CloseNotification — через send()/NoBlock (ответ не используется). Интерфейс не пересоздавать на каждый показ.

---

## 18. [MEDIUM] InstallServerBackend: QThread::usleep(1000) — задуманная пауза перед проверкой сервера фактически отсутствует

**Файл:** `ParanoiaUiClient/src/backend/InstallServerBackend.cpp:111`

В `on_scriptFinished` (слот на GUI-потоке: QML_ELEMENT, инстанцирован декларативно) перед проверкой только что установленного сервера стоит `QThread::usleep(1000)` — это **1 миллисекунда** (usleep принимает микросекунды): паузы «дать серверу подняться» нет, `regUser` может уйти раньше, чем systemd-сервис начал слушать порт → установка флапает «Error on check server». Механическое исправление единиц (`usleep(1'000'000)`) заморозило бы GUI на секунду — приём sleep в слоте здесь непригоден в принципе. Реального фриза сейчас нет (1 мс) — проблема функциональная.

**План:** убрать usleep; проверку выполнять через `QTimer::singleShot(1000-3000 мс)` либо ретраями regUser по таймеру до успеха/таймаута.

---

## 19. [LOW] iOS: JPEG-кодирование выбранного фото на главном потоке

**Файл:** `ParanoiaUiClient/src/platform/IosImagePicker.mm:82-85` (`writeTempJpeg` `:50-54`)

completionHandler пикера (выполняется на фоновой очереди провайдера) делает `dispatch_async` на main queue и уже ТАМ вызывает `writeTempJpeg`: `UIImageJPEGRepresentation(image, 0.9)` (полное перекодирование снимка 12-48 МП, 100-500 мс) + запись файла — прямо во время анимации закрытия пикера; на iOS main queue = GUI-поток Qt. Кодировать можно в самом completionHandler (UIImageJPEGRepresentation потокобезопасен), на main диспатчить только finish(). Путь холодный (выбор аватара) — low.

**План:** writeTempJpeg выполнять в completionHandler/global queue, на main — только `finish(delegate, path)`.

---

## 20. [HIGH] Hunspell-словари (~4 МБ) грузятся синхронно на GUI-потоке при каждом открытии чата

**Файл:** `ParanoiaUiClient/src/spell/SpellHighlighter.cpp:178` (`:75`; `SpellChecker.cpp:105`; `ChatPage.qml:4691`)

`SpellSyntaxHighlighter` владеет собственным `SpellChecker m_checker` по значению, а конструктор SpellChecker безусловно зовёт `Impl::load()` → `Hunspell_create` для ru_RU (.dic 3.48 МБ + .aff 71 КБ) и en_US (.dic 551 КБ) — парсинг ~100-400 мс, плюс файловый I/O в ensureBundledDictionaryFile. ChatPage пересоздаётся на каждый вход в диалог (`Main.qml:371`, `:413`) → каждый вход в чат на десктопе = повторная загрузка обоих словарей на GUI-потоке. Словари не кэшируются и не разделяются между инстансами; загрузка идёт даже при enabled=false (setEnabled вызывается после конструирования, `:180`).

**План:** шаренный синглтон SpellChecker (или пул словарей по локали) с ленивой загрузкой на фоне (QtConcurrent + сигнал availableChanged); SpellSyntaxHighlighter берёт готовые handle; при enabled=false загрузку не запускать вовсе.

---

## 21. [MEDIUM] decodeFromImage: чтение файла и полноразмерный ZXing-декод синхронно на GUI-потоке

**Файл:** `ParanoiaUiClient/src/utils/QrCodeUtils.cpp:50-64`

Q_INVOKABLE `decodeFromImage` вызывается прямо из `FileDialog.onAccepted` (`RegisterUserPage.qml:34`, `ClientRegistrationPage.qml:121`, `QrExchangePage.qml:56`) и на GUI-потоке: полный декод изображения с диска (фото 12-48 Мп), конверсия в Grayscale8, `ZXing::ReadBarcodes` с TryHarder+TryRotate+TryInvert по ПОЛНОМУ разрешению — секунды фриза на большом фото. Соседний путь камеры всё делает правильно: даунскейл до 1280 px + QtConcurrent (`QrCameraScanner.cpp:218`, `:236`). Вдобавок ZXing-блок скопипащен между двумя файлами (`:53-64` ≈ `QrCameraScanner.cpp:240-256`). Путь редкий (импорт QR из файла) — medium.

**План:** декод в QtConcurrent::run с результатом сигналом + даунскейл до ~1280 px; общий хелпер decodeQr(QImage) для обоих путей.

---

## 22. [MEDIUM] Вставка картинки из буфера: двойное извлечение изображения и синхронное PNG-кодирование на GUI

**Файл:** `ParanoiaUiClient/src/utils/ClipboardUtils.cpp:32` (`:17`, `:24`; `ChatPage.qml:4829-4834`)

Обработчик Ctrl+V сначала зовёт `hasImage()`, где `!cb->image().isNull()` форсит полную передачу изображения из системного буфера (на X11 — синхронный IPC-трансфер, 4K-скриншот — десятки МБ), затем `saveImageToTemp()` извлекает то же изображение ВТОРОЙ раз (Qt не кэширует конверсию) и синхронно кодирует в PNG на GUI-потоке — сотни мс компрессии. Заметный фриз при каждой вставке скриншота; desktop-only, разовое действие — medium.

**План:** извлекать QImage один раз; PNG-кодирование и запись — в QtConcurrent::run, путь отдавать сигналом и там вызывать sendFile; hasImage ограничить `mimeData()->hasImage()` без полного трансфера.

---

## 23. [HIGH] Декод входящего H.264-видео выполняется на GUI-потоке (до 30 кадров/с)

**Файл:** `ParanoiaUiClient/src/voip/CallEngine.cpp:899` (`:50`, `:802-927`, `:909`; `H264Codec.cpp:60-62`, `:458`)

`enqueueIncomingVideoFragment` приходит через `invokeMethod(Queued)` на CallEngine, живущий в GUI-потоке (член VoipSystem, созданного в main; moveToThread нет). В слоте синхронно: реассемблинг NAL, `h264_decoder_->decode()` (на Linux/Windows — чисто программный FFmpeg, 2-20 мс/кадр; hw-декод только mac/android) и `getDecoded()` с sws_scale-конверсией в I420 + копией до ~3 МБ. При 30 fps — 100-600 мс работы В СЕКУНДУ на главном потоке: UI звонка дёргается, тач-события лагают, страдает точность 20-мс аудио-таймера onJitterTick в том же потоке (щелчки в звуке).

**План:** вынести реассемблер + H264Decoder в отдельный QThread-воркер (moveToThread, фрагменты слать в него напрямую из FFI-колбэка); в GUI отдавать только готовый кадр — `VideoSinkBridge::setI420Frame` уже умеет маршалить из любого потока; generation-проверку оставить в воркере.

---

## 24. [HIGH] Кодирование исходящего видео и avfilter-конвейер камеры выполняются на GUI-потоке

**Файл:** `ParanoiaUiClient/src/voip/VideoCapture.cpp:247` (`:425`, `:451`, `:467-499`; `CallEngine.cpp:531`, `:774`)

VideoCapture живёт в GUI-потоке (parent — CallEngine), `videoFrameChanged` эмитится из потока мультимедиа-бекенда → авто-connect queued → `onVideoFrame` исполняется в GUI. Там на каждый кадр камеры: process libavfilter-графа (format+transpose+scale+pad), построчная копия I420 в packed (~1.4 МБ) + вторая полная копия в preview-QVideoFrame, затем прямым connect'ом `CallEngine::onCameraFrameI420` — H.264-энкод (libx264 veryfast/libopenh264, 5-30 мс/кадр 720p) + фрагментация + FFI push. При 30 fps GUI получает 300-900 мс видеоработы в секунду — устойчивый джанк на протяжении всего видеозвонка.

**План:** перенести VideoCapture + H264Encoder в выделенный рабочий QThread (кадры от QVideoSink и так приходят из чужого потока — очередь сменит адресата); в GUI оставить только preview.

---

## 25. [MEDIUM] CallSignalingClient::stop() блокирует GUI до 3 секунд, пока воркер сидит в 25-секундном long-poll

**Файл:** `ParanoiaUiClient/src/voip/CallSignalingClient.cpp:150-151` (`:190`; вызов `VoipSystem.cpp:245`)

`stop()` делает `thread_.quit()` + `thread_.wait(3000)`, но workerLoop — слот в event loop потока: quit() подействует только после возврата из workerLoop, а тот заблокирован в FFI `callPoll(..., 25000)` без per-handle отмены → wait почти всегда высиживает полные 3 секунды. Вызов идёт с GUI (refreshBindings при выходе из профиля/смене сессии + деструктор) → фриз интерфейса на 3 с. Бонус: после таймаута поток жив, повторный start() ставит второй workerLoop в очередь (зомби-цикл, серийно).

**План:** не ждать синхронно: выставлять stop_ и повышать config_generation_ (результат poll'а и так отбрасывается), wait() — только на выходе приложения после `begin_shutdown` (он отменяет long-poll'ы); либо per-handle отмена в FFI.

---

## 26. [MEDIUM] setTurnPeer на GUI-потоке выполняет блокирующий DNS-резолв TURN-хоста

**Файл:** `ParanoiaUiClient/src/voip/CallController.cpp:1234` (также `:870`; Rust `voip_ffi.rs:1201`)

`promoteBestPath` (GUI: из onProbeResult/onTurnRelayReady/onAnswer) зовёт `engine_->setTurnPeer(server, relay)`, а Rust-сторона первым делом делает `server_s.to_socket_addrs()` — синхронный getaddrinfo hostname'а TURN-сервера на потоке вызывающего. При деградировавшем DNS (ровно когда включается TURN-фейловер!) — блокировка GUI на секунды (таймаут резолвера ~5 с). Смягчение: turnAllocate прямо перед этим греет системный DNS-кэш в QtConcurrent — в типичном случае резолв мгновенный.

**План:** кэшировать резолвленный SocketAddr после turnAllocate (на воркере) и передавать в setTurnPeer числовой адрес; либо весь setTurnPeer в QtConcurrent с колбэком.

---

## 27. [MEDIUM] changeProfileServer: синхронный teardown сессии и серия vault-операций в onClicked

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:2141-2192` (вызов `ProfileSettingsPage.qml:326`)

`Backend.changeProfileServer` вызывается синхронно из onClicked подтверждающего попапа, и на GUI-потоке происходит: removeSession с дропом последнего shared_ptr → `paranoia_client_free` / закрытие SQLCipher с WAL-checkpoint; `QDir::rename` каталога профиля; и ~5 FFI-расшифровок + ~4 шифрования vault-файлов (profileManifestEntry ×2, loadProfilesManifest+write, upsert, update, чтение/запись client.json) — каждая операция заново читает-пишет один и тот же profiles.json (см. `02-redundant.md` п. 25). Сам перелогин уже уходит в воркер — фриз именно в перечисленном до него. Операция редкая — medium.

**План:** валидации оставить синхронными; teardown, rename и правку манифеста — в воркер с результатом-сигналом (QML уже показывает feedbackText); правки манифеста объединить в одну read-modify-write.

---

## 28. [MEDIUM] Синхронная загрузка CallPage (QtMultimedia) на старте приложения

**Файл:** `ParanoiaUiClient/ui/Main.qml:193-194`

В Component.onCompleted главного окна CallPage.qml (472 строки) компилируется с `Component.PreferSynchronous` — вместе с первой загрузкой плагинов QtMultimedia (на Android — FFmpeg-бэкенд) и QtQuick.Effects, синхронно на GUI до показа первого кадра: удлиняет холодный старт на мобильных. Компонент нужен только к первому звонку; единственный потребитель onIncomingCall уже имеет guard на `status !== Component.Ready` — асинхронная загрузка ложится в существующую логику. Связано с 01 п. 14 (дубль этой же компиляции в ChatPage).

**План:** `Component.Asynchronous` сразу после старта; в onIncomingCall при status===Loading дождаться statusChanged перед push.

---

## 29. [LOW] Экспорт профиля: ECIES-шифрование и запись файла (SAF) синхронно на GUI-потоке

**Файл:** `ParanoiaUiClient/ui/Pages/ExportImportPage.qml:81` (`MainBackend.cpp:2197-2280`)

onAccepted диалога сохранения синхронно вызывает `Backend.exportProfile`: сборка JSON, ECIES-шифрование через FFI (`:2268`) и запись `Utils::writeBytesToTarget` (`:2275`) — на Android для content:// это временный файл + JNI-копирование через ContentResolver (целевой DocumentProvider может быть облачным → сетевой I/O на GUI). Редкое разовое действие, объём мал — low.

**План:** exportProfile на воркер, результат — сигналом exportFinished(QVariantMap); кнопку блокировать до сигнала.

---

## 30. [HIGH] push_opus/push_h264: блокирующий block_on(send) в bounded-канал на GUI-потоке (потенциально удалённо-триггерируемый фриз)

**Файл:** `ParanoiaLibrary/src/voip_ffi.rs:1345` (`:1401`; ёмкости `:855`, `transport.rs:429`)

`paranoia_call_session_push_opus/push_h264` отправляют фрейм через `rt.block_on(sender.send(...))` — блокирующее ожидание в ограниченный mpsc-канал (128) на потоке вызывающего, а вызывающий — GUI (слоты CallEngine: push_opus каждые 20 мс, push_h264 на каждый фрагмент NAL). Собственный комментарий transport.rs: «один кадр может дать до ~857 фрагментов при I-frame» — видеоканал ёмкостью 128 гарантированно заполняется на каждом крупном I-frame, и GUI ждёт в block_on, пока run_session выкачает канал по сетевому темпу. Выкачка — по одному пакету за итерацию biased-select с приоритетом ПРИЁМА (`transport.rs:656-661`): при флуде входящих (в т.ч. не проходящих расшифровку — они тоже съедают итерации) дренаж стопорится, таймаута у block_on нет — **флуд UDP на известный endpoint звонка = удалённо триггерируемое зависание GUI**. Даже в хорошей сети каждый I-frame даёт периодический стоп GUI на время отправки сотен пакетов. Асимметрия: RX-сторона уже делает `try_send` с дропом при Full (`transport.rs:561-566`). Плюс lock+clone sender'а на каждый пакет.

**План:** заменить block_on(send) на `try_send` (реал-тайм семантика: при Full — дроп voice-фрейма, симметрично RX); для видео — передавать целый NAL одним сообщением и фрагментировать внутри run_session (или углубить канал); кэшировать outbound_sender в ParanoiaCallSession.

---

## 31. [MEDIUM] EasyCli MCP: fsync и блокирующий файловый I/O на единственном потоке сервера

**Файл:** `ParanoiaEasyCli/src/mcp_server.rs:127` (`:80`, `:140`, `:535`, `:1199-1216`; LocalSet `:207-218`)

Весь MCP работает на одном потоке (LocalSet + spawn_local, futures !Send) — любой синхронный блок в любой задаче стопорит ВЕСЬ event loop, включая чтение stdin и ответы на ping (ровно то, ради чего tools/call выносили в отдельные задачи). Блокирующие места: `DurableLog::persist` — open/writeln/flush + `f.sync_all()` (fsync) на каждую пачку новых сообщений (из tool_receive/tool_wait/channel_push_loop); `tool_history`/`load_seen` читают весь messages.jsonl (боевой уже 3 МБ); save_cursor/save_topic_binding — синхронные json-записи; `tool_provision` синхронно гоняет Argon2id (64 МиБ, t=3) под write-lock vault. Долгий fsync/Argon2 → сервер не отвечает на ping → харнесс считает его мёртвым (наблюдавшийся «STDIO connection dropped» с респауном). Родственно п. 16 (sync-I/O внутри async-методов Dialogue — бьёт по тому же LocalSet).

**План:** persist/чтение лога/sync_from_ui_core — в `spawn_blocking` (данные Send); минимум — убрать sync_all (append-лог с дедупом по id переживает потерю хвоста) и читать хвост файла вместо полного парса.

---

## 32. [HIGH] ⭐ КОРНЕВАЯ: конвой всех операций на ffiMutex построен на ложной предпосылке — хэндл фактически Send+Sync

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:929-942` (комментарий-предпосылка `:2458-2459`; Rust: `ffi.rs:222-231`, `lib.rs:39-43`, `store.rs:44-46`, `transport.rs:151-159`)

Сквозная цепочка (sweep): QML → sendFile на воркере берёт `session->ffiMutex` и держит его на ВСЁ время передачи — а Rust-сторона перед пушем ещё делает полный receive() (см. `02` п. 19), т.е. лок = «полный синк + аплоад целиком», на мобильном аплинке минуты (эфемерный блоб до 2 ГиБ чанками по 512 КиБ); мозаика — по-фото. Всё это время в очереди на том же мьютексе: отправка текста (`:677`), приём (`:1981`), открытие истории любого чата (`:2523`), превью (`:1448`), сохранение вложений (`:1190`), удаления (`:1817`) — **мессенджер функционально мёртв до конца аплоада**, а GUI дополнительно встаёт в точках из пп. 5/6 (publishServiceSnapshot, маскировка).

**Ключевое:** обоснование сериализации — комментарий «handle !Send, операции на нём сериализуются» — фактически неверно. `ParanoiaHandle` = ParanoiaClient{Arc, Arc, Arc} + tokio Runtime + Mutex<Option<String>>; LocalStore.conn — Mutex<Connection>, Transport — reqwest::Client+RwLock (ClientCover: Send+Sync); negative-impl нет → хэндл **автоматически Send+Sync**, Runtime многопоточный, конкурентные block_on легальны. Код УЖЕ зовёт хэндл конкурентно без ffiMutex из четырёх мест прода (ActiveChatNotifier long-poll 25 с — с комментарием «общий мьютекс заморозил бы UI», pollActiveChat `:2350-2358`, NotificationCoordinator `:350-359`, CallSignalingClient) — и это корректно именно потому, что хэндл Sync. Единственная реальная причина общего лока — компоновка `set_active_topic → send_*` (тема как состояние хэндла, `:937`, `:1062`, `:1104`). Огрублённая критсекция «вся сеть под локом» — не осознанная необходимость, а следствие устаревшего предположения; она же — корень конвоев из пп. 1 (cpp-main-session), 5, 6, 8 и 02 п. 8.

**План:** (1) FFI send-варианты с явным параметром темы (слот active_topic уже есть) — убрать компоновку set_active_topic→send из-под лока; (2) длинные сетевые операции (send_file*, send_photo_grouped*, receive, resume, save_attachment, history) выполнять БЕЗ per-session ffiMutex; при необходимости — узкий лок только на исходящие push'ы одного диалога (порядок seq); (3) ffiMutex оставить лишь для защиты указателя session->ffi (как в «мгновенных» локах копирования handle); (4) поправить вводящие в заблуждение комментарии «handle !Send». Закрывает минутные стопы отправки/приёма/истории при аплоадах и корень большинства ffiMutex-конвоев.