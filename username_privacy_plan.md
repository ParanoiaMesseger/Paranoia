# Username Privacy Plan

Goal: stop sending human-readable usernames to the server without changing the server code or API. Server-side fields named `username`, `sender`, and `recver` will keep their current shape, but the client/library will fill them with opaque server ids.

## Approach

1. Treat `username` as a local display name only.
2. Derive the server-visible id from the user's Ed25519 public key:
   `server_id = sha256("paranoia:server-id:v1\n" + public_key_bytes)`.
3. Keep the server unchanged: it still stores `users: HashMap<String, String>` and verifies signatures over the same request fields.
4. Change FFI/library/client code so every server interaction uses `server_id` instead of display username.

## Client Changes

1. Add helpers to derive the Ed25519 public key from the stored private key and compute `server_id`.
2. Keep `ClientBackend::m_username` as the display username for UI and local profile metadata.
3. Add local state for the current user's `server_id`.
4. Change login so `paranoia_client_new` receives `server_id`, while UI continues to show `m_username`.
5. Change registration so the admin UI accepts/uses a public key and registers `server_id` as the server-side username.

## Server Installation Changes

During installation (`InstallServerBackend`) the admin currently only saves admin credentials after a successful server check. Extend this to also bootstrap the admin as a client on the same server:

1. Generate a separate client key pair (`client_private_key` / `client_public_key`) alongside the admin key pair at `StepGenerateKeys`.
2. At `StepVerifyServer`, after registering the admin identity, also call `regUser` with the client `server_id` derived from `client_public_key`.
3. On success, save client credentials via `ServerSession::saveClientConfigForProfile` (server URL + client `server_id` as username + `client_private_key`).
4. Update `Utils::upsertProfileManifest` so the new profile is listed and marked as last-used.
5. After `installFinished` is emitted, `Main.qml` should trigger `Backend.loginClient(domain, server_id, client_private_key)` automatically so the user lands in the main screen without a manual login step.
6. Emit `adminStateChanged` and `loginStateChanged` from `MainBackend` after the install signal so the UI reflects both roles immediately.

## Dialog Changes

1. Extend local dialog data to store both `peerName` and `peerServerId`.
2. Use `peerName` only in UI.
3. Use `peerServerId` for send, receive, server-history cleanup, local dialogue keys, and last-pulled seq calls.
4. Do not preserve compatibility for existing local dialogs; beta profiles must re-add contacts or import current-format data.

## Dialog Creation UI Changes

The current `AddDialogPage.qml` exposes two separate paths — shared-secret entry and QR/JSON exchange — which is confusing and offers a weaker security option. Simplify to a single path:

1. **Remove** the "Общий секрет" `ParaInput` field and the "Добавить" button from `AddDialogPage`.
2. **Remove** `Backend.addDialog(peer, secret)` call from QML. The C++ `MainBackend::addDialog` and `Dialog::deriveKey` implementations can be removed or left unused once no QML path calls them.
3. The only action on `AddDialogPage` is "Обменяться ключом через QR/JSON" which opens `QrExchangePage`. The display name field remains so the user can give the peer a local name before starting the exchange.
4. If the display-name field is empty, block navigation to `QrExchangePage` with an inline validation message (existing behaviour, keep it).

## QR / JSON Key Exchange UX Changes

The current `QrExchangePage.qml` exposes raw protocol concepts and text areas for JSON payloads. Replace it with a three-step visual pipeline. Users never see raw JSON — they only share/receive payloads via QR code or JSON file.

### Visual pipeline header

A compact strip at the top of the screen shows the three steps with SVG pictograms and connecting arrows. The active step is accented; completed steps are dimmed; future steps are greyed out.

```
 [✉ Приглашение] ──▶ [🤝 Принятие] ──▶ [🔒 Сравнение]
        ●                  ○                  ○
```

Suggested SVG icons (inline in QML as `Shape`/`Image` from `qrc:`):
- **Step 1 — Приглашение**: envelope with an outgoing arrow.
- **Step 2 — Принятие**: two envelopes facing each other (or a handshake outline).
- **Step 3 — Сравнение**: two shield outlines with a checkmark between them.

The strip is purely decorative/informational and does not react to taps.

### State machine (internal)

| State | Active step | What the user sees |
|---|---|---|
| `s1_share` | 1 | Own QR + share buttons. Prompt to get peer's code. |
| `s2_receive` | 2 | "Get peer's code" buttons (scan / file). After receiving: own updated QR + share buttons. |
| `s3_compare` | 3 | SAS displayed. "Подтвердить" button. |
| `done` | — | Success illustration + "Готово" button. |

On screen open: invitation is generated automatically (`Backend.createDialogKeyInvitation`). State → `s1_share`. `_localState` stored as hidden QML property.

### Step 1 — Приглашение (`s1_share`)

Content area:
- Own QR code (large, centered).
- Two buttons below the QR:
  - **"Поделиться QR"** — opens system share sheet with the QR image (`QrCodeUtils.saveToTemp` + Qt share).
  - **"Сохранить JSON"** — writes payload to a file via `FileDialog` (save mode).
- Separator and prompt text: «Получите код от собеседника:»
- Two buttons:
  - **"Сканировать QR"** — opens camera scanner.
  - **"Выбрать JSON-файл"** — opens `FileDialog` (open mode).
- No text areas. No paste field.

When a peer payload is received (via scan or file):
- App detects payload type from JSON structure (`"type": "invitation"` or `"type": "response"`).
- If `invitation` → call `Backend.createDialogKeyResponse(peerPayload)`. Own payload updated silently. SAS computed. State → `s2_receive`.
- If `response` → call `Backend.dialogKeyFingerprint(_localState, peerPayload)`. SAS computed. State → `s3_compare`.

### Step 2 — Принятие (`s2_receive`)

Shown when this device generated a response (was the responder). Content area:
- Status text: «Ваш код обновился. Отправьте его собеседнику.»
- Own updated QR code.
- **"Поделиться QR"** and **"Сохранить JSON"** buttons (same as step 1).
- Separator: «Сравните код безопасности:»
- SAS displayed prominently (large, monospace, coloured).
- **"Подтвердить"** button → calls `Backend.confirmDialogKeyExchange`. State → `done`.

### Step 3 — Сравнение (`s3_compare`)

Shown when this device is finalising (was the initiator). Content area:
- Status text: «Сравните код безопасности вслух с собеседником.»
- SAS displayed prominently.
- **"Подтвердить"** button → calls `Backend.confirmDialogKeyExchange`. State → `done`.

### Done screen

- Success illustration (SVG checkmark / lock).
- Text: «Ключ установлен. Можно начинать переписку.»
- **"Готово"** button → emits `exchangeConfirmed()` and navigates back.

### Key implementation notes

- `_localState` and `_peerPayload` are private `property string` values — never rendered in any visible element.
- No `TextArea` for JSON anywhere on the screen.
- Payload type detection via a small helper in `MainBackend` (or QML): check presence of a discriminating key in the parsed JSON object.
- The `FileDialog` for saving the JSON should suggest a filename like `paranoia-invite-<peer>.json`.
- The `FileDialog` for opening accepts `*.json` and all files.
- QR scanner reuses the existing `QrCodeUtils.decodeFromImage` path if a camera scanner widget is not available — fall back to "Выбрать изображение QR" in that case.
- After confirmation emit `exchangeConfirmed()` as before.

## FFI / Library Changes

1. Keep exported FFI function signatures mostly unchanged where possible.
2. Interpret `user_a` and `user_b` passed from the client as server ids for all networked operations.
3. Keep server request JSON unchanged: `/reg`, `/push`, `/pull`, `/determinate` still receive the same field names.
4. Ensure signatures are computed over server ids, matching what the unchanged server verifies.

## QR / Import Changes

1. Include `display_name`, `server_id`, and public key in local contact exchange/export payloads.
2. Store imported contacts with display name plus server id.
3. Do not rely on display username for addressing.

## Verification

1. Register a user and confirm server config contains only a 64-char server id, not the display username.
2. Send, pull, and clear history while confirming request bodies/logs contain server ids only.
3. Confirm UI still displays human-readable names from local metadata.
4. Confirm two clients can communicate when they know each other's `server_id`.

## Caveats

1. The server still learns stable user ids and communication graph.
2. Existing server registrations by plaintext username will not automatically match new server ids.
3. Existing local dialogs need re-adding with peer server ids.
