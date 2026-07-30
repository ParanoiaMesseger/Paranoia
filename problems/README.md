# План доработки: результаты ревью проекта

Ревью кодовой базы на предмет трёх классов проблем:

- **freeze** — возможные фризы / блокировки (GUI-поток, tokio-воркеры);
- **redundant** — лишние операции (двойная работа, копирования, O(n) там, где можно O(1));
- **artifact** — избыточные конструкции, следы поиска решения (мёртвый код, дубли, отладочные остатки).

Каждая находка проверена по коду: цитата-доказательство сверена с фактическим содержимым файла на момент ревью.

## Файлы плана

| Файл | Класс | Находок |
|---|---|---|
| [01-freezes.md](01-freezes.md) | Фризы и блокировки | 32 |
| [02-redundant.md](02-redundant.md) | Лишние операции | 40 |
| [03-artifacts.md](03-artifacts.md) | Артефакты и мёртвый код | 77 |
| [**PLAN.md**](PLAN.md) | **Сквозной план исправлений** (последовательность, группировка в keystone-фиксы, развилки-решения) | — |

## Сводка по серьёзности

| Серьёзность | Находки |
|---|---|
| **high** | `reg.rs:71` — регистрация пишет конфиг мимо `PARANOIA_CONFIG` (потеря пользователей после рестарта); `notify.rs:237` — блокирующие RocksDB-сканы в самом горячем async-роуте; `MainBackend.cpp:2903` — publishServiceSnapshot: ffiMutex + SQLCipher-чтения в цикле на GUI-потоке при каждом pull; `ChatBackend.cpp:2784` — синхронный saveDialogs на GUI при каждом батче сообщений; `ChatBackend.cpp:2543` — parseMessages полной истории на GUI; `ChatBackend.cpp:2667` — галерея качает любое видео целиком в RAM под ffiMutex (потерян guard 30 МБ); `SpellHighlighter.cpp:178` — Hunspell-словари ~4 МБ синхронно на GUI при каждом открытии чата; `CallEngine.cpp:899` — декод входящего H.264 на GUI (до 30 fps); `VideoCapture.cpp:247` — avfilter+энкод исходящего видео на GUI; `voip_ffi.rs:1345` — block_on(send) в bounded-канал на GUI (удалённо-триггерируемый фриз флудом UDP); `voip_ffi.rs:634` — Runtime+TLS-handshake каждые 12 с в фон-сервисе (батарея); ⭐ `ChatBackend.cpp:930` — КОРНЕВАЯ: конвой всех операций на ffiMutex при ложной предпосылке «handle !Send» (хэндл Send+Sync, мессенджер мёртв на время аплоадов) |
| **medium** | Сервер: `server_config.rs:72` — синхронный `fs::write` под глобальным RwLock конфига; `blob.rs:159` — блокирующий I/O чанков в async; `schema_cover.rs:167` — двойная (де)сериализация в `/pull`; `voip_stun.rs:537` — O(n)-скан аллокаций на каждый media-пакет. Клиент: `ParaInput.qml:32` — двойная синхронизация полей ввода; handwriting-раскладки — мёртвый груз в qrc; `MainBackend.cpp:1664` — маскировка под ffiMutex на GUI; `:2023` — синхронный saveDialogs при каждой мутации диалога; `:2285` — importProfile целиком на GUI; `:2789` — deleteProfile: removeRecursively на GUI; `:1844` — storageBreakdown: обход диска на GUI; `:1972` — декод полноразмерного фото аватара на GUI; `:645` — двойной fetchCorporateRoster на логин; `:2733` — N vault-расшифровок манифеста в getSessionList; `:1471` — мёртвый «жадный» корп-синк; `:1086` — checkTurnServer-заглушка «всегда доступен»; `ChatBackend.cpp:2726` — O(n×m)-мерж кэша сообщений; `:2434` — полный re-fetch окна 2000 ради точечных апдейтов; `:2550` — двойной emit messagesReceived; `:1649` — весь mp4 через RAM при проигрывании; `ChatBackend.hpp:221` — write-only m_seenIds; `ChatPage.qml:1771` — MediaPlayer+AudioOutput синхронно при каждом открытии чата; `ChatPage.qml:3689` — скрамбл-биндинг во всех делегатах каждые 45 мс; `ffi.rs:3483` — новый tokio Runtime + reqwest-клиент на каждый фоновый опрос (батарея); `ffi.rs:66` — 10 Гц-пробуждения race_shutdown весь long-poll (батарея); `ffi.rs:3256` — мёртвая пара одиночного service-notify в 4 слоях; `ffi.rs:1067` — мёртвый старый путь отправки файлов (4 FFI-входа); `dialogue.rs:592` — 3-4 fsync-коммита на каждый входящий пакет (транзакций нет); `dialogue.rs:1303` — полный receive() перед каждым фото мозаики; `dialogue.rs:1192` — мёртвое in-RAM семейство отправки; `store.rs:923` — outbound_transfers переживают удаление диалога (privacy + зомби-заливка); `LinuxNotifier.cpp:34` — блокирующий D-Bus (до 25 с) на GUI; `InstallServerBackend.cpp:111` — usleep(1000)=1 мс, пауза-пустышка → флап установки; `NotificationCoordinator.cpp:210` — фоновый таймер 2-15 с на Android вопреки энергорежимам; `:501` — JNI+commit+двойная сериализация на каждый тик; `:63` — 2-4 полных опроса за одно iOS BGTask-пробуждение; `:424` — мёртвая ветка сброса → висящий бейдж; `VersionInfoBackend.cpp:416` — queued-событие на каждый сетевой чанк; `QrCodeUtils.cpp:50` — полноразмерный ZXing-декод на GUI; `ClipboardUtils.cpp:32` — двойной трансфер буфера + PNG-кодирование на GUI; `SpellHighlighter.cpp:155` — полный Hunspell-рескан текста на каждый символ; `Utils.cpp:174` — N+1 vault-декриптов манифеста профилей; `CallSignalingClient.cpp:151` — stop() блокирует GUI на 3 с; `CallController.cpp:1234` — блокирующий DNS-резолв TURN на GUI; `CallEngine.cpp:907` — 3.1 МБ аллокация + копия NAL на каждый кадр; `VideoCapture.cpp:467` — лишняя packed-прослойка 1.3 МБ на кадр; `CallController.cpp:852` — мёртвый trySwitchToTurn + 3 поля-сироты; `MainBackend.cpp:2154` — changeProfileServer: teardown+5 vault-операций в onClicked; `Main.qml:194` — синхронная загрузка CallPage/QtMultimedia на старте; `MainPage.qml:693` — полный ресет модели диалогов на каждый тик уведомлений; `ExportImportPage.qml:62` — сброс ручного выбора экспорта ключей на каждый dialogsChanged; `corp_api.rs:50` — corp/dist-конверт БЕЗ HTTP-маскировки при включённой маскировке (ИБ); `corp_api.rs:326` — Runtime+reqwest на каждый corp/admin-вызов; `profile.rs:32` — поля маскировки профиля не подключены → все клиенты с одним UA (ИБ); `qr_exchange.rs:198` — мёртвый API + неподключённый анти-replay exchange_id; `turn.rs:274` — двойной parse + 3 копии payload на каждый relay-пакет; `voip_ffi.rs:183` — синхронный дубль call_signal_send с копией логики подписи; `nal.rs` — мёртвый модуль, wire-логика в 2 копиях; `signaling.rs:119` — мёртвые типы контракта, дрейф session_id 16≠32 уже случился; `mcp_server.rs:127` — fsync/Argon2 на единственном потоке MCP («STDIO dropped»); `main.rs:566`+`tui.rs:265` — busy-опрос при неудержанном /notify; `main.rs:1819` — Argon2 64МиБ на каждую CLI-команду; `main.rs:390` — topic list дренирует курсор приёма вопреки правилу trim; `ChatPage.qml:5161` — скелет confirm-попапа ×10 в 6 файлах (стили уже дрейфуют); `ChatBackend.cpp:1679` — мёртвая цепочка deleteMessagesUntil в 4 слоях (⚠️ бэклог keep-last-N) |
| **low** | `dialogues.rs:81` — O(n²) SHA256 в prune; `pull.rs:76` — `dbg!` в проде; `store.rs:36` — лишние `unsafe impl`; `CenteredPane.qml` — сирота; `AppIcon.qml` — дубли глифов; `SessionStore.cpp:30` — мёртвые sessionFor/loadDialogs/deriveKey; `ActiveChatNotifier.cpp:69` — вечные 2с-пробуждения idle-воркера; ChatPage.qml/PhotoMosaic.qml — 5 мёртвых артефактов итераций (topic-функции, saveDialog-сирота, sendSelectedPhotos, tileProgress, _mosaicDebug); `EmojiPicker.qml:28` — второй устаревший эмодзи-пикер; `MessageText.qml:34` — двойной measure-прогон; `ChatPage.qml:23` — полный getDialogs на каждый dialogsChanged; `ffi.rs:2127`/`:1559`/`:3176` — мёртвые FFI-поверхности (fetch_and_apply_signed_profile, одиночный unread-notify, vault_*_attachment); `ffi.rs:1645` — двойная (де)сериализация keyring в multi-notify; `vault.rs:455` — rekey-локи через долгий I/O (гигиена); `dialogue.rs:979` — sync-I/O в async (стопорит LocalSet EasyCli); store/transport/local_vault — 6 мелких артефактов (seqs_for_topic, тройная HTTP-обвязка, 5 копий atomic-write, ArrivedResponse.ts, HKDF-константа-обманка, check_token/current_root); `IosImagePicker.mm:83` — JPEG-кодирование на main; `PlatformNotifications.cpp:222` — мёртвые takeOpenPeer/clearServiceSnapshot; `Paths.cpp:11` — лукап+mkpath на каждый вызов; `ClientSSH.cpp:148/:226` — мёртвая non-blocking машинерия + std::cout-дамп скриптов; `adminStorage.cpp:45` — legacy-парсер вопреки политике; `SpellChecker.hpp:12` — мёртвая QML-регистрация; `CallSignalingClient.cpp:180` — msleep(400)-петля в фоне; `CallEngine.cpp:648` — мёртвая обёртка start(); `VideoTranscoder.cpp:107` — неиспользуемый AVFrame; `UnlockPin.qml:200` — ~110 строк копипаста keypad из SetPin; `ChangePin.qml:29` — 80мс-таймер-workaround, решённый в C++; `VersionInfoPage.qml:13` — мёртвое releasesUrl; страницы регистрации/экспорта — 6 мелких (экспорт синхронно на GUI, re-fetch ростера ради флага, caption-полоса QrCodeBox, min/max-константа, tariff/hasTrusted, тройная QR-копипаста); `client_cover_food.rs:187` — неинтерполированный «{msg}» в ошибке push; voip-стек — 5 мелких (pack-копии, мёртвые jitter.rs/TURN-auth/stun_discover/не-_owned методы); easycli — 6 мелких (2-3 чтения стора на операцию, лог без ротации, self_hash-дубль, старая раскладка мастера, hex_lower, дубль set_owner_only_permissions); межфайловые дубли — 4 (обвязка роутов сервера ×7 с потерянным warn! на /push, JNI SAF ×2, STUN-примитивы ×3, keyring-конверсия в TUI); финальный свип — 10 мелких мёртвых (vaultLock-цепочка без кнопки, vaultSetPinResult-сирота → молчащая ошибка PIN, save_attachment/send_read_receipt/bound-start/4 Q_INVOKABLE/outgoing/Java-пикер/QML-россыпь/3 pub fn) |

## Покрытие ревью

✅ **Ревью ПОЛНОЕ: 18/18 зон** (2026-07-06 — 2026-07-21, воркфлоу `review-zone`, каждая находка подтверждена adversarial-верификатором; суммарно ~162 подтверждённых находки, 1 опровергнута, дубли между зонами слиты — итого 149 пунктов плана):

- ✅ **ParanoiaServer** (все роуты, store, schema_cover, voip_stun) — 9 находок;
- ✅ **QML: Components + keyboard** (ParaInput, AppIcon, раскладки VKB) — 4 находки;
- ✅ **C++: main + MainBackend + session/** (`cpp-main-session`) — 12 находок (2026-07-07, воркфлоу `review-zone`, все подтверждены adversarial-верификацией);
- ✅ **C++: ChatBackend + ActiveChatNotifier + EmojiImageProvider** (`cpp-chat`) — 9 находок (2026-07-20; 10-я опровергнута верификатором: нотифаер после logout уже в idle);
- ✅ **QML: ChatPage + чат-компоненты** (`qml-chat`) — 11 находок (2026-07-20; одна — QML-сторона saveDialogs — слита с п. 12 файла фризов);
- ✅ **Rust: FFI-ядро** (`rust-ffi-core`: ffi.rs, lib.rs, crypto, packet) — 8 находок (2026-07-20);
- ✅ **Rust: dialogue + store + transport + local_vault** (`rust-dialogue-store`) — 12 находок (2026-07-20);
- ✅ **C++: уведомления + платформенный код** (`cpp-notify-platform`) — 9 находок (2026-07-20);
- ✅ **C++: utils/ + spell/ + profiling/** (`cpp-utils-spell`) — 10 находок (2026-07-20);
- ✅ **C++: src/voip/ клиента** (`cpp-voip`) — 10 находок (2026-07-20);
- ✅ **QML: Main/Theme/MainPage/Settings/PIN** (`qml-main-pages`) — 10 находок (2026-07-20; 3 слиты с существующими пунктами MainBackend — deleteProfile/storageBreakdown/getSessionList);
- ✅ **QML: регистрация/импорт/QR-страницы** (`qml-pages-reg`) — 11 находок (2026-07-21; 4 слиты с существующими — importProfile/маскировка/saveDialogs-путь/QR-декод);
- ✅ **Rust: export/corp/admin/cover + ParanoiaCover** (`rust-misc`) — 5 находок (2026-07-21; из них 2 с ИБ-подтекстом: немаскированный corp-конверт, неподключённые поля маскировки);
- ✅ **Rust: voip_ffi + ParanoiaLibrary/src/voip** (`rust-voip`) — 11 находок (2026-07-21);
- ✅ **ParanoiaEasyCli** (`easycli`) — 11 находок (2026-07-21; watch+TUI busy-опрос слиты в один пункт);
- ✅ **Сквозной свип фриз-цепочек** (`sweep-freeze-paths`) — 1 находка (2026-07-21), но корневая: ложная предпосылка ffiMutex-сериализации;
- ✅ **Сквозной свип дублей** (`sweep-duplication`) — 8 находок (2026-07-21; 3 слиты с существующими пунктами);
- ✅ **Сквозной свип мёртвого кода** (`sweep-artifacts`) — 11 находок (2026-07-21).

Все зоны пройдены. Воркфлоу `review-zone` (`.claude/workflows/review-zone.js`) остаётся для повторных ревью после доработок: «запусти ревью зоны &lt;ключ&gt;». Чек-лист:

| Зона | Что покрывает | Статус |
|---|---|---|
| `server` | ParanoiaServer целиком | ✅ 2026-07-06 |
| `qml-components-kbd` | ui/Components + клавиатура | ✅ 2026-07-06 |
| `cpp-main-session` | main, MainBackend, session/ | ✅ 2026-07-07 |
| `cpp-chat` | ChatBackend, EmojiImageProvider | ✅ 2026-07-20 |
| `cpp-notify-platform` | уведомления + платформенный код | ✅ 2026-07-20 |
| `cpp-utils-spell` | utils/, spell/, profiling/ | ✅ 2026-07-20 |
| `cpp-voip` | src/voip/ клиента | ✅ 2026-07-20 |
| `qml-chat` | ChatPage + чат-компоненты | ✅ 2026-07-20 |
| `qml-main-pages` | Main/Theme/MainPage/Settings/PIN | ✅ 2026-07-20 |
| `qml-pages-reg` | регистрация/импорт/QR-страницы | ✅ 2026-07-21 |
| `rust-ffi-core` | ffi.rs, crypto, packet | ✅ 2026-07-20 |
| `rust-dialogue-store` | dialogue, store, transport, local_vault | ✅ 2026-07-20 |
| `rust-misc` | export/corp/admin/cover + ParanoiaCover | ✅ 2026-07-21 |
| `rust-voip` | voip_ffi + ParanoiaLibrary/src/voip | ✅ 2026-07-21 |
| `easycli` | ParanoiaEasyCli | ✅ 2026-07-21 |
| `sweep-freeze-paths` | сквозной: цепочки QML→C++→FFI→Rust | ✅ 2026-07-21 |
| `sweep-duplication` | сквозной: межфайловые дубли | ✅ 2026-07-21 |
| `sweep-artifacts` | сквозной: мёртвый код по всему репо | ✅ 2026-07-21 |

**Рекомендуемый порядок доработки:** сначала ⭐ корневая п. 32 файла фризов (сужение ffiMutex-критсекции — закрывает сразу семейство конвоев), затем high-фризы горячих путей (saveDialogs/parseMessages/видеотракт звонка/Hunspell), батарейные Runtime-фиксы (единый OnceLock для service-notify/call_poll/corp), SQLite-транзакции, ИБ-пункты (corp-конверт без маскировки, неподключённые поля профиля, анти-replay), остальное — по severity.

## Осознанные решения — НЕ проблемы

При доработке не «чинить» как лишние операции: long-poll ~25–30 с и поллинг вместо push (принципиально — приватность метаданных); cover-трафик и маскировку (schema_cover, food_delivery_cover — «лишние» запросы намеренны); инвертированную ленту чата (BottomToTop).
