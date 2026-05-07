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

## Dialog Changes

1. Extend local dialog data to store both `peerName` and `peerServerId`.
2. Use `peerName` only in UI.
3. Use `peerServerId` for send, receive, server-history cleanup, local dialogue keys, and last-pulled seq calls.
4. Preserve compatibility for existing local dialogs by treating old `peer` values as both display name and server id until migrated manually or through import/QR.

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
3. Existing local dialogs need migration or re-adding with peer server ids.
