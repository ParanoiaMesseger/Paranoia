# Paranoia Messenger — Voice (and Future Video) Call Implementation Policy

## Overview

This document describes the architecture and implementation policy for adding peer-to-peer voice calls (and future H.264 video calls) to the Paranoia messenger. The design goals are:

- **End-to-end encryption** using pre-distributed per-dialog keys (ChaCha20-Poly1305 AEAD)
- **Minimal protocol surface** — no SIP, no full WebRTC stack, no unnecessary signaling overhead
- **Clear Rust/Qt boundary**: cryptographic core and network transport in Rust (Tokio); audio I/O, codec, and UI in Qt (C++)
- **Single codec**: Opus for voice, H.264 (future) for video
- **P2P first**: direct UDP connection via NAT traversal; relay (TURN-like) fallback via own server

---

## Architecture Layers

```
┌─────────────────────────────────────┐
│           Qt (C++) Layer            │
│  QAudioSource / QAudioSink          │
│  libopus (encode/decode)            │
│  QML UI (call screen, status)       │
│  CXX-Qt bridge                      │
└────────────────┬────────────────────┘
                 │ CXX-Qt FFI (zero-copy &[u8] slices)
┌────────────────▼────────────────────┐
│            Rust Layer               │
│  Tokio async runtime                │
│  Transport (UdpSocket + ICE/STUN)   │
│  Crypto Core (ChaCha20-Poly1305)    │
│  Key derivation (HKDF / crypto_kdf) │
│  Session state machine              │
└─────────────────────────────────────┘
                 │ UDP
┌────────────────▼────────────────────┐
│            Network                  │
│  P2P (UDP hole-punching via STUN)   │
│  Relay fallback (own TURN server)   │
└─────────────────────────────────────┘
```

---

## Cryptography Policy

### Cipher Suite

| Parameter | Value |
|---|---|
| Algorithm | ChaCha20-Poly1305 (IETF variant, RFC 8439) |
| Key size | 256 bit |
| Nonce size | 96 bit (12 bytes) |
| Authentication tag | 128 bit (Poly1305 MAC) |
| Crate | `chacha20poly1305` (RustCrypto) |

**Never use bare ChaCha20 without Poly1305.** Every media packet must be AEAD-encrypted to prevent in-transit modification.

### Key Derivation (HKDF)

Each dialog already has a secure pre-distributed master key. This master key **must not** be used directly for media encryption. Instead, derive per-session ephemeral keys for each call:

```
HKDF-SHA256(
  IKM  = dialog_master_key,
  salt = call_session_id,       // unique per call (random 16 bytes, exchanged via signaling)
  info = b"paranoia-voice-tx"   // separate info strings for TX and RX directions
) → session_key_tx (32 bytes)

HKDF-SHA256(
  IKM  = dialog_master_key,
  salt = call_session_id,
  info = b"paranoia-voice-rx"
) → session_key_rx (32 bytes)
```

- Initiator encrypts outgoing audio with `session_key_tx`, decrypts incoming with `session_key_rx`.
- Responder has the same derivation but swaps TX/RX labels.
- Implementation: use the `hkdf` crate (with `sha2` backend) or `libsodium`-compatible `crypto_kdf_*` API.
- `call_session_id` is generated fresh by the initiator for each call and transmitted via the existing messaging channel as part of call signaling.

### Nonce Construction

Nonce uniqueness is critical. **A repeated (key, nonce) pair completely breaks ChaCha20-Poly1305.**

```
Nonce (96 bit) = [stream_id: 1 byte] [direction: 1 byte] [sequence_number: 8 bytes (big-endian)] [padding: 2 bytes = 0x00]
```

- `stream_id`: 0 = voice, 1 = video (future)
- `direction`: 0 = TX from initiator, 1 = TX from responder (prevents nonce collision when both derive the same key)
- `sequence_number`: monotonically increasing per-stream counter, starting at 0 each session
- Sequence number is **64-bit** to prevent rollover for any realistic call duration
- On session teardown, keys and counters are zeroed from memory

---

## Custom RTP-Like Packet Format

A lightweight packet header is prepended to each Opus frame before encryption. The authenticated additional data (AAD) for AEAD covers the header, providing integrity without encrypting it.

```
Byte offset    Field                   Size
─────────────────────────────────────────────────
0              Version (= 0x01)        1 byte
1              Stream ID               1 byte  (0=voice, 1=video)
2              Flags                   1 byte  (bit0 = comfort noise, bit1 = frame start)
3              Reserved                1 byte
4–11           Sequence Number         8 bytes (big-endian u64)
12–15          RTP Timestamp           4 bytes (48000 Hz units for Opus)
16 – N         ChaCha20-Poly1305       (encrypted Opus payload + 16-byte Poly1305 tag)
               ciphertext + tag
```

- Header bytes 0–15 are passed as **AAD** to `encrypt_in_place()` — they are integrity-protected but not encrypted.
- The receiver first verifies the Poly1305 tag before processing any data. Packets with invalid MACs are silently dropped.
- This format replaces SRTP entirely and requires no SDP negotiation.

---

## Codec Layer (Qt / C++)

### Audio Pipeline

```
Microphone
    │
    ▼
QAudioSource (PCM, 48 kHz, mono/stereo)
    │
    ▼
libopus opus_encode()  →  Opus frame (20 ms = 960 samples @ 48 kHz)
    │
    ▼  (via CXX-Qt channel, &[u8] slice, zero-copy)
Rust transport layer  →  [encrypt] → [add header] → UdpSocket::send_to()

Incoming UDP
    │
    ▼
Rust transport layer  →  [verify MAC] → [decrypt] → Opus payload
    │
    ▼  (via CXX-Qt channel)
libopus opus_decode()
    │
    ▼
QAudioSink (PCM playback)
```

### Codec Parameters

| Parameter | Value |
|---|---|
| Sample rate | 48 000 Hz |
| Channels | 1 (mono) for voice; 2 (stereo) future option |
| Frame size | 20 ms (960 samples) — good latency/quality balance |
| Bitrate | 16–64 kbps (adaptive, `OPUS_AUTO` or explicit) |
| Application mode | `OPUS_APPLICATION_VOIP` |
| DTX | Enabled — suppresses transmission during silence |
| FEC | Enabled (`opus_encoder_ctl(OPUS_SET_INBAND_FEC(1))`) |
| Packet loss concealment | Handled by `opus_decode()` with NULL frame arg |

### Jitter Buffer

A simple ring-buffer jitter buffer must be implemented on the receiving side to reorder out-of-order packets before passing them to `opus_decode`. Recommended initial delay: 2–4 frames (40–80 ms). Packets that arrive too late (beyond buffer window) are discarded; `opus_decode` handles the gap with PLC.

---

## Video (Future — H.264)

When video is added, the same transport and crypto stack is reused with minimal changes:

- Stream ID = `0x01` in the packet header
- `info` string in HKDF changes to `b"paranoia-video-tx"` / `b"paranoia-video-rx"`
- Qt Multimedia or a hardware encoder (e.g., `QMediaRecorder` with H.264 profile) produces H.264 NAL units
- NAL units are fragmented into MTU-safe chunks (≤1200 bytes payload) and each chunk is independently encrypted as a separate packet
- No RTP/RTCP — the same sequence number counter continues from the voice stream index space, or a separate counter per stream (preferred)
- Resolution negotiated via the existing messaging signaling channel before call start

---

## Transport Layer (Rust + Tokio)

### NAT Traversal Strategy

1. **Signaling**: The existing message server (already implemented) is used to exchange STUN-reflexive candidates and `call_session_id` between peers before the call starts. No new signaling server is needed.
2. **STUN**: Use own STUN server (RFC 8489). Both peers discover their external IP:port by sending `Binding Request` to the STUN server over UDP.
3. **UDP Hole Punching**: Peers simultaneously send probing packets to each other's external addresses. For most NAT types (full-cone, port-restricted, address-restricted) this succeeds within a few hundred milliseconds.
4. **TURN Relay Fallback**: If connectivity checks fail (e.g., symmetric NAT on both sides) within a timeout (3–5 seconds), the call is relayed via own TURN server. End-to-end encryption is preserved — the relay server only sees ciphertext.

### Tokio Main Loop (pseudocode)

```rust
async fn run_call(socket: UdpSocket, peer: SocketAddr, keys: SessionKeys, qt_tx: mpsc::Sender<Vec<u8>>, qt_rx: mpsc::Receiver<Vec<u8>>) {
    let keepalive = tokio::time::interval(Duration::from_secs(15));
    pin_mut!(keepalive);

    loop {
        tokio::select! {
            // Incoming UDP packet
            Ok((len, addr)) = socket.recv_from(&mut buf) => {
                if is_stun(&buf[..len]) {
                    handle_stun_response(&buf[..len]);
                } else if addr == peer {
                    if let Ok(opus) = decrypt_packet(&keys, &buf[..len]) {
                        qt_tx.send(opus).await.ok();
                    }
                }
            }

            // Outgoing Opus frame from Qt
            Some(opus_frame) = qt_rx.recv() => {
                let pkt = encrypt_packet(&mut keys, &opus_frame);
                socket.send_to(&pkt, peer).await.ok();
            }

            // NAT keep-alive
            _ = keepalive.tick() => {
                let ping = build_stun_binding_request();
                socket.send_to(&ping, peer).await.ok();
            }

            // Call teardown signal
            _ = shutdown.notified() => break,
        }
    }

    keys.zeroize(); // Zero keys from memory on hangup
}
```

### Muxing STUN and Media on One Port

STUN packets are identified by the magic cookie `0x2112A442` at bytes 4–7 of the packet (RFC 8489). Any packet not matching this pattern is treated as media. This allows a single `UdpSocket` to handle both ICE keep-alive traffic and encrypted Opus frames.

---

## CXX-Qt Integration

The Rust transport layer is exposed to Qt as a `QObject` using the `cxx-qt` crate (KDAB).

```rust
// Rust side (cxx-qt)
#[cxx_qt::bridge]
mod ffi {
    extern "RustQt" {
        #[qobject]
        type CallEngine = super::CallEngineRust;

        // Signals emitted to QML
        #[qsignal] fn call_state_changed(self: Pin<&mut CallEngine>, state: QString);
        #[qsignal] fn audio_frame_ready(self: Pin<&mut CallEngine>, frame: QByteArray);

        // Invokable slots from QML
        #[qinvokable] fn start_call(self: Pin<&mut CallEngine>, peer_id: QString);
        #[qinvokable] fn end_call(self: Pin<&mut CallEngine>);
        #[qinvokable] fn push_audio_frame(self: Pin<&mut CallEngine>, frame: QByteArray);
    }
}
```

- **Audio Qt → Rust**: `push_audio_frame()` is called from C++ after `libopus` encodes each 20 ms frame. `QByteArray` data is copied once (acceptable — ~50–100 bytes per frame).
- **Audio Rust → Qt**: `audio_frame_ready` signal carries the decrypted Opus payload back to C++ for decoding.
- **Call state**: `call_state_changed` carries states like `"connecting"`, `"connected"`, `"failed"`, `"ended"` to drive QML UI.

---

## Recommended Rust Crates

| Purpose | Crate |
|---|---|
| Async runtime | `tokio` (already in project) |
| AEAD encryption | `chacha20poly1305` (RustCrypto) |
| Key derivation | `hkdf` + `sha2` |
| Memory zeroing | `zeroize` |
| STUN/ICE | `webrtc-rs` (`stun`, `ice` crates) or `stun-rs` (sans-IO) |
| Qt bridge | `cxx-qt` (KDAB) |

---

## Security Considerations

1. **Forward Secrecy**: Ephemeral per-session keys derived with HKDF ensure that compromise of one call session does not expose other sessions.
2. **Replay Protection**: The monotonically increasing sequence number (part of the nonce) makes replayed packets detectable. The receiver maintains a small sliding window to reject replayed sequence numbers.
3. **DoS via forged packets**: Poly1305 MAC verification happens before any decoding. Invalid packets are dropped immediately with no further processing.
4. **Key Zeroing**: All session keys must be zeroed from memory using the `zeroize` crate when the call ends.
5. **Nonce Exhaustion**: With a 64-bit sequence counter and 20 ms frames, nonce exhaustion would take ~11.7 million years. This is not a practical concern.
6. **Metadata Leakage**: Packet sizes and timing are visible to the network. DTX (discontinuous transmission) is recommended to reduce traffic during silence but cannot fully hide metadata.

---

## Implementation Phases

| Phase | Scope | Status |
|---|---|---|
| 1 | HKDF key derivation + ChaCha20-Poly1305 encrypt/decrypt in Rust | To do |
| 2 | Custom packet format (header + AAD) | To do |
| 3 | Qt audio pipeline (QAudioSource → libopus → CXX-Qt → Rust) | To do |
| 4 | Tokio transport loop + STUN/NAT traversal | To do |
| 5 | Jitter buffer + PLC handling | To do |
| 6 | CXX-Qt QObject (CallEngine) + QML call UI | To do |
| 7 | TURN relay fallback | To do |
| 8 | Video (H.264) — future phase | Planned |
