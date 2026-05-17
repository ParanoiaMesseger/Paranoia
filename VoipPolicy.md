# Политика VoIP-звонков

## Обзор

Политика описывает архитектуру и криптографические правила P2P-звонков (голос + видео) в Paranoia Messenger.

**Принципы:**

- Шифрование end-to-end на уровне отдельных медиа-пакетов (ChaCha20-Poly1305 AEAD); сервер видит только метаданные и зашифрованные конверты сигналинга.
- Никакого SIP/SDP/полной WebRTC-стеки. Своя минимальная wire-format поверх UDP.
- Чёткая граница: Rust держит крипто-ядро, транспорт, сигналинг, NAT-протоколы; Qt — захват/воспроизведение медиа, кодеки, QML-UI.
- Один кодек на каждый медиа-поток: Opus для голоса, H.264 для видео.
- Один UDP-сокет на звонок мультиплексирует оба потока — это даёт одно NAT-mapping вместо двух.
- P2P первично; релей сервера (TURN) опционален и только при отсутствии прямой связности (см. ниже — TURN-протокол реализован, но в путь звонка пока не подключён).

***

## Архитектурные слои

```
┌─────────────────────────────────────────┐
│              Qt (C++) слой              │
│  AudioCapture / AudioPlayback (QtMM)    │
│  VideoCapture (QCamera) / VideoSink     │
│  libopus, libavcodec (FFmpeg, hwaccel)  │
│  CallEngine, CallController             │
│  CallSignalingClient (long-poll thread) │
│  QML: CallPage с VideoOutput            │
└────────────────┬────────────────────────┘
                 │ C FFI (paranoia_lib.h)
┌────────────────▼────────────────────────┐
│             Rust (Tokio) слой           │
│  voip::transport (UDP + STUN mux)       │
│  voip::crypto (HKDF + AEAD + Zeroize)   │
│  voip::packet (header + ReplayWindow)   │
│  voip::nal (NAL Fragmenter/Reassembler) │
│  voip::signaling (sealed envelopes)     │
│  voip::stun / voip::turn                │
└────────────────┬────────────────────────┘
                 │ UDP / HTTPS
┌────────────────▼────────────────────────┐
│                Сеть                     │
│  P2P UDP (STUN hole-punching)           │
│  Server HTTP: /call/signal, /call/poll  │
└─────────────────────────────────────────┘
```

Граница Rust ↔ Qt — обычное C-FFI (заголовок `paranoia_lib.h`, символы `extern "C"` в `voip_ffi.rs`). CXX-Qt не используется.

***

## Криптография

### Шифр

| Параметр | Значение |
|---|---|
| Алгоритм | ChaCha20-Poly1305 IETF (RFC 8439) |
| Длина ключа | 256 бит |
| Длина nonce | 96 бит (12 байт) |
| Тег MAC | 128 бит (Poly1305) |
| Реализация | `chacha20poly1305` (RustCrypto) |

Никаких «голых» потоковых шифров. Каждый медиа-пакет — AEAD-конверт; целостность заголовка обеспечивается AAD.

### Деривация ключей (HKDF-SHA256)

Dialog master key (32 байта, общий ключ диалога) **не используется напрямую** для медиа-шифрования. На каждый звонок инициатор генерирует случайный `session_id` (16 байт), который передаётся в Offer'е, и обе стороны выводят пары направленных ключей через HKDF-SHA256:

```
SessionKeys::derive(master_key, session_id, stream_id, role) →
    tx = HKDF(IKM=master_key, salt=session_id, info=info_tx)
    rx = HKDF(IKM=master_key, salt=session_id, info=info_rx)

info_tx / info_rx — одна из четырёх констант:
    "paranoia-voice-tx"  / "paranoia-voice-rx"
    "paranoia-video-tx"  / "paranoia-video-rx"

У инициатора:  info_tx = «-tx», info_rx = «-rx»
У ответчика:   info_tx = «-rx», info_rx = «-tx»  (зеркало)
```

Таким образом `init.tx == resp.rx` и `init.rx == resp.tx`, а ключи voice ≠ video. `StreamKeys` — обёртка, держащая обе пары (`voice` и `video`), индексируется по `StreamId`.

`SessionKeys` хранится в обёртке с `#[derive(ZeroizeOnDrop)]` — буферы ключей очищаются на drop'е и явно при завершении `run_session`.

### Свойства защиты

Заявленный уровень — **прямая секретность относительно session_id**: компрометация одного `session_id` не открывает другие звонки. Однако компрометация **master key диалога** разрешает расшифровать все звонки, сделанные этим диалогом, при условии что записаны их сырые UDP-потоки и захвачены `session_id` из сигналинга. Это не «perfect forward secrecy» в смысле Signal Protocol — отдельного эфемерного DH-обмена на каждый звонок нет. Защита та же, что у самих сообщений: завязана на ротацию `master_key` диалога.

### Конструкция nonce

Уникальность пары (key, nonce) критична. Nonce 96 бит:

```
[stream_id : 1 байт] [direction : 1 байт] [sequence : 8 байт BE] [0x00 : 2 байта padding]

stream_id : 0 = voice, 1 = video
direction : 0 = от инициатора к ответчику
            1 = от ответчика к инициатору
sequence  : per-stream монотонно растущий счётчик, начинается с 0 на сессии
```

`stream_id` + `direction` гарантируют, что одинаковые ключи в зеркальных HKDF не дают пересечение nonce. Sequence на 64 битах не исчерпается ни при какой реальной длительности.

***

## Wire-format медиа-пакета

```
смещение  поле                    размер
─────────────────────────────────────────
0         Version (= 0x01)        1 байт
1         Stream ID               1 байт   (0=voice, 1=video)
2         Flags                   1 байт   (см. ниже)
3         Reserved                1 байт   (должно быть 0)
4..12     Sequence Number         8 байт   (BE u64)
12..16    RTP Timestamp           4 байта  (BE u32)
                                            voice: единицы 48 kHz (≈seq·960)
                                            video: единицы 90 kHz (общий ts на NAL)
16..N     ChaCha20-Poly1305(...)            ciphertext || 16-байт Poly1305 tag
```

Байты 0..16 идут в AEAD как **AAD** — они в открытом виде, но защищены MAC'ом.

### Flags

| Бит | Voice | Video |
|---|---|---|
| 0 | COMFORT_NOISE (keepalive с пустым payload) | FRAGMENT_END (последний фрагмент NAL'а — переиспользует тот же бит, так как comfort noise для video бессмыслен) |
| 1 | — | FRAME_START (первый фрагмент NAL'а) |
| 2..7 | RESERVED — должны быть 0; пакет с любым выставленным резервированным битом отбрасывается. |

### Защита от replay

Каждый поток (voice, video) имеет независимый 64-битный sliding-window-битмап (`ReplayWindow`). Реалии:

- Принимается любой `seq > highest_seen` — окно сдвигается.
- В пределах окна (≤ 63 от `highest`) принимается каждый seq не более одного раза.
- Старее `highest − 63` — гарантированно отвергается.

Пакеты, не прошедшие AEAD-проверку (плохой MAC, неверная версия, выставленный reserved-бит), молча отбрасываются.

### Размерные ограничения

- `MAX_DATAGRAM = 1400` (MTU-safe).
- `MAX_FRAGMENT_PAYLOAD = 1400 − 16 (header) − 16 (Poly1305 tag) = 1368` байт.
- Voice (Opus 24 kbps, 20 мс @ 48 kHz) укладывается в один пакет.
- Video (H.264 NAL) фрагментируется (см. ниже).

***

## Сигналинг

Сигналинг идёт **через отдельные HTTP-эндпоинты** `/call/signal` (PUT) и `/call/poll` (PUT, long-poll). Это не messaging-канал — он короче, без store-and-forward и без attachment'ов. Сервер видит метаданные {sender, recver, kind, ts_ms} и зашифрованный payload.

### Конверт

```
payload = ChaCha20-Poly1305(
    key   = dialog_master_key,
    nonce = random 12 байт,
    msg   = serde_json(payload_struct)
)
envelope_bytes = nonce(12) || ciphertext || tag(16)
```

AAD не используется — целостность метаданных сервера обеспечивается Ed25519-подписью HTTP-запроса на уровне messaging-cover.

### Виды (`kind`)

| kind | Тип | Payload |
|---|---|---|
| 0 | Offer | `CallOfferPayload` |
| 1 | Answer | `CallAnswerPayload` |
| 2 | Hangup | `CallHangupPayload` |
| 3 | Ice | `CallIcePayload` (trickle одного кандидата) |

### Структуры payload

```rust
CallOfferPayload {
    call_id: String,            // UUID, генерит инициатор
    session_id: [u8; 16],       // base64; salt для HKDF
    streams: Vec<u8>,           // [0]=voice; [0,1]=voice+video
    candidates: Vec<String>,    // "ip:port", сначала локальные
    from_username: String,
    created_ts_ms: i64,
}

CallAnswerPayload {
    call_id: String,
    accept: bool,
    candidates: Vec<String>,
    streams: Vec<u8>,           // пересечение того, что ответчик готов поддержать
    reason: String,             // непустой при accept=false
}

CallHangupPayload  { call_id, reason }
CallIcePayload     { call_id, candidate }
```

`streams` — массив `StreamId` (0=voice, 1=video). Инициатор объявляет, что готов отдать; ответчик в Answer указывает, на какие из них он согласен. Если ответчик отозвал видео (нет камеры / отказ пользователя) — Answer-streams = `[0]`, и инициатор камеру не включает.

### Long-poll

Клиент держит запрос на `/call/poll` до 25 секунд. Конверты с неподобранным master_key или повреждённым ciphertext тихо отбрасываются на стороне FFI; UI видит только успешно расшифрованные.

***

## Голосовой пайплайн

### Параметры Opus

| Параметр | Значение |
|---|---|
| Sample rate | 48 000 Hz |
| Каналов | 1 (mono) |
| Размер фрейма | 20 мс (960 семплов) |
| Application mode | `OPUS_APPLICATION_VOIP` |
| Bitrate | 24 kbps по умолчанию, VBR |
| Inband FEC | включён |
| DTX | включён (молчание не передаётся) |
| Packet loss perc | 5% (подсказка энкодеру) |
| Complexity | 8 |
| Signal hint | `OPUS_SIGNAL_VOICE` |
| PLC | штатный `opus_decode(NULL)` на пропуски |

### Поток

```
QAudioSource (PCM s16 mono 48 kHz)
    → AudioCapture: режет на 20-мс фреймы → QByteArray (1920 байт)
    → OpusEncoder::encode → ~50 байт Opus
    → paranoia_call_session_push_opus → mpsc → Rust transport
    → encrypt + send_to

recv_from → decrypt → frame_cb → CallEngine::enqueueIncomingFrame
    → jitter-буфер (Qt-side: 3..16 фреймов глубины, sequence-ordered, sliding по `expected`)
    → 20-мс QTimer pop → OpusDecoder::decode (или PLC на пропуске)
    → AudioPlayback (QAudioSink)
```

Jitter-буфер реализован на Qt-стороне. Параметры: initial delay 3 фрейма (60 мс), max depth 16 (320 мс); при PLC-streak > 12 — resync с минимального доступного seq.

***

## Видео-пайплайн

### Параметры H.264

| Параметр | Значение |
|---|---|
| Профиль | Baseline |
| Разрешение | 1280×720 (адаптируется к ближайшему формату камеры) |
| FPS | 30 |
| Bitrate | ~1 Mbps |
| GOP | 60 кадров (keyframe каждые ~2 с) |
| B-frames | 0 (реалтайм) |
| Annex B | да (start-codes `00 00 00 01`) |
| RTP timestamp | 90 kHz |

### Кодеки и приоритет hardware-acceleration

`H264Encoder` пробует на инициализации первый рабочий кодек из платформенного списка:

| Платформа | Приоритет |
|---|---|
| macOS / iOS | `h264_videotoolbox` → `libx264` → `h264` |
| Android | `h264_mediacodec`* → `libx264` → `h264` |
| Windows | `h264_nvenc` → `h264_qsv` → `h264_amf` → `libx264` → `h264` |
| Linux | `h264_nvenc` → `h264_vaapi` → `libx264` → `h264` |
| Прочее | `libx264` → `h264` |

*Android `h264_mediacodec` требует `AVHWFramesContext` с Surface input — на текущий момент init дропается и поток уходит на `libx264` (software).

Низколатентные опции выставляются адресно по выбранному кодеку: `libx264` получает `preset=veryfast tune=zerolatency`; `videotoolbox` — `realtime=1 allow_sw=1`; `nvenc` — `preset=p1 tune=ull zerolatency=1`.

Декодер: на macOS/iOS — `h264_videotoolbox`, на Android — `h264_mediacodec`, иначе software `h264`. Не-`yuv420p` входы конвертируются через `swscale` в I420.

### Поток

```
QCamera + QMediaCaptureSession + QVideoSink (захват)
    → VideoCapture::onVideoFrame: подбор формата ближе к 720p30
    → swscale → I420 (1280×720, 1.4 MB / кадр)
    → emit frameReady(QByteArray, pts_90khz)
    → H264Encoder::encode → vector<QByteArray> (Annex B NAL'ы)
    → разрезание на фрагменты ≤ 1368 байт:
        первый: flags = FRAME_START
        последний: flags |= FRAGMENT_END
        rtp_timestamp общий на весь NAL
    → paranoia_call_session_push_h264 → mpsc → Rust transport
    → AEAD-шифрование с per-video-stream tx_seq → send_to

recv → decrypt → video_cb (stream_id, sequence, rtp_timestamp, flags, payload)
    → CallEngine::enqueueIncomingVideoFragment:
        смена rtp_timestamp → текущий буфер дропается
        FRAME_START → новый NAL
        FRAGMENT_END → готовый NAL → префикс 00 00 00 01 → H264Decoder::decode
    → H264Decoder::getDecoded → I420
    → VideoSinkBridge::setI420Frame → main thread → QVideoSink → QML VideoOutput
```

Локальный preview подключён напрямую к `QVideoSink` камеры (не проходит через сеть). Это бесплатно — QCamera всё равно отдаёт кадр в sink.

### Реассемблер

Состояние: `(current_ts, buffer, expecting)`. Правила:

- Получили фрагмент с другим `rtp_timestamp`, чем накопленный → старый буфер дропается (потеряли FRAGMENT_END последнего пакета).
- `FRAME_START` → буфер очищается, начинается новый NAL.
- `FRAGMENT_END` → буфер отдаётся декодеру как готовый NAL.
- Buffer > 4 MB → дроп (защита от bomb-пакетов).
- Фрагмент без активного `expecting` (получили середину без начала) → молча дропается.

### Гейтинг сборки

| Флаг | Зависит от |
|---|---|
| `PARANOIA_HAS_OPUS` | системный libopus или prebuilt из `deps/opus/<target>/` |
| `PARANOIA_HAS_QT_MULTIMEDIA` | Qt6::Multimedia |
| `PARANOIA_HAS_VOIP` | оба выше |
| `PARANOIA_HAS_FFMPEG` | pkg-config libavcodec+libavutil+libswscale или prebuilt из `deps/ffmpeg/<target>/` |
| `PARANOIA_HAS_VIDEO` | `HAS_VOIP && HAS_FFMPEG` |

Если `HAS_VIDEO=0`, исходники видео-стека (`H264Codec`, `VideoCapture`, `VideoSink` и video-секции `CallEngine`) из сборки исключаются; голос работает независимо.

***

## Транспорт

### Один сокет — оба потока

`spawn_session` поднимает одну фоновую Tokio-задачу `run_session` поверх единственного `tokio::net::UdpSocket`. Главный цикл — `tokio::select!` по пяти источникам:

1. `recv_from` — входящие пакеты;
2. voice outbound mpsc (Opus-фрейм от Qt);
3. video outbound mpsc (уже-фрагментированный NAL-пакет от Qt);
4. STUN outbound mpsc (Binding Request наружу);
5. keepalive-таймер (15 секунд);
6. shutdown notify.

`run_session` держит per-stream состояние независимо: два `tx_seq`, два `ReplayWindow`, `StreamKeys` с обоими наборами ключей. На приёме `stream_id` peek'ается из байта 1 пакета до AEAD, выбирается нужный rx-ключ.

### Keepalive

Каждые 15 секунд отправляется зашифрованный пакет на voice-потоке с `flags = COMFORT_NOISE` и пустым payload. Сохраняет NAT-mapping и сигнализирует «я ещё здесь».

### Авто-обнаружение peer'а

Сессия может быть запущена без заранее известного peer'а (`SessionParams.peer = None`). Первый валидный (прошедший AEAD) входящий пакет фиксирует peer-адрес. Это нужно когда NAT mapping становится известен только после первого пакета удалённой стороны.

### Сожительство со STUN

STUN-сообщения определяются по `magic cookie 0x2112A442` в байтах 4..8 пакета (RFC 8489) — это позволяет одному `UdpSocket` обслуживать одновременно медиа и ICE-keepalive без отдельных портов. Входящий `Binding Request` получает `Binding Success` с XOR-MAPPED-ADDRESS = адресу отправителя. Исходящий `Binding Request` (для discovery собственного reflexive) идёт через тот же сокет — это критично, иначе NAT-mapping для другого порта почти всегда отличается.

***

## NAT traversal

| Слой | Состояние |
|---|---|
| STUN (RFC 8489) | реализован, используется в каждом звонке через `paranoia_call_session_stun_discover` (тот же сокет, что и сессия). Reflexive адрес отправляется удалённой стороне как ICE-trickle. |
| ICE-trickle | примитивный — нет полного state machine RFC 8445. После Offer/Answer кандидаты добавляются через `kind=Ice` конверты; `engine_->setPeer(...)` принимает «лучшего из последних». |
| TURN (RFC 5766 subset) | встроенный STUN-listener сервера также обслуживает Allocate / Refresh / CreatePermission / Send/Data Indications. Клиент делает TURN Allocate через тот же UDP-сокет звонка и отправляет relay candidate, если после старта звонка не получил media напрямую. |

STUN-сервер задаётся через переменную окружения `PARANOIA_STUN_SERVER`; если пусто — STUN не вызывается, звонок работает только в локальной сети или при открытом IP.

***

## C FFI поверхность

```c
/* Сигналинг */
int   paranoia_call_signal_send(handle, from, to, master_key_b64, kind, payload_json);
char* paranoia_call_poll(handle, user, peers_keys_json, long_poll_ms);

/* UDP-сессия (мультиплекс voice+video) */
ParanoiaCallSession* paranoia_call_session_start(local_bind, peer_addr,
    master_key_b64, session_id_b64, role,
    frame_cb, video_cb, state_cb, userdata);
ParanoiaCallSession* paranoia_call_session_start_unbound(...);  /* peer определяется позднее */

int   paranoia_call_session_set_peer(s, peer_addr);
char* paranoia_call_session_local_addr(s);
char* paranoia_call_session_stun_discover(s, stun_server, timeout_ms);
char* paranoia_call_session_turn_allocate(s, turn_server, timeout_ms);
int   paranoia_call_session_set_turn_peer(s, turn_server, peer_relay_addr);

int   paranoia_call_session_push_opus(s, opus_bytes, len);
int   paranoia_call_session_push_h264(s, nal_fragment, len, flags, rtp_timestamp);

void  paranoia_call_session_stop(s);
```

Callback'и:

```c
typedef void (*paranoia_call_frame_cb)(void* ud, const u8* opus, size_t len, u64 seq);
typedef void (*paranoia_call_video_cb)(void* ud, const u8* nal, size_t len,
                                       u64 seq, u32 rtp_ts, u8 flags);
typedef void (*paranoia_call_state_cb)(void* ud, const char* state);
```

Все callback'и вызываются из фоновой Tokio-задачи; должны быть thread-safe со стороны caller'а. Указатели на буферы валидны только на время вызова — copy-on-receive обязателен (Qt-сторона делает `QMetaObject::invokeMethod` с `QByteArray`-копией).

NULL-значения video_cb / frame_cb допустимы — соответствующий поток молча игнорируется. Это позволяет audio-only клиентам не реализовывать видео-приём.

***

## Качества безопасности

1. **Прямая секретность относительно session_id** — компрометация HKDF-ключей одного звонка не открывает другие, так как `session_id` уникален. Защиты от компрометации master_key диалога нет (см. выше).
2. **Защита от replay** — sliding-window 64-битмап на каждый поток. Дубли и пакеты старше окна отбрасываются молча.
3. **DoS forged-пакетами** — Poly1305 MAC проверяется до любой обработки. Невалидные пакеты в трейс/лог не падают (только trace-level).
4. **Zeroization** — `SessionKeys` зануляется при drop'е через `zeroize` крейт; явно вызывается при штатном завершении `run_session`.
5. **Исчерпание nonce** — 64-битный sequence + 20-мс voice фреймы → ~11.7 млн лет до исчерпания; не практический риск.
6. **Метаданные** — размер и тайминг пакетов видимы сети. DTX в Opus уменьшает трафик в тишине, но не скрывает полностью. Длина видео-пакетов выдаёт scene complexity. Маскировка не предусмотрена.
7. **Сервер сигналинга** — наблюдает {sender, recver, kind, ts_ms, длина_зашифрованного_payload}. Содержимое Offer/Answer/Ice (call_id, session_id, кандидаты, list streams) для него недоступно.
8. **Reserved-биты header'а** — любой пакет с выставленным резервированным битом отвергается до AEAD; это даёт окно для будущих расширений wire-format без поломки версии.
