# Лишние операции

Двойная работа, лишние копирования и линейные сканы там, где возможен O(1).

---

## 1. [MEDIUM] ParaInput: скрытый двойник поля ввода синхронизируется на каждом нажатии клавиши

**Файл:** `ParanoiaUiClient/ui/Components/ParaInput.qml:32`

Компонент всегда инстанцирует **оба** контрола — однострочный `TextField` (field) и многострочный `TextArea` (multiField); видим только один (по `lineCount`, который фиксирован для каждого места использования). При этом `onTextChanged` корня записывает текст в оба контрола, а `onTextChanged` каждого контрола пишет обратно в `root.text`. В итоге каждое нажатие клавиши в видимом поле прогоняет полную установку текста и перелайаут текстового документа в невидимом двойнике (`visible: false` отключает только рендер, не обработку текста). Для длинных многострочных вставок это удвоение O(n)-работы на каждый ввод; плюс лишний контрол живёт в памяти в каждом ParaInput приложения.

```qml
onTextChanged: {
    if (field.text !== root.text) field.text = root.text
    if (multiField.text !== root.text) multiField.text = root.text
}
```

**План:** синхронизировать только активный контрол — в `root.onTextChanged` ветвить по `lineCount` (`if (root.lineCount <= 1) field.text = ... else multiField.text = ...`). Ещё лучше — грузить нужный контрол через `Loader` по `lineCount`, тогда второй вообще не создаётся.

---

## 2. [MEDIUM] Двойная (де)сериализация и копирование всех payload'ов в ответе `/pull`

**Файл:** `ParanoiaServer/src/schema_cover.rs:164-169` (+ `routes/pull.rs:95-103`)

Горячий путь выдачи истории делает лишние проходы по данным: `store.pull` копирует каждый payload (`val_bytes.to_vec()`), `pull.rs` кодирует его в base64 и упаковывает в нетипизированный `serde_json::Value`, а затем `SchemaCover::wrap_pull_response` разбирает этот Value обратно (`item.get("seq")`/`get("payload")`) и клонирует каждую base64-строку через `to_string()` в `PacketCore`, после чего снова сериализует. Для pull с сотнями сообщений / мегабайтными вложениями это удвоение аллокаций и копий всего трафика на каждый запрос. `FoodDeliveryCover` делает аналогичный повторный проход по Value.

(Сам cover-слой — осознанная фича маскировки; лишняя здесь только повторная (де)сериализация, не оборачивание как таковое.)

```rust
arr.iter().filter_map(|item| {
    Some(PacketCore {
        seq: item.get("seq")?.as_u64()?,
        payload: item.get("payload")?.as_str()?.to_string(),
    })
})
```

**План:** сделать `pull::ApiResponse` типизированным (`Vec<PacketCore>` или `Vec<(u64, String)>`) вместо `message: Value` — тогда cover-слой оборачивает готовые структуры без повторного парса и клонов; в `FoodDeliveryCover` перекладывать поля move'ом.

---

## 3. [MEDIUM] TURN: O(n)-скан всех аллокаций под глобальным мьютексом на каждый media-пакет

**Файл:** `ParanoiaServer/src/voip_stun.rs:536-538`

`handle_send` вызывается на каждую Send Indication (десятки пакетов в секунду на направление звонка) и под глобальным `Mutex allocations` линейно перебирает все аллокации в поисках локального адресата по `relayed_addr`. При N одновременных звонков каждый аудио/видео-пакет через relay стоит O(N) под общим локом — контеншн растёт квадратично с числом звонков и добавляет джиттер в путь реального времени. Вдобавок `parse_message` уже скопировал DATA-атрибут в `Vec`, а `build_data_indication` копирует его ещё раз.

```rust
let mut guard = allocations.lock().await;
let local_destination = guard.iter().find_map(|(client, allocation)|
    (allocation.relayed_addr == peer).then_some(*client));
```

**План:** держать второй индекс `HashMap<SocketAddr /*relayed_addr*/, SocketAddr /*client*/>`, обновляемый при создании/удалении аллокации, — поиск локального адресата станет O(1). Продление `expires_at` писать без удержания лока на время `send_to` (уже так); рассмотреть `RwLock`/шардирование.

---

## 4. [MEDIUM] Двойной fetchCorporateRoster (два HTTP-запроса) при каждом логине

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:645` (+ connect `:184-185`)

В конструкторе `activeSessionChanged` подключён к `fetchCorporateRoster` (`:184-185`). В GUI-продолжении `loginClientInternal` вызов `store->setActiveSession(session)` (`:635`) уже эмитит `activeSessionChanged` (сессия свежесозданная — сигнал гарантирован) и запускает загрузку ростера, после чего на `:645` `fetchCorporateRoster()` вызывается ещё раз явно. Guard'а на in-flight запрос в `fetchCorporateRoster` нет (`:1363-1422`) — два параллельных `corp_fetch_roster` HTTP-запроса на каждый корпоративный логин/активацию профиля, каждый со своими побочными эффектами (`applyCorporateSelfName`/`applyCorporateRosterNames` с записью конфигов; при первом входе — двойной `corp_fetch_dialogue` для аккаунта компании: итоговый upsert идемпотентен, но сеть и работа задвоены). Аналогично задвоен `emit loginStateChanged` (connect `:178` + явный emit `:637`). Путь не горячий (раз на логин), для некорпоративных профилей оба вызова отсекаются почти бесплатно.

```cpp
connect(SessionStore::instance(), &SessionStore::activeSessionChanged,
        this, &MainBackend::fetchCorporateRoster);          // :184-185
...
store->setActiveSession(session);   // :635 — уже эмитит activeSessionChanged
...
self->fetchCorporateRoster();       // :645 — второй запуск
```

**План:** убрать явный `self->fetchCorporateRoster()` (и явный `emit loginStateChanged`) из `loginClientInternal` — connection на `activeSessionChanged` уже покрывает этот путь; либо наоборот, оставить только явные вызовы и убрать connection, но не оба сразу. Дополнительно — guard на in-flight запрос внутри `fetchCorporateRoster`.

---

## 5. [MEDIUM] getSessionList: повторная vault-расшифровка манифеста профилей на каждую сессию

**Файл:** `ParanoiaUiClient/src/backend/MainBackend.cpp:2729-2733` (также `:2106`, `:2114`)

В цикле по сессиям `getSessionList()` для каждой вызывает `Utils::profileManifestEntry(profileId)`, а тот каждый раз заново читает и расшифровывает (FFI `vault_decrypt_json` + диск) один и тот же `profiles.json`: N профилей = N расшифровок одного файла за один вызов, кэша в Utils нет — причём манифест содержит base64-аватары ВСЕХ профилей (десятки-сотни КБ на расшифровку). Путь горячий: `getSessionList` дёргается из QML не только на `sessionsChanged`, но и на каждый `onDialogsChanged` — и от Backend, и от Notifications (`MainPage.qml:151,172` — `refreshSessions()`), т.е. на каждый цикл поллинга с изменением непрочитанных, каждое входящее, каждое прочтение; комментарий в `MainPage.qml:96` сам называет его «ТЯЖЁЛОЙ загрузкой (синхронный FFI)». Тот же паттерн в `activeProfileDisplayName`/`activeProfileAvatar` (`:2106`, `:2114`) — ещё по расшифровке на каждое обращение из QML.

```cpp
for (const auto &session : SessionStore::instance()->allSessions()) { ...
    const QJsonObject entry = Utils::profileManifestEntry(session->profileId);
```

**План:** загрузить манифест один раз в начале `getSessionList` (`Utils::loadProfilesManifest`) и выбирать записи из него; для display-name/avatar активного профиля — кэшировать манифест в RAM с инвалидацией по `sessionsChanged`.

---

## 6. [HIGH] ensureGalleryPreview — разошедшаяся копия ensureImagePreview: потерян лимит 30 МБ, любое видео целиком качается в RAM под ffiMutex

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:2667` (контраст — guard в `:1422-1426`)

`ensureGalleryPreview` (экран «Вложения»: зовётся для каждой видимой плитки из `SharedMediaPage.qml:372-377`; видео без постера попадают в mediaItems — `ChatPage.qml:428-433`) повторяет логику `ensureImagePreview` (fetch bytes → makePreview → setBytes → failed-set), но при копировании потерян guard «не тянем видео >30 МБ» (в чатовом пути есть явно, с комментарием). Для видео-плитки без постера `cache_attachment_bytes_keyring` скачает с сервера и расшифрует ВЕСЬ mp4 в `Vec<u8>`/QByteArray (сотни МБ в RAM; Rust-ветка `dialogue.rs:1022-1041` качает все чанки внутри block_on) под общим `ffiMutex` — на всё время закачки встают отправка/приём/история, — только чтобы вырезать кадр-постер. Несколько плиток = серия таких закачек. Плюс сам дубль двух почти идентичных реализаций — источник таких расхождений.

```cpp
// ChatBackend.cpp:2667 — без проверки kind/size
bytes = session->ffi->cache_attachment_bytes_keyring(serverId, peerId, keyringJson, messageId);
// контраст, ChatBackend.cpp:1425: if (videoMessage && msg.value("size").toLongLong() > 30*1024*1024) videoMessage = false;
```

**План:** добавить в ensureGalleryPreview тот же лимит размера для видео (или брать постер только у уже скачанных), и вынести общую часть двух функций в один приватный хелпер (requestKey + колбэк готовности).

---

## 7. [MEDIUM] O(n×m)-мерж в appendMessages: линейный поиск по кэшу на каждое входящее сообщение

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:2726` (также `:2730`, `:2746`, `:2770`, `:2786-2790`)

Для каждого входящего сообщения appendMessages делает до трёх линейных `find_if` по всему кэшу (по id — `:2726`, по seq — `:2730`, по pending-тексту — `:2746`), каждая итерация зовёт `cached.toMap()` + QMap-lookup. При инкрементальном refresh `loadHistory(false)` передаёт полное окно 2000 сообщений в кэш из ~2000 → худший случай ~2000×2000×3 итераций на GUI-потоке на каждый апдейт статусов/превью (поллер 6-10 с). В конце каждого вызова — безусловная сортировка всего кэша с `toMap()` в компараторе (`:2770-2772`) и полная пересборка сета seen (`:2786-2790`).

```cpp
found = std::ranges::find_if(cache, [&id](const QVariant &cached) {
    return cached.toMap().value("id").toString() == id; });   // внутри for по messages
```

**План:** перед циклом построить `QHash<QString,int>` id→индекс и `QHash<quint64,int>` seq→индекс (один проход O(n)), искать за O(1); сортировать только если реально добавились новые элементы, ts вычислять один раз.

---

## 8. [MEDIUM] Полный re-fetch окна истории (2000 сообщений под ffiMutex) ради точечных апдейтов

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:2434` (также `:1214`, `:1321`, `:1474`)

Инкрементальные события дёргают `loadHistory(peer, false)` = `history_keyring` с лимитом 2000 — полный дешифр окна под общим `ffiMutex` — плюс полный мерж и emit: `refreshArrivedStatus` при changed>0 (`:2434`, поллер 6-10 с), готовность каждой пачки превью (`:1474` — а здесь FFI вообще не нужен: меняется только `preview_source`, вычисляемый из RAM-провайдера, `:2842-2846`), успешное сохранение вложения (`:1214`, `:1321`). Пока ffiMutex занят дешифром 2000 сообщений, отправка/приём/превью стоят в очереди. GUI напрямую не блокируется (всё на QThreadPool) — это лишняя работа + contention на ffiMutex.

**План:** для превью — обновлять `preview_source` прямо в кэше по messageId и эмитить модель без FFI-раунда; для arrived-статусов — точечный FFI (изменённые seq/статусы) либо ограниченное окно (последние N=50-100), а не всё окно.

---

## 9. [MEDIUM] Двойной emit messagesReceived на каждый refresh истории — QML прогоняет composeMessages дважды

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:2550` (также `:2580` + `:2599`)

appendMessages в конце сам эмитит `messagesReceived(peer, cache)` (`:2791`). Но в loadHistory путь clearCache=false сразу после appendMessages эмитит его повторно (`:2549-2551`), причём guard peer != m_activePeer уже отработал ранним return (`:2541`) — второй emit срабатывает всегда. В пути clearCache=true первый emit из appendMessages (`:2580`) уходит с полусобранным кэшем (реакции ещё не восстановлены `:2582-2595`, outbox не возвращён `:2598`), затем финальный на `:2599`. QML-хендлер `onMessagesReceived` (`ChatPage.qml:1589`) на каждый emit прогоняет composeMessages по всей ленте — вся работа дублируется на каждый апдейт активного чата.

**План:** дать appendMessages параметр emitSignal=true и передавать false из loadHistory (обоих путей), оставив один финальный emit.

---

## 10. [MEDIUM] cacheVideoForPlayback гоняет весь mp4 через RAM вместо потоковой материализации в файл

**Файл:** `ParanoiaUiClient/src/backend/ChatBackend.cpp:1649` (`:1655-1658`)

Для проигрывания видео код берёт `cache_attachment_bytes_keyring` (весь расшифрованный mp4 одним буфером: Rust собирает `Vec<u8>` — `dialogue.rs:963-1062`, в ветке enc-кэша дополнительно весь sealed-файл через `fs::read`; обёртка копирует ещё раз в QByteArray) и вручную пишет в `paranoia_play/<id>.mp4`. Пик RAM ≥ 2× размера видео — на мобильных риск OOM/вытеснения. Смягчение: ранний выход по уже materialized-файлу (`:1624`) — полный проход случается один раз на видео; выполняется на QThreadPool, GUI не фризит.

⚠️ **Нюанс фикса** (нашёл верификатор): прямая замена на `save_attachment_keyring` НЕ эквивалентна — `write_attachment_to_path` (`dialogue.rs:1577`) не смотрит в локальный enc-кэш и у получателя пойдёт заново качать все чанки с сервера (ломает оффлайн-повтор, лишний трафик). Корректный фикс — новая FFI-ручка «расшифровать enc-кэш потоково в путь» (или доучить `write_attachment_to_path` ветке enc_path), с фолбэком на скачивание.

**План:** потоковая материализация расшифрованного вложения сразу в целевой файл (новая/доученная FFI-ручка), без полного буфера в RAM; `cache_attachment_bytes_keyring` оставить для мелких превью.

---

## 11. [LOW] Idle-цикл ActiveChatNotifier: вечные пробуждения потока каждые 2 секунды без цели

**Файл:** `ParanoiaUiClient/src/backend/ActiveChatNotifier.cpp:68-70`

Когда цель пуста (вышли из чата, приложение в фоне — updateNotifier зовёт `configure({}…)`), workerLoop не паркуется, а крутит `msleep(2000)+continue` до конца жизни процесса. Поток намеренно не останавливают (stop()+wait() на GUI морозил бы UI до 25 с — осознанно), но вместо парковки получились перманентные пробуждения CPU каждые 2 с — и после логаута, и в свёрнутом приложении, вразрез с курсом на энергосбережение. Смягчения: до первого открытия чата поток не запущен; работа на пробуждение мизерная (лок+копия строк); на Android фоновый процесс часто заморожен системой.

**План:** парковать воркер на QWaitCondition/QSemaphore при пустой конфигурации и будить из configure()/stop() — убирает пробуждения, не возвращая блокирующий stop() на GUI.

---

## 12. [MEDIUM] Скрамбл-биндинг «дешифровки» пересчитывается во ВСЕХ делегатах ленты каждые 45 мс

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:3689` (таймер `:1372-1376`, decryptStr `:1382-1395`)

Text-оверлей «дешифровки» есть в каждом делегате ленты, и его биндинг `text: root.decryptStr(model.text || "", _rv, root._scrambleTick)` зависит от `_scrambleTick` у ВСЕХ инстанцированных делегатов — гейт `visible: !isMe && _animating && showMessageText` (`:3680`) не останавливает переоценку биндинга у невидимых. Пока идёт reveal любого входящего (~1.65 с), таймер тикает каждые 45 мс → ~15-30 делегатов (с учётом cacheBuffer) прогоняют посимвольный JS-цикл с конкатенацией по ПОЛНОМУ model.text (без учёта _clampText); у неанимируемых _rv=1.0 и результат выбрасывается. Для «простыней» — сотни тысяч посимвольных операций в секунду на GUI-потоке ровно во время анимации, где и так борются за плавность.

**План:** гейтить сам биндинг: `text: _animating ? root.decryptStr(model.text || "", _rv, root._scrambleTick) : ""` — зависимость от _scrambleTick зарегистрируется только у единственного анимируемого делегата.

---

## 13. [LOW] MessageText: двойной прогон _measurePlain/_measureCodePlain при создании каждого делегата

**Файл:** `ParanoiaUiClient/ui/Components/MessageText.qml:34` (также `:35`, `:362`, `:371`)

При инстанцировании каждого текстового сообщения `_measureCodePlain()` вычисляется дважды (`_hasCode` `:34` и `measureCode.text` `:371`), `_measurePlain()` — дважды для коротких сообщений (`_longestPlainLine` `:35` и `measureText.text` `:362`). Смягчение (верификатор): самая дорогая часть — `_segments(raw)` с regex-разбором — уже закэширована в `_segs` (`:52`); сами measure-функции — дешёвые filter/map/join по готовым сегментам, поэтому low.

**План:** закэшировать в readonly-свойствах (`_plainMeasured`, `_codePlain`) и ссылаться из всех четырёх мест — по одному вычислению на смену raw.

---

## 14. [LOW] Полный ремаршалинг списка диалогов на каждый dialogsChanged ради имени/аватара одного пира

**Файл:** `ParanoiaUiClient/ui/Pages/ChatPage.qml:23` (`:36`; `MainBackend.cpp:1208-1234`)

`_refreshPeerInfo` по каждому `onDialogsChanged` (эмитится из ~29 мест, в т.ч. `NotificationCoordinator.cpp:471` на каждый поллинг с новыми входящими в ЛЮБОМ диалоге) вызывает `Backend.getDialogs()`: C++ без кэша пересобирает весь QVariantList с конкатенацией base64-аватара на каждый диалог — чтобы прочитать displayName/avatar единственного peer. Вдобавок через `activeProfileDisplayName`/`activeProfileAvatar` дважды синхронно читает и парсит profilesManifest с диска (см. п. 5). Смягчение: getDialogs чисто in-memory, аватары 64×64 (~2-6 КБ), цена события — миллисекунды.

**План:** точечный Q_INVOKABLE `Backend.dialogInfo(peer)` (один QVariantMap) либо сигнал с изменившимся peer + ранний выход в QML.

---

## 15. [MEDIUM] Новый tokio Runtime и новый reqwest-клиент на каждый фоновый опрос сервиса (батарея!)

**Файл:** `ParanoiaLibrary/src/ffi.rs:3483` (`:3490-3491`; также холодные `:295`, `:337`, `:396`, `:2538`)

`paranoia_service_notify_multi_wait` — горячий путь Android-фон-сервиса (`ParanoiaForegroundService.java:891,1002`, long-poll цепочка каждые ~15-30 с под wakelock; в battery-режиме 210-390 с). При каждом вызове создаётся новый МНОГОпоточный `Runtime::new()` (пул воркеров по числу ядер + blocking-пул, затем всё уничтожается) и новый `Transport::new` → свежий `reqwest::Client` (`transport.rs:166-183`): пул соединений и TLS-сессии не переживают вызов — каждый опрос платит полный TCP+TLS handshake. Для проекта, где батарея фон-сервиса — приоритет (ради этого делали multi-notify), это постоянный перерасход CPU/сети. Прецедент правильного паттерна в кодовой базе уже есть: `VOIP_RUNTIME: OnceLock` (`voip_ffi.rs:86`).

```rust
let rt = match Runtime::new() { … };                    // ffi.rs:3483
let transport = crate::transport::Transport::new(&server, reserves.iter(), cover);  // :3491 → новый reqwest::Client
```

**План:** процессный `OnceLock<Runtime>` (достаточно `Builder::new_current_thread().enable_all()`) + кэш Transport по ключу (server_url, reserve_urls); тем же кэшем закрыть `paranoia_service_call_poll` в voip_ffi.rs. Долгоживущий reqwest-клиент сохранит соединение между опросами.

---

## 16. [MEDIUM] race_shutdown будит рантайм каждые 100 мс на всём протяжении long-poll (батарея!)

**Файл:** `ParanoiaLibrary/src/ffi.rs:59-69` (обёрнуты: `:1533`, `:1656`, `:3499`, `voip_ffi.rs:511`)

Отмена long-poll'ов реализована поллингом атомарного флага: ветка `tokio::select!` крутит `loop { if SHUTTING_DOWN … ; sleep(100ms) }` параллельно каждому in-flight long-poll — 150-300 лишних таймер-пробуждений рантайма на каждый 15-30-секундный опрос. В фоновом процессе `:notifications` на Android флаг вообще никогда не взводится (`paranoia_begin_shutdown` зовёт только UI-процесс на aboutToQuit, `main.cpp:241`) — постоянные 10 Гц-пробуждения в батарейно-критичном фоне вхолостую.

**План:** событийная отмена: `static NOTIFY: tokio::sync::Notify`; `paranoia_begin_shutdown` после `store(true)` зовёт `notify_waiters()`; в race_shutdown — `select! { r = fut => …, _ = NOTIFY.notified() => None }` с быстрой проверкой флага на входе. Ноль пробуждений до реального shutdown.

---

## 17. [LOW] Двойная (де)сериализация keyring'а в каждом цикле multi-notify UI-процесса

**Файл:** `ParanoiaLibrary/src/ffi.rs:1644-1648`

`paranoia_notify_unread_multi_keyring` (опрос NotificationCoordinator по таймеру 60с-5мин) парсит items_json в `serde_json::Value`, затем для каждого диалога сериализует поле keyring обратно в строку (`k.to_string()`) и тут же повторно парсит в `dialogue_config_from_keyring_str` — round-trip Value→String→Value на каждый диалог в каждом опросе, причём из результата используется только `cfg.key`. Смягчение: выполняется на воркере, микросекунды на фоне HTTP-запроса рядом — косметика.

**План:** типизированный парс одним заходом: `#[derive(Deserialize)] struct MultiItem { peer: String, keyring: Vec<FfiKeyringEntry> }` + `from_str::<Vec<MultiItem>>`, без промежуточной строки.

---

## 18. [MEDIUM] receive(): 3-4 отдельных SQLite-коммита с fsync на каждый входящий пакет — транзакций в store.rs нет вообще

**Файл:** `ParanoiaLibrary/src/dialogue.rs:592` (также `:533`, `:578`; `store.rs:288-318`, `:450-477`)

В цикле обработки pull-батча на КАЖДЫЙ пакет: `save_message` (два execute: INSERT messages + INSERT seq_map) и следом `set_last_pulled_seq` (UPSERT). В store.rs нет ни одного BEGIN/transaction (grep — ноль), PRAGMA synchronous не понижен (дефолт FULL) — каждый execute() это отдельный автокоммит с fsync WAL. Первичная синхронизация диалога из N сообщений = ~4N fsync-транзакций; на Android-флеше (fsync единицы-десятки мс) — секунды на сотни сообщений, и всё под ffiMutex (тянет известные GUI-фризы). Тот же паттерн в `delete_messages_by_seqs` — по 2 автокоммита на seq в tombstone-sweep и удалении темы. Смягчение: в steady-state поллинге без новых сообщений цикл не пишет.

**План:** обрабатывать pull-батч в одной транзакции (unchecked_transaction/savepoint, батчевый «сохранить сообщения + курсор»), писать last_pulled_seq раз на батч — повторный pull идемпотентен (`process_incoming` проверяет get_message_by_seq, `:1821`); delete_messages_by_seqs — транзакция или `DELETE … IN (…)`.

---

## 19. [MEDIUM] Безусловный полный receive() перед каждой файловой отправкой — 15 фото мозаики = 15 полных синков

**Файл:** `ParanoiaLibrary/src/dialogue.rs:1303`

`send_path_chunked` начинает с безусловного `self.receive()`: пагинация /map по всей карте seq (RTT на страницу), forward-pull, полный SELECT всех server_seq + tombstone-sweep. Клиент шлёт фото мозаики последовательно в цикле (`ChatBackend.cpp:1074-1120`, всё под ffiMutex) — каждое фото платит полный цикл синхронизации, хотя предыдущий закончился секунду назад; комментарий в ChatBackend сам признаёт «основное время уходит на pull-before-push внутри движка» и маскирует задержку фиктивным 0% прогресса. Соседние `send()` (`:1101`) и `send_chunked()` (`:1200`) используют дешёвый guard «notify_count()>0 → receive()» — path-вариант единственный без него. ⚠️ Нюанс: у send_path_chunked нет ретрая на duplicate_seq/invalid_seq (в отличие от send, `:1141-1151`) — сейчас безусловный receive несёт корректностную роль; фикс должен добавить ретрай.

**План:** notify-guard + ретрай на duplicate_seq/invalid_seq (по образцу send()); либо один receive() на группу — прокинуть флаг «уже синхронизированы» из цикла мозаики.

---

## 20. [MEDIUM] Android: пустой таймер-цикл каждые 2-15 с в фоне вопреки режимам энергосбережения

**Файл:** `ParanoiaUiClient/src/backend/NotificationCoordinator.cpp:209-210` (`schedulePoll` `:540-548`, off-ветка `:521-522`)

В фоне на Android `onPollTimer` не опрашивает сеть (это делает сервис `:notifications`) — только перевзводит `m_pollTimer` на randomNotifyDelayMs() = 2-15 с: экономная ветка 210-390 с обёрнута в `#if !defined(Q_OS_ANDROID)`. UI-процесс в фоне вечно просыпается каждые 2-15 с и на каждом тике делает rebuildBackgroundPollSnapshot + JNI start/stop сервиса с синхронным prefs.commit — в том числе в режимах battery_saving и **off** (в off каждый тик: stop() + commit + stopService-IPC). Прямо противоречит цели режимов энергосбережения. Таймер в фоне не нужен: реарм при возврате в Active делает onApplicationStateChanged → schedulePoll(0) (`:249`), плюс onNetworkChanged и pollModeChanged. Смягчение: без FGS ОС довольно быстро замораживает процесс (cached-freeze).

**План:** на Android при уходе в фон останавливать m_pollTimer совсем; в onPollTimer для Android-фона не перевзводить.

---

## 21. [MEDIUM] schedulePoll на каждом тике: JNI-старт сервиса с sync commit на GUI и двойная сериализация снапшота

**Файл:** `ParanoiaUiClient/src/backend/NotificationCoordinator.cpp:499-524` (Java `ParanoiaForegroundService.java:364-380`)

`schedulePoll` (GUI-поток, конец каждого цикла опроса, 2-15 с бессрочно) всякий раз делает «переходную» работу, нужную только при изменении состояния: (1) `rebuildBackgroundPollSnapshot` — обход всех сессий×диалогов с JSON-сериализацией keyring каждого (`Dialog::keyringJson` строит QJsonDocument без кэша), хотя buildPollTargets в том же тике уже сериализовал те же keyring'и; (2) на Android — JNI `start()`: ensureChannels + `prefs.edit().commit()` (синхронная запись XML на GUI-потоке) + startForegroundService Binder-IPC — без idempotence-guard'а. Периодическая дисковая запись + IPC + двойная сериализация с GUI каждые 2-15 с при неизменном состоянии.

**План:** rebuildBackgroundPollSnapshot — по событиям изменения (dialogsChanged/sessionsChanged/pollModeChanged); в schedulePoll помнить последнее запрошенное состояние сервиса и звать start/stop только при смене; в Java `commit()` → `apply()`.

---

## 22. [MEDIUM] iOS: кратный полный multi-notify-опрос за одно BGTask-пробуждение

**Файл:** `ParanoiaUiClient/src/backend/NotificationCoordinator.cpp:57-67` (`:212`, `:220`; `PlatformNotifications_ios.mm:164-175`)

Колбэк фонового пробуждения делает сразу два действия: запускает runBackgroundPollFromService на воркере (полный multi-notify по снапшоту + 30-секундный call-poll + showMessageCount) И постит onNetworkChanged → schedulePoll(0) → на iOS таймер в фоне запускает pollBackgroundNotifications() — ВТОРОЙ полный опрос тех же сессий с повторным showMessageCount; затем applyNotifyCounts перевзводит таймер на 2-15 с — за 30-секундное окно BGTask ещё 1-3 круга. Guard m_notifyPollInFlight от параллельного runBackgroundPollFromService не защищает. Попутно дубль сабмита BGTask-request (`:536` поверх `ios.mm:164`). Итог: 2-4 полных сетевых круга по всем сессиям за пробуждение в самом дорогом (фоновом) режиме; BGTask система даёт редко — потому medium.

**План:** в колбэке пробуждения не звать onNetworkChanged целиком (сбросить retry-счётчик и эмитнуть networkRestored без schedulePoll), либо на iOS в фоне гасить m_pollTimer — единственным опросом остаётся runBackgroundPollFromService.

---

## 23. [MEDIUM] Прогресс загрузки обновления: queued-событие в GUI на каждый сетевой чанк

**Файл:** `ParanoiaUiClient/src/backend/VersionInfoBackend.cpp:411-427` (Rust `ffi.rs:418-427`)

Rust-сторона `paranoia_http_download` зовёт progress-колбэк на каждый chunk reqwest (~8-64 КБ); колбэк на каждый вызов постит `QMetaObject::invokeMethod(Queued)` в GUI, где строится `tr("Скачивание… %1%")` и эмитится downloadChanged → переоценка QML-биндингов. Для APK/DEB 60-100 МБ — тысячи-десятки тысяч событий в очереди GUI при ~100 видимых состояниях; комментарий в коде сам это фиксирует. Путь редкий (ручная загрузка обновления) — medium.

**План:** троттлить до постинга — слать только при смене целого процента (atomic с последним отправленным) или ≤10 раз/с; либо колбэк пишет atomic-поля, GUI читает их QTimer'ом 100-200 мс на время загрузки.

---

## 24. [MEDIUM] misspelledRanges(): полный рескан всего текста с Hunspell-проверкой каждого слова на каждый ввод символа

**Файл:** `ParanoiaUiClient/src/spell/SpellHighlighter.cpp:148-170` (`ChatPage.qml:4685-4688`, `:4728`)

ChatPage вызывает `misspelledRanges()` из onPaint Canvas-оверлея, а requestPaint дёргается в onTextChanged — на каждый символ. Метод каждый раз делает `doc->toPlainText()` (полная копия), прогоняет regex по всему документу и для каждого слова зовёт до 4 `Hunspell_spell` (две формы × два словаря). Параллельно на тот же keystroke Qt уже выполнил `highlightBlock()` с идентичным сканом изменённого блока — но его setFormat-результаты QQuickTextEdit не рендерит и они выбрасываются (в коде это прямо откомментировано). O(весь текст) двойной работы на каждый символ в самом горячем UI-пути; desktop-only (на мобильных enabled=false), черновики обычно короткие — потому medium.

**План:** кэшировать диапазоны по блокам прямо в highlightBlock (он инкрементален) и отдавать misspelledRanges() из кэша; requestPaint задебаунсить 150-200 мс (по образцу draftSaveTimer).

---

## 25. [MEDIUM] API манифеста профилей провоцирует N+1: каждый вызов — полный vault-декрипт файла

**Файл:** `ParanoiaUiClient/src/utils/Utils.cpp:174` (`:154`; вызовы `MainBackend.cpp:806-807`, `:883-884`, `:2106`, `:2114`, `:2141-2180`)

`profileManifestEntry`/`updateProfileManifestEntry`/`upsertProfileManifest` на каждый вызов заново декриптуют profiles.json через FFI (мутирующие — ещё и шифруют весь файл обратно); кэша и read-modify-write API нет, поэтому вызывающие дублируют декрипты: loadProfilesManifest + сразу upsert (второй декрипт внутри), два profileManifestEntry подряд (localName, потом avatar), changeProfileServer — до 5 декриптов + 2 энкриптов на операцию. Горячая часть: activeProfileDisplayName/Avatar дёргаются из `_refreshPeerInfo` на каждый dialogsChanged открытого чата — два vault-декрипта на GUI под FFI-мьютексом. Родственно п. 5 (getSessionList).

**План:** API, принимающий уже загруженный манифест (`upsertProfileManifest(manifest, …)` / `entryFrom(manifest, id)`), либо короткоживущий RAM-кэш с инвалидацией при записи — одна операция = один декрипт.

---

## 26. [LOW] Каждый вызов геттеров Paths и isVaultProtected повторяет QStandardPaths-лукап и mkpath-сисколлы

**Файл:** `ParanoiaUiClient/src/utils/Paths.cpp:6-13` (`:28-38`)

`appDataRoot()` на каждый вызов делает QStandardPaths::writableLocation + mkpath существующего каталога; `isVaultProtected()` зовёт 6 геттеров → 6× appDataRoot + mkpath("profiles") на одну проверку — а она стоит в начале КАЖДОГО `Utils::readAll/writeFile`, включая каждый saveDialogs. ~10-16 лишних сисколлов на вызов — микроскопично на фоне vault-шифрования рядом, но пути статичны на всю жизнь процесса.

**План:** function-local static кэш путей; isVaultProtected сравнивает с заранее подготовленным набором без лукапов/mkpath.

---

## 27. [MEDIUM] Аллокация 3.1 МБ и лишняя полная копия NAL на каждый входящий видеокадр

**Файл:** `ParanoiaUiClient/src/voip/CallEngine.cpp:906-907` (`:893-896`)

В горячем пути входящего видео на каждый декодированный кадр создаётся новый QByteArray на kMaxFrameBytes = 1920×1080×3/2 ≈ 3.1 МБ (при 30 fps — ~93 МБ/с alloc/free-чурна; такие аллокации идут через mmap с page-fault'ами), хотя фактический размер кадра известен декодеру. Плюс перед decode() каждый собранный NAL целиком копируется в новый буфер annexb ради приклейки 4-байтового start-кода. Всё — в GUI-потоке (см. 01 п. 23). Нюанс фикса: frame_bytes уходит в sink через std::move — переиспользуемый буфер потребует возврата буферов; annexb-копия устранима точно.

**План:** start-код класть в reassembly_.nal сразу при FRAME_START (append 00 00 00 01 перед первым фрагментом); буфер кадра — переиспользовать/пул с ресайзом по фактическим dims.

---

## 28. [MEDIUM] Лишняя packed-прослойка и покадровая аллокация 1.3 МБ в исходящем видеотракте

**Файл:** `ParanoiaUiClient/src/voip/VideoCapture.cpp:467-499` (`H264Codec.cpp:228-230`)

На каждый кадр камеры: новый QByteArray packed ~1.35 МБ с построчными memcpy из avfilter-выхода → копия в preview-QVideoFrame → третья копия в AVFrame энкодера (av_image_copy_plane). Уточнение верификатора: полностью лишняя именно packed-прослойка (копия + аллокация на кадр) — если `H264Encoder::encode` примет `data[3]/linesize[3]` напрямую из filter_->out, она исчезает; копии в QVideoFrame и AVFrame неустранимы (владеют своими буферами), меняется лишь источник.

**План:** перегрузка encode(data[3], linesize[3]) + preview из out->data; packed-буфер убрать (или как минимум сделать member).

---

## 29. [LOW] Фоновая msleep(400)-петля CallSignalingClient при выключенном опросе офферов

**Файл:** `ParanoiaUiClient/src/voip/CallSignalingClient.cpp:175-182`

Когда опрос офферов выключен (приложение в фоне без звонка — большая часть жизни мобильного клиента при залогиненном профиле), workerLoop крутит «msleep(400) + continue»: поток просыпается 2.5 раза/с впустую. Смягчение: за пробуждение — только atomic load; на Android 12+ cached-freezer вскоре замораживает UI-процесс. Родственно 02 п. 11 (idle-петля ActiveChatNotifier).

**План:** QWaitCondition/семафор, который будят setOfferPollingEnabled(true) и stop(); либо выход из workerLoop и повторный invokeMethod при включении.

---

## 30. [MEDIUM] Список диалогов: полный ресет JS-модели на каждый тик уведомлений и каждый символ поиска

**Файл:** `ParanoiaUiClient/ui/Pages/MainPage.qml:693` (обработчики `:151-153`, `:159`, `:172`; поиск `:649`)

Модель ListView — результат `filteredDialogs()` от plain JS-массива allDialogs. Любое присваивание allDialogs (ЧЕТЫРЕ обработчика: Backend.onDialogsChanged, onDialogDeleted, Chat.onDialogsChanged, Notifications.onDialogsChanged) или dialogQuery (каждый символ поиска) отдаёт ListView новый массив → полный сброс модели и пересоздание делегатов (аватары-Image с data:-URL, бейджи, MouseArea). dialogsChanged от NotificationCoordinator приходит на каждый цикл поллинга с изменением непрочитанных — точечное изменение счётчика одного диалога пересоздаёт весь видимый список. `getDialogs()` каждый раз заново конкатенирует `data:image/png;base64,`+avatar для всех диалогов. При удалении диалога модель перечитывается дважды (removeDialog → dialogsChanged + deleteDialogLocal → dialogDeleted). Смягчение: делегаты создаются только видимые (+cacheBuffer), getDialogs — in-memory.

**План:** перевести на ListModel/QAbstractListModel с точечными обновлениями (setProperty по индексу, move при перестановке); фильтр — DelegateModel/QSortFilterProxyModel поверх той же модели; минимум — объединить четыре обработчика и не заменять массив при неизменном содержимом.

---

## 31. [MEDIUM] Экспорт: полный ресет списка на каждый dialogsChanged со сбросом ручного выбора пользователя

**Файл:** `ParanoiaUiClient/ui/Pages/ExportImportPage.qml:61-63` (`refreshExportDialogs` `:18-27`)

Connections onDialogsChanged без guard'а вызывает refreshExportDialogs(): полная пересборка модели списка + перезапись selectedExportPeers с true для ВСЕХ диалогов с keyring. Сигнал частый (NotificationCoordinator эмитит на каждое изменение pending-счётчиков поллинга) — любое входящее сообщение, пока пользователь на вкладке «Экспорт», молча возвращает его снятые галочки к «все выбраны». Для страницы экспорта КЛЮЧЕЙ это не только перф-шум, но и риск экспортировать больше, чем пользователь хотел. Перф-цена мала (in-memory, ~4 делегата) — medium из-за смыслового эффекта.

**План:** обновлять модель только при реальном изменении состава; selectedExportPeers сливать с текущим выбором (новым — true, существующим — сохранять выбор).

---

## 32. [LOW] Полный сетевой re-fetch корпоративного ростера ради одного локально известного флага

**Файл:** `ParanoiaUiClient/ui/Pages/AddDialogPage.qml:43-47`

onCorporateDialogueAdded при успехе заново вызывает `Backend.fetchCorporateRoster()` — HTTP-запрос к ноде + расшифровка блоба + повторное применение имён + полный ресет rosterModel — чтобы пометить «Добавлен» одну запись, чей partnerServerId уже пришёл в сигнале, а флаг added вычисляется локально. Вдобавок авто-добавление аккаунта компании при первом фетче эмитит тот же сигнал → двойной полный фетч при первом открытии страницы. HTTP на воркере (GUI не фризится), путь редкий — low.

**План:** точечный патч модели (найти запись по username, added=true); сетевой re-fetch — только на кнопке «Обновить».

---

## 33. [MEDIUM] Новый многопоточный tokio Runtime + новый reqwest::Client на каждый corp/admin-вызов

**Файл:** `ParanoiaLibrary/src/corp_api.rs:326` (также `:79`, `:102`; `admin_api.rs:71`, `:144`, `:231`)

Каждый вызов corp_fetch_roster/corp_fetch_dialogue/corp_push*/corp_delete* и всех admin-операций делает `Runtime::new()` (полный multi-thread: спавн N воркеров + blocking pool, синхронный join при drop) и строит новый reqwest::Client/Transport — свежий TCP+TLS хендшейк без переиспользования соединений (заметно при последовательных fetch_dialogue). Проект сам признал это антипаттерном и починил в voip: `VOIP_RUNTIME: OnceLock` (`voip_ffi.rs:79-87`, комментарий прямо про «расточительно на мобильных»). Родственно п. 15 (тот же антипаттерн в service-notify FFI). Путь не горячий (корп-логин, добавление диалога) и на воркер-потоке — medium.

**План:** общий ленивый runtime по образцу VOIP_RUNTIME (или `new_current_thread` — для одиночных блокирующих запросов хватает) + переиспользуемый reqwest::Client в static; единый фикс с п. 15.

---

## 34. [HIGH] service_call_poll: новый многопоточный Runtime + новый reqwest-клиент на каждый 12-секундный опрос (батарея!)

**Файл:** `ParanoiaLibrary/src/voip_ffi.rs:634` (`:641-642`; Java `ParanoiaForegroundService.java:1036-1051`, `:706-733`)

`paranoia_service_call_poll` на КАЖДЫЙ вызов создаёт `Runtime::new()` (многопоточный пул + blocking-пул; Drop синхронно join'ит все потоки), новый FoodDeliveryClientCover и `Transport::new` → свежий reqwest::Client. Android-сервис зовёт его back-to-back цепочкой с long-poll 12 с («НЕПРЕРЫВНОЕ покрытие») — **~7200 созданий рантайма и полных TCP+TLS handshake'ов в сутки на профиль** в штатном фоновом режиме. Третий экземпляр антипаттерна (п. 15 — service-notify, п. 33 — corp/admin); правильный прецедент — в этом же файле (`VOIP_RUNTIME: OnceLock`, `voip_ffi.rs:86`).

**План:** тот же общий фикс, что п. 15/33: процессный OnceLock<Runtime> (current_thread) + кэш Transport по (server_url, reserve_urls) — TLS-сессия переживает опросы.

---

## 35. [MEDIUM] TURN-путь: двойной parse и три копии payload'а на каждый входящий пакет, OsRng-syscall на каждый исходящий

**Файл:** `ParanoiaLibrary/src/voip/turn.rs:274` (`:489`, `:495`, `:504`; `transport.rs:585-586`, `:668`, `:775`)

На relay-пути (штатный режим cross-network звонков) каждый входящий media-пакет: `turn::parse` копирует значение КАЖДОГО атрибута в Vec (включая весь DATA ≤1200Б), затем `parse_data_indication` парсит буфер ВТОРОЙ раз целиком (результат первого parse выбрасывается) и клонирует DATA ещё раз — двойной parse + три копии до AEAD-расшифровки, при 50 pps voice и сотнях pps video. На отправке: payload копируется в атрибут и ещё раз в итоговый буфер, а transaction_id генерируется через OsRng (getrandom-syscall) на каждый датаграмм, хотя tid у Indication никем не проверяется.

**План:** заимствующий parse_data_indication (offset DATA → срез без промежуточного Message); build_send_indication — писать сразу в итоговый буфер; tid для Send Indication — из счётчика/thread-local PRNG.

---

## 36. [LOW] pack(): лишняя аллокация и копирование шифртекста на каждый исходящий пакет

**Файл:** `ParanoiaLibrary/src/voip/packet.rs:115-120`

На каждый исходящий voice-фрейм/video-фрагмент aead_encrypt возвращает отдельный Vec, после чего pack аллоцирует второй и копирует header+шифртекст; вдобавок aead_encrypt пересоздаёт ChaCha20Poly1305::new на пакет. Реальная, но микроскопическая неоптимальность (memcpy ≤1 КБ в фоновом tokio-таске).

**План:** encrypt_in_place (aead::Buffer для Vec) с AAD-срезом заголовка в один буфер; cipher создать один раз на сессию; в перспективе — переиспользуемый scratch-буфер в run_session.

---

## 37. [MEDIUM] EasyCli: busy-опрос по сети при неудержанном /notify — watch, TUI и пейсинг пулера

**Файл:** `ParanoiaEasyCli/src/main.rs:556-569` (также `tui.rs:263-281`, `mcp_server.rs:838`)

`notify_count_wait` — best-effort: на сервере, не удерживающем /notify (старый сервер, ошибка за CDN — сценарии, прямо названные в комментариях), он возвращается мгновенно. Тогда: `cmd_watch` спит только при long_poll_ms==0 → непрерывный notify+receive без единой паузы (десятки запросов/с); live-таск TUI — то же самое (sleep(2s) только в ветке Err, при успешном пустом receive паузы нет); пейсинг channel_push_loop 300 мс не отличает удержанный long-poll от мгновенного возврата (~3 запроса/с). В `tool_wait` эта же проблема уже решена guard'ом «poll_start.elapsed() < 2s → пауза» — в остальные места guard не перенесён. Не находка против long-poll-дизайна — защита деградационного пути.

**План:** перенести guard из tool_wait во все три места: итерация короче ~2 с и без новых сообщений → sleep interval.

---

## 38. [MEDIUM] Argon2-инициализация vault на каждую команду CLI, включая не использующие vault

**Файл:** `ParanoiaEasyCli/src/main.rs:1819-1821`

main() для всех команд (кроме tui и mcp install) безусловно зовёт init_vault_for_cli() → Argon2id m=64 МиБ, t=3 — сотни мс KDF и 64 МиБ аллокации на каждый запуск процесса. Vault (db_key) нужен только командам, открывающим paranoia.db через ParanoiaClient; server-id, profile-name, dialogue init/set-key, device-key show, export, import работают с plaintext-стором и key_from_pin — платят полный Argon2 впустую. В сценариях автоматизации (процесс на команду) ощутимо.

**План:** ленивый init — перенести init_vault_for_cli() внутрь build_client() (и других мест, реально открывающих paranoia.db).

---

## 39. [LOW] Стор диалогов перечитывается и репарсится с диска 2-3 раза на каждую операцию

**Файл:** `ParanoiaEasyCli/src/main.rs:310` (`:260-261`; `:636`, `:663`, `:723`)

build_client → load_profile_signing_key читает и парсит весь ~/.paranoia_dialogues.json; сразу следом build_dialogue делает это второй раз; cmd_call_offer/hangup — третий. Каждый вызов MCP-тулзы = два полных чтения. Файл маленький (КБ), цена — миллисекунды; кэшировать между операциями нельзя (стор меняют другие процессы).

**План:** загружать стор один раз на операцию и передавать &DialogueKeyStore в build_client/build_dialogue/dialog_master_key.

---

## 40. [LOW] durable-лог растёт без ротации, а history парсит весь файл ради последних 50 записей

**Файл:** `ParanoiaEasyCli/src/mcp_server.rs:138-158` (`:75-93`)

messages.jsonl только дописывается и никогда не обрезается; read() читает файл целиком, JSON-парсит каждую строку и отбрасывает всё кроме последних limit (split_off); load_seen держит ВСЕ id в памяти бессрочно. Боевой файл уже 3 МБ и растёт; чтение — блокирующее на единственном потоке (см. 01 п. 31). Ощутимо станет через месяцы.

**План:** ротация при старте (последние N строк) + чтение хвоста файла (seek с конца); seen — только по хвосту.
