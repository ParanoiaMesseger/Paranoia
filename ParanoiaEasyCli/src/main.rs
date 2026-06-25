use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use clap::{Parser, Subcommand, ValueEnum};
use ed25519_dalek::SigningKey;
use paranoia_lib::{
    AdminKeyPair, ClientConfig, Dialogue, DialogueConfig, DialogueKey, DialogueKeyEntry, Message,
    MessageContent, ParanoiaClient, crypto, derive_topic_id,
    export::{
        EXPORT_PAYLOAD_VERSION, ExportAdminServer, ExportDialogue, ExportKeyEntry, ExportPayload,
        ExportProfileType, ExportServer, ecies_decrypt, ecies_encrypt, generate_device_keypair,
        pubkey_from_private_key, validate_export_payload,
    },
};
use paranoia_lib::transport::CoreCallSignal;
use rand::RngCore;
use rpassword::read_password;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

mod dialogue_store;
mod mcp_install;
mod mcp_server;
mod tui;
mod ui_store;

use dialogue_store::{
    MergeOutcome, ProfileDialogueStore, base64_entry_to_key, key_entry_from_base64,
    key_entry_from_hex, load_dialogue_store, merge_profile_keyring_entry, profile_id,
    profile_keyring_entries, resolve_peer_id, save_dialogue_store, set_dialogue_key,
};

const ADMIN_SECRETS: &str = "./ADMIN_SECRETS";
const USER_SECRETS: &str = "./USER_SECRETS";
const ADMIN_PUB: &str = "./ADMIN_PUB";
const USER_PUB: &str = "./USER_PUB";
const DEVICE_KEY: &str = "./DEVICE_KEY";
const MAX_EXPORT_FILE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(serde::Serialize, serde::Deserialize)]
struct DeviceKeyFile {
    private_key_b64: String,
    pubkey_b64: String,
}

fn read_pin() -> Result<String> {
    // Неинтерактивно через env (как init_vault_for_cli) — нужно MCP-серверу и
    // скриптам (нет tty). Иначе спрашиваем у пользователя.
    if let Ok(pin) = std::env::var("PARANOIA_CLI_PIN") {
        return Ok(pin);
    }
    eprint!("Enter PIN: ");
    let pin = read_password().context("failed to read PIN")?;
    Ok(pin)
}

fn key_from_pin(pin: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(pin.as_bytes());
    let digest = hasher.finalize();
    let mut key = [0u8; 32];
    key.copy_from_slice(&digest[..32]);
    key
}

/// Шифруем произвольный payload с помощью paranoia-lib::crypto::encrypt (ChaCha20-Poly1305).
fn encrypt_blob(pin: &str, plaintext: &[u8]) -> Result<Vec<u8>> {
    let key = key_from_pin(pin);
    crypto::encrypt(&key, plaintext)
}

/// Расшифровываем blob из *_SECRETS.
fn decrypt_blob(pin: &str, data: &[u8]) -> Result<Vec<u8>> {
    let key = key_from_pin(pin);
    crypto::decrypt(&key, data)
}

fn read_encrypted_secret_b64(path: &str, label: &str) -> Result<String> {
    let pin = read_pin()?;
    let data = fs::read(path).with_context(|| format!("failed to read {label}"))?;
    let plaintext =
        decrypt_blob(&pin, &data).with_context(|| format!("wrong PIN or corrupted {label}"))?;
    Ok(String::from_utf8(plaintext)?.trim().to_string())
}

fn encrypt_profile_secret_b64(secret_b64: &str) -> Result<String> {
    let pin = read_pin()?;
    let ciphertext = encrypt_blob(&pin, secret_b64.trim().as_bytes())?;
    Ok(B64.encode(ciphertext))
}

fn decrypt_profile_secret_b64(ciphertext_b64: &str) -> Result<String> {
    let pin = read_pin()?;
    let ciphertext = B64
        .decode(ciphertext_b64.trim())
        .context("invalid profile signing key ciphertext")?;
    let plaintext =
        decrypt_blob(&pin, &ciphertext).context("wrong PIN or corrupted profile signing key")?;
    Ok(String::from_utf8(plaintext)?.trim().to_string())
}

fn validate_b64_32(value: &str, label: &str) -> Result<[u8; 32]> {
    let bytes = B64
        .decode(value.trim())
        .with_context(|| format!("invalid base64 for {label}"))?;
    bytes
        .try_into()
        .map_err(|b: Vec<u8>| anyhow!("{label} must be 32 bytes, got {}", b.len()))
}

/// server_id = hex(SHA256("paranoia:server-id:v1\n" || ed25519_pubkey)).
/// Идентично `ParanoiaLibrary::ffi::paranoia_derive_server_id`. Это идентичность,
/// под которой профиль зарегистрирован на сервере, и то, что уходит как `sender`/
/// ключ диалога — поэтому `--username` ОБЯЗАН быть именно server_id, а не
/// отображаемым именем (иначе сервер ответит "One user in pair not registered").
fn derive_server_id_from_signing(signing: &SigningKey) -> String {
    let pubkey = signing.verifying_key().to_bytes();
    let mut hasher = Sha256::new();
    hasher.update(b"paranoia:server-id:v1\n");
    hasher.update(pubkey);
    hex::encode(hasher.finalize())
}

/// Тот же вывод из signing key в base64(32).
fn derive_server_id_b64(signing_key_b64: &str) -> Result<String> {
    let bytes = validate_b64_32(signing_key_b64, "signing key")?;
    Ok(derive_server_id_from_signing(&SigningKey::from_bytes(&bytes)))
}

fn write_owner_only(path: impl AsRef<Path>, data: impl AsRef<[u8]>) -> Result<()> {
    let path = path.as_ref();
    fs::write(path, data).with_context(|| format!("failed to write {}", path.display()))?;
    set_owner_only_permissions(path)?;
    Ok(())
}

#[cfg(unix)]
fn set_owner_only_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to set owner-only permissions on {}", path.display()))
}

#[cfg(not(unix))]
fn set_owner_only_permissions(_path: &Path) -> Result<()> {
    Ok(())
}

fn load_or_create_device_key() -> Result<DeviceKeyFile> {
    let path = Path::new(DEVICE_KEY);
    if path.exists() {
        let data = fs::read(path).context("failed to read DEVICE_KEY")?;
        let key_file: DeviceKeyFile =
            serde_json::from_slice(&data).context("failed to parse DEVICE_KEY")?;
        let priv_bytes = validate_b64_32(&key_file.private_key_b64, "device private key")?;
        let expected_pub = B64.encode(pubkey_from_private_key(&priv_bytes));
        if key_file.pubkey_b64.trim() != expected_pub {
            return Err(anyhow!("DEVICE_KEY public key does not match private key"));
        }
        return Ok(key_file);
    }

    let (priv_bytes, pub_bytes) = generate_device_keypair();
    let key_file = DeviceKeyFile {
        private_key_b64: B64.encode(priv_bytes),
        pubkey_b64: B64.encode(pub_bytes),
    };
    let data = serde_json::to_vec_pretty(&key_file).context("failed to serialize DEVICE_KEY")?;
    write_owner_only(path, data)?;
    Ok(key_file)
}

fn save_admin_secret(secret_b64: &str) -> Result<()> {
    let pair = AdminKeyPair::from_secret_b64(secret_b64).context("invalid admin private key")?;
    let pin = read_pin()?;
    let ciphertext = encrypt_blob(&pin, secret_b64.trim().as_bytes())?;
    write_owner_only(ADMIN_SECRETS, ciphertext)?;
    fs::write(ADMIN_PUB, pair.pubkey_b64()).context("failed to write ADMIN_PUB")?;
    Ok(())
}

/// ADMIN INIT: сгенерировать админскую пару, зашифровать секрет, записать pub.
fn admin_init() -> Result<()> {
    let pair = AdminKeyPair::generate(); // генерирует секрет 32 байта и pub.
    let sk_b64 = pair.secret_b64(); // base64(32 байта).
    let pk_b64 = pair.pubkey_b64(); // base64(32 байта).

    let pin = read_pin()?;
    let ciphertext = encrypt_blob(&pin, sk_b64.as_bytes())?;
    write_owner_only(ADMIN_SECRETS, ciphertext)?;
    fs::write(ADMIN_PUB, pk_b64).context("failed to write ADMIN_PUB")?;

    println!("Admin keys generated.");
    println!("Admin pubkey saved to ADMIN_PUB, put it into server config (admin_key).");
    Ok(())
}

fn load_admin_keypair() -> Result<AdminKeyPair> {
    let sk_b64 = read_encrypted_secret_b64(ADMIN_SECRETS, "ADMIN_SECRETS")?;
    AdminKeyPair::from_secret_b64(&sk_b64)
}

/// ADMIN REG-USER: подписать pub клиента и вызвать /reg через Transport.
async fn admin_reg_user(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
) -> Result<()> {
    let admin = load_admin_keypair()?;
    let user_pub_b64 = fs::read_to_string(USER_PUB)
        .context("failed to read USER_PUB")?
        .trim()
        .to_string();

    let admin_sig_b64 = admin.sign_user_registration(username, &user_pub_b64);

    let cover =
        std::sync::Arc::new(paranoia_lib::client_cover_food::FoodDeliveryClientCover::new());
    let transport = paranoia_lib::transport::Transport::new(
        server_url,
        reserve_server_urls.iter().map(String::as_str),
        cover,
    );
    transport
        .reg(username, &user_pub_b64, &admin_sig_b64)
        .await?;
    println!("User '{}' registered.", username);
    Ok(())
}

/// USER INIT: сгенерировать пару, зашифровать секрет, записать USER_PUB.
fn user_init() -> Result<()> {
    // генерируем 32‑байтовый секрет, как у AdminKeyPair.
    let mut secret_bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut secret_bytes);
    let sk = SigningKey::from(secret_bytes);
    let pk = sk.verifying_key();

    let sk_b64 = B64.encode(secret_bytes);
    let pk_b64 = B64.encode(pk.to_bytes());

    let pin = read_pin()?;
    let ciphertext = encrypt_blob(&pin, sk_b64.as_bytes())?;
    write_owner_only(USER_SECRETS, ciphertext)?;
    fs::write(USER_PUB, pk_b64).context("failed to write USER_PUB")?;

    println!("User keys generated.");
    println!("Send USER_PUB to admin to get registered.");
    Ok(())
}

fn load_user_signing_key() -> Result<SigningKey> {
    let sk_b64 = read_encrypted_secret_b64(USER_SECRETS, "USER_SECRETS")?;
    let secret_bytes = validate_b64_32(&sk_b64, "user secret")?;
    Ok(SigningKey::from_bytes(&secret_bytes))
}

fn load_profile_signing_key(server_url: &str, username: &str) -> Result<Option<SigningKey>> {
    let store = load_dialogue_store()?;
    let id = profile_id(server_url, username);
    let Some(profile) = store.profiles.get(&id) else {
        return Ok(None);
    };
    let Some(secret_b64) = profile_signing_key_b64(profile)? else {
        return Ok(None);
    };
    let secret_bytes = validate_b64_32(&secret_b64, "profile user secret")?;
    Ok(Some(SigningKey::from_bytes(&secret_bytes)))
}

fn profile_signing_key_b64(profile: &ProfileDialogueStore) -> Result<Option<String>> {
    if !profile.signing_key_ct_b64.trim().is_empty() {
        return Ok(Some(decrypt_profile_secret_b64(
            &profile.signing_key_ct_b64,
        )?));
    }
    if !profile.signing_key_b64.trim().is_empty() {
        return Ok(Some(profile.signing_key_b64.trim().to_string()));
    }
    Ok(None)
}

fn build_client(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
) -> Result<ParanoiaClient> {
    let signing_key = match load_profile_signing_key(server_url, username)? {
        Some(signing_key) => signing_key,
        None => load_user_signing_key()?,
    };
    let cfg = ClientConfig {
        server_url: server_url.to_string(),
        reserve_server_urls: reserve_server_urls.to_vec(),
        username: username.to_string(),
        signing_key,
        db_path: db_path.to_string(),
    };
    ParanoiaClient::new(cfg) // создаёт Transport + LocalStore.
}

fn build_dialogue(
    client: &ParanoiaClient,
    server_url: &str,
    username: &str,
    peer: &str,
) -> Result<Dialogue> {
    let store = load_dialogue_store()?;
    // Разрешаем peer по имени → server_id (ключ диалога — server_id, НЕ имя; иначе
    // DialogueKey даст другой dialogue_id). Если peer уже server_id — без изменений.
    let peer_owned = resolve_peer_id(&store, server_url, username, peer);
    let peer = peer_owned.as_str();
    let dkey = DialogueKey::new(username, peer);
    let dcfg = if let Some(entries) = profile_keyring_entries(&store, server_url, username, peer) {
        let keyring = entries
            .iter()
            .map(|entry| {
                Ok(DialogueKeyEntry {
                    start_seq: entry.start_seq,
                    key: base64_entry_to_key(entry)?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        DialogueConfig::with_keyring(dkey, keyring)?
    } else {
        let key_hex = store.entries.get(peer).context(
            "no session_key for this peer, use 'dialogue init', 'dialogue set-key' or import profile first",
        )?;
        let entry = key_entry_from_hex(1, key_hex)?;
        DialogueConfig::single_key(dkey, base64_entry_to_key(&entry)?)
    };
    Ok(client.open_dialogue(dcfg))
}

/// SEND (text)
async fn cmd_send(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    text: &str,
    topic: Option<String>,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?.with_topic(topic);
    let msg = dialogue.send_text(text).await?;
    println!(
        "Sent: id={} seq={:?}{}",
        msg.id,
        msg.server_seq,
        msg.topic_name
            .as_deref()
            .map(|t| format!(" topic={t}"))
            .unwrap_or_default()
    );
    Ok(())
}

/// REACT (эмодзи-реакция на сообщение по message_id)
async fn cmd_react(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    message_id: &str,
    emoji: &str,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let msg = dialogue.send_reaction(message_id, emoji).await?;
    println!("Reacted: id={} seq={:?}", msg.id, msg.server_seq);
    Ok(())
}

/// TOPIC LIST — темы диалога (имя, число сообщений). Перед выводом тянем новые
/// сообщения, чтобы свежесозданные собеседником темы появились.
async fn cmd_topic_list(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let _ = dialogue.receive().await;
    let topics = dialogue.list_topics()?;
    if topics.is_empty() {
        println!("(тем нет — все сообщения в «Главной»)");
    } else {
        for (_, name, count) in topics {
            println!("{name}\t{count} сообщ.");
        }
    }
    Ok(())
}

/// TOPIC DELETE — удалить тему целиком (у обеих сторон).
async fn cmd_topic_delete(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    topic: &str,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let n = dialogue.delete_topic(topic).await?;
    println!("Удалена тема «{topic}»: {n} сообщ.");
    Ok(())
}

/// RECEIVE
async fn cmd_receive(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    long_poll_ms: u32,
    topic: Option<String>,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    // Long-poll: сервер держит /notify до появления нового сообщения или таймаута.
    // Best-effort — при ошибке (старый сервер/обрыв CDN) просто идём на обычный pull
    // (это и есть авто-деградация на короткий поллинг). Возврат игнорируем: о наличии
    // нового судит сам receive() ниже.
    if long_poll_ms > 0 {
        let _ = dialogue.notify_count_wait(long_poll_ms).await;
    }
    let (msgs, decrypt_errors) = dialogue.receive().await?;
    if decrypt_errors > 0 {
        eprintln!(
            "Warning: {decrypt_errors} message(s) could not be decrypted (wrong session key?)"
        );
    }
    let filter_id = topic
        .as_deref()
        .map(|t| derive_topic_id(&dialogue.key, t));
    print_messages(&msgs, filter_id.as_deref());
    Ok(())
}

/// Префикс темы для строки сообщения (`[#имя] `), пусто для «Главной».
fn topic_prefix(m: &Message) -> String {
    m.topic_name
        .as_deref()
        .map(|t| format!("[#{t}] "))
        .unwrap_or_default()
}

/// Напечатать сообщения в формате `[ts] {tprefix}id=<id> <sender>: <text>`.
/// `filter_topic_id` — если задан, показываем только сообщения этой темы.
fn print_messages(msgs: &[Message], filter_topic_id: Option<&str>) {
    for m in msgs {
        if let Some(want) = filter_topic_id {
            if m.topic_id.as_deref() != Some(want) {
                continue;
            }
        }
        let tp = topic_prefix(m);
        match &m.content {
            MessageContent::Text(t) => {
                println!("[{}] {tp}id={} {}: {}", m.timestamp, m.id, m.sender, t);
            }
            other => {
                println!("[{}] {tp}id={} {}: {:?}", m.timestamp, m.id, m.sender, other);
            }
        }
    }
}

fn guess_mime(path: &str) -> String {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "pdf" => "application/pdf",
        "txt" | "log" | "md" => "text/plain",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Непрерывный приём: цикл receive. long_poll_ms>0 → сервер держит запрос
/// (near-real-time); =0 → пауза interval сек между опросами.
async fn cmd_watch(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    interval: u64,
    long_poll_ms: u32,
    topic: Option<String>,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let filter_id = topic
        .as_deref()
        .map(|t| derive_topic_id(&dialogue.key, t));
    loop {
        if long_poll_ms > 0 {
            // best-effort: при ошибке (обрыв/CDN режет) идём на обычный pull.
            let _ = dialogue.notify_count_wait(long_poll_ms).await;
        }
        let (msgs, decrypt_errors) = dialogue.receive().await?;
        if decrypt_errors > 0 {
            eprintln!("Warning: {decrypt_errors} message(s) could not be decrypted");
        }
        print_messages(&msgs, filter_id.as_deref());
        if long_poll_ms == 0 {
            tokio::time::sleep(std::time::Duration::from_secs(interval.max(1))).await;
        }
    }
}

async fn cmd_send_file(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    path: &std::path::Path,
    topic: Option<String>,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?.with_topic(topic);
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("attachment.bin")
        .to_string();
    let mime = guess_mime(&filename);
    let msgs = dialogue
        .send_file_auto_with_progress(filename.clone(), mime, path, |_, _| {})
        .await?;
    let id = msgs
        .first()
        .map(|m| m.id.to_string())
        .unwrap_or_default();
    println!("Sent file: id={id} name={filename} parts={}", msgs.len());
    Ok(())
}

async fn cmd_download(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    message_id: &str,
    out: &std::path::Path,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let out_str = out.to_str().context("invalid out path")?;
    dialogue.download_attachment(message_id, out_str).await?;
    println!("Downloaded: id={message_id} -> {out_str}");
    Ok(())
}

/// CLEAR server history
async fn cmd_clear(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    cut_seq: u64,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    dialogue.clear_server_history(cut_seq).await?;
    println!("Server history cleared up to seq={}", cut_seq);
    Ok(())
}

/// Достать master key (последняя запись keyring'а) для диалога — тот же ключ,
/// которым клиент шифрует сигнальные конверты звонка (VoipSystem: keyring.last()).
fn dialog_master_key(server_url: &str, username: &str, peer_id: &str) -> Result<[u8; 32]> {
    let store = load_dialogue_store()?;
    if let Some(entries) = profile_keyring_entries(&store, server_url, username, peer_id) {
        let last = entries.last().context("keyring for peer is empty")?;
        return base64_entry_to_key(last);
    }
    let key_hex = store
        .entries
        .get(peer_id)
        .context("no session_key for this peer (import profile first)")?;
    let entry = key_entry_from_hex(1, key_hex)?;
    base64_entry_to_key(&entry)
}

/// CALL-OFFER: послать тестовый Offer-конверт звонка (kind=0) peer'у. Нужен для
/// автономной отладки приёма входящих звонков в фоне (Android/iOS) без второго
/// живого клиента: шлём валидный подписанный+зашифрованный оффер на сервер,
/// клиент-получатель ловит его поллингом call_poll и поднимает баннер вызова.
/// Медиа НЕ поднимается (мы не отвечаем на answer) — проверяется именно ДОСТАВКА
/// и показ входящего. Мирроринг paranoia_call_signal_send (voip_ffi.rs).
async fn cmd_call_offer(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let store = load_dialogue_store()?;
    let peer_id = resolve_peer_id(&store, server_url, username, peer);
    let key = dialog_master_key(server_url, username, &peer_id)?;

    // call_id и session_id — случайные (как у настоящего клиента).
    let mut rng = rand::rngs::OsRng;
    let mut cid = [0u8; 16];
    rng.fill_bytes(&mut cid);
    let mut sid = [0u8; 32];
    rng.fill_bytes(&mut sid);
    let call_id = hex_lower(&cid);
    let session_id_b64 = B64.encode(sid);

    // Тело Offer — те же поля, что шлёт CallController::startOutgoingCall.
    let payload = serde_json::json!({
        "call_id": call_id,
        "session_id": session_id_b64,
        "candidates": ["192.168.0.50:40000"],
        "streams": [0],
    })
    .to_string();

    let sealed = paranoia_lib::voip::signaling::seal(&key, payload.as_bytes())
        .map_err(|e| anyhow!("signaling seal failed: {e}"))?;
    let payload_b64 = B64.encode(&sealed);
    let ts_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    // Подпись как на сервере: sender+recver+kind+ts_ms+payload_b64 (kind=0).
    let signed = format!("{username}{peer_id}0{ts_ms}{payload_b64}");
    let sig = crypto::sign(&client.config().signing_key, signed.as_bytes());
    let core = CoreCallSignal {
        sender: username.to_string(),
        recver: peer_id.clone(),
        kind: 0,
        payload: sealed,
        ts_ms,
        sig,
    };
    client
        .transport()
        .call_signal(&core)
        .await
        .map_err(|e| anyhow!("call_signal failed: {e}"))?;
    println!("Offer sent: call_id={call_id} to={peer_id}");
    Ok(())
}

/// CALL-HANGUP: послать Hangup-конверт (kind=2) по call_id — для отладки
/// распространения сброса и «протухших» офферов (отменённый звонок).
async fn cmd_call_hangup(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
    call_id: &str,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let store = load_dialogue_store()?;
    let peer_id = resolve_peer_id(&store, server_url, username, peer);
    let key = dialog_master_key(server_url, username, &peer_id)?;

    let payload = serde_json::json!({
        "call_id": call_id,
        "reason": "user_hangup",
    })
    .to_string();
    let sealed = paranoia_lib::voip::signaling::seal(&key, payload.as_bytes())
        .map_err(|e| anyhow!("signaling seal failed: {e}"))?;
    let payload_b64 = B64.encode(&sealed);
    let ts_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let signed = format!("{username}{peer_id}2{ts_ms}{payload_b64}");
    let sig = crypto::sign(&client.config().signing_key, signed.as_bytes());
    let core = CoreCallSignal {
        sender: username.to_string(),
        recver: peer_id.clone(),
        kind: 2,
        payload: sealed,
        ts_ms,
        sig,
    };
    client
        .transport()
        .call_signal(&core)
        .await
        .map_err(|e| anyhow!("call_signal failed: {e}"))?;
    println!("Hangup sent: call_id={call_id} to={peer_id}");
    Ok(())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// DIALOGUE INIT: сохранить session_key, как hex.
fn cmd_dialogue_init(peer: &str, session_key_hex: &str) -> Result<()> {
    set_dialogue_key(peer, session_key_hex)?;
    println!("Dialogue key saved for peer '{}'.", peer);
    Ok(())
}

/// DIALOGUE SET-KEY: запросить ключ с клавиатуры.
fn cmd_dialogue_set_key(peer: &str) -> Result<()> {
    eprint!("Enter session key (hex, 32 bytes): ");
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    set_dialogue_key(peer, line.trim())?;
    println!("Dialogue key updated for peer '{}'.", peer);
    Ok(())
}

fn cmd_device_key_show() -> Result<()> {
    let key = load_or_create_device_key()?;
    println!("{}", key.pubkey_b64);
    Ok(())
}

fn export_profile_type(profile: CliExportProfile) -> ExportProfileType {
    match profile {
        CliExportProfile::Client => ExportProfileType::Client,
        CliExportProfile::Admin => ExportProfileType::Admin,
        CliExportProfile::Full => ExportProfileType::Full,
    }
}

fn export_includes_client(profile: CliExportProfile) -> bool {
    matches!(profile, CliExportProfile::Client | CliExportProfile::Full)
}

fn export_includes_admin(profile: CliExportProfile) -> bool {
    matches!(profile, CliExportProfile::Admin | CliExportProfile::Full)
}

fn selected_peer(peer: &str, peers: &[String]) -> bool {
    peers.is_empty() || peers.iter().any(|candidate| candidate == peer)
}

fn export_dialogues(
    server_url: &str,
    username: &str,
    peers: &[String],
) -> Result<Vec<ExportDialogue>> {
    let store = load_dialogue_store()?;
    let id = profile_id(server_url, username);
    let mut dialogues = Vec::new();

    if let Some(profile) = store.profiles.get(&id) {
        for (peer_sid, entries) in &profile.dialogues {
            // Ключ диалога — server_id; отображаемое имя берём из names.
            let display = profile.names.get(peer_sid);
            // Выбор по --peer допускаем и по server_id, и по имени.
            let selected = peers.is_empty()
                || peers.iter().any(|p| p == peer_sid || Some(p) == display);
            if !selected {
                continue;
            }
            let mut keyring = Vec::new();
            for entry in entries {
                let normalized = key_entry_from_base64(entry.start_seq, &entry.key)?;
                keyring.push(ExportKeyEntry {
                    start_seq: normalized.start_seq,
                    key: normalized.key,
                });
            }
            if !keyring.is_empty() {
                keyring.sort_by_key(|entry| entry.start_seq);
                dialogues.push(ExportDialogue {
                    // peer = отображаемое имя (или server_id, если имени нет),
                    // peer_server_id = server_id — чтобы импорт не терял идентичность.
                    peer: display.cloned().unwrap_or_else(|| peer_sid.clone()),
                    peer_server_id: Some(peer_sid.clone()),
                    keyring,
                });
            }
        }
    } else {
        for (peer, key_hex) in &store.entries {
            if !selected_peer(peer, peers) {
                continue;
            }
            let entry = key_entry_from_hex(1, key_hex)?;
            dialogues.push(ExportDialogue {
                peer: peer.clone(),
                peer_server_id: None,
                keyring: vec![ExportKeyEntry {
                    start_seq: entry.start_seq,
                    key: entry.key,
                }],
            });
        }
    }

    dialogues.sort_by(|lhs, rhs| lhs.peer.cmp(&rhs.peer));
    Ok(dialogues)
}

fn cmd_export(
    server_url: &str,
    profile: CliExportProfile,
    username: Option<String>,
    peers: Vec<String>,
    receiver_pubkey_b64: String,
    out: PathBuf,
) -> Result<()> {
    let receiver_pub = validate_b64_32(&receiver_pubkey_b64, "receiver device public key")?;
    let mut payload = ExportPayload {
        format_version: EXPORT_PAYLOAD_VERSION,
        profile_type: export_profile_type(profile),
        servers: Vec::new(),
        admin_servers: Vec::new(),
    };

    if export_includes_client(profile) {
        let username = username.context("--username is required for client/full export")?;
        let signing_key_b64 = match load_profile_signing_key(server_url, &username)? {
            Some(signing_key) => B64.encode(signing_key.to_bytes()),
            None => read_encrypted_secret_b64(USER_SECRETS, "USER_SECRETS")?,
        };
        validate_b64_32(&signing_key_b64, "user signing key")?;
        let dialogues = export_dialogues(server_url, &username, &peers)?;
        if !peers.is_empty() && dialogues.len() != peers.len() {
            return Err(anyhow!("some selected peers have no stored keyring"));
        }
        payload.servers.push(ExportServer {
            url: server_url.to_string(),
            username,
            signing_key_b64,
            dialogues,
        });
    }

    if export_includes_admin(profile) {
        let admin_private_key_b64 = read_encrypted_secret_b64(ADMIN_SECRETS, "ADMIN_SECRETS")?;
        AdminKeyPair::from_secret_b64(&admin_private_key_b64)
            .context("invalid admin private key")?;
        payload.admin_servers.push(ExportAdminServer {
            url: server_url.to_string(),
            admin_private_key_b64,
        });
    }

    let stats = validate_export_payload(&payload)?;
    let plaintext = serde_json::to_vec(&payload).context("failed to serialize export payload")?;
    let envelope = ecies_encrypt(&receiver_pub, &plaintext)?;
    write_owner_only(&out, envelope.as_bytes())?;
    println!(
        "Export saved to {} (servers={}, admin_servers={}, dialogues={}, key_entries={}).",
        out.display(),
        stats.servers,
        stats.admin_servers,
        stats.dialogues,
        stats.key_entries
    );
    Ok(())
}

#[derive(Default)]
struct ImportStats {
    profiles: usize,
    dialogues: usize,
    key_entries: usize,
    admin_servers: usize,
    skipped: usize,
    conflicts: usize,
}

fn profile_for_import<'a>(
    store: &'a mut dialogue_store::DialogueKeyStore,
    server: &ExportServer,
    server_id: &str,
) -> (&'a mut ProfileDialogueStore, bool) {
    // Ключуем профиль по server_id (идентичность для сервера), НЕ по
    // отображаемому `server.username`: иначе profile_id не сойдётся с тем, что
    // CLI шлёт серверу, и --username придётся угадывать.
    let id = profile_id(&server.url, server_id);
    let existed = store.profiles.contains_key(&id);
    let profile = store
        .profiles
        .entry(id)
        .or_insert_with(|| ProfileDialogueStore {
            server_url: server.url.clone(),
            username: server_id.to_string(),
            signing_key_b64: String::new(),
            signing_key_ct_b64: String::new(),
            dialogues: Default::default(),
            names: Default::default(),
            local_name: String::new(),
        });
    (profile, !existed)
}

fn import_server_profile(
    store: &mut dialogue_store::DialogueKeyStore,
    server: &ExportServer,
    stats: &mut ImportStats,
) -> Result<()> {
    validate_b64_32(&server.signing_key_b64, "imported user signing key")?;
    // server_id владельца — детерминированно из signing key (в payload его нет).
    let owner_server_id = derive_server_id_b64(&server.signing_key_b64)?;
    let (profile, created) = profile_for_import(store, server, &owner_server_id);
    if created {
        stats.profiles += 1;
    }

    match profile_signing_key_b64(profile)? {
        Some(existing_key) if existing_key.trim() != server.signing_key_b64.trim() => {
            stats.conflicts += 1;
            return Ok(());
        }
        Some(_) => {}
        None => {
            profile.signing_key_ct_b64 = encrypt_profile_secret_b64(&server.signing_key_b64)?;
            profile.signing_key_b64.clear();
        }
    }

    for dialogue in &server.dialogues {
        // Ключ диалога — server_id пира (для dialogue_id и recver). Если в payload
        // он есть (peer_server_id) — берём его, а `peer` трактуем как
        // отображаемое имя и кладём в names. Старые экспорты без peer_server_id —
        // fallback на `peer` как есть (back-compat; server_id восстановить нечем).
        let peer_sid = dialogue
            .peer_server_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(dialogue.peer.trim());
        let peer_sid = peer_sid.to_string();
        if peer_sid.is_empty() {
            continue;
        }
        if peer_sid != dialogue.peer.trim() && !dialogue.peer.trim().is_empty() {
            profile
                .names
                .entry(peer_sid.clone())
                .or_insert_with(|| dialogue.peer.trim().to_string());
        }

        let mut touched_dialogue = false;
        for entry in &dialogue.keyring {
            let entry = key_entry_from_base64(entry.start_seq, &entry.key)?;
            match merge_profile_keyring_entry(profile, &peer_sid, entry) {
                MergeOutcome::Imported => {
                    stats.key_entries += 1;
                    touched_dialogue = true;
                }
                MergeOutcome::Skipped => stats.skipped += 1,
                MergeOutcome::Conflict => stats.conflicts += 1,
            }
        }
        if touched_dialogue {
            stats.dialogues += 1;
        }
    }

    Ok(())
}

fn maybe_import_current_admin(
    server_url: &str,
    payload: &ExportPayload,
    stats: &mut ImportStats,
) -> Result<()> {
    let Some(admin) = payload
        .admin_servers
        .iter()
        .find(|admin| admin.url == server_url)
    else {
        if !payload.admin_servers.is_empty() {
            stats.skipped += payload.admin_servers.len();
        }
        return Ok(());
    };

    save_admin_secret(&admin.admin_private_key_b64)?;
    stats.admin_servers += 1;
    if payload.admin_servers.len() > 1 {
        stats.skipped += payload.admin_servers.len() - 1;
    }
    Ok(())
}

/// Ядро import: расшифровать export-файл и материализовать профиль(и) в сторе.
/// Возвращает сводку JSON (без печати) — общее для `import` и мастера `mcp install`.
fn import_core(server_url: &str, file: &Path) -> Result<serde_json::Value> {
    let metadata =
        fs::metadata(file).with_context(|| format!("failed to stat {}", file.display()))?;
    if metadata.len() > MAX_EXPORT_FILE_BYTES {
        return Err(anyhow!("export file is larger than 16 MiB"));
    }
    let envelope =
        fs::read_to_string(file).with_context(|| format!("failed to read {}", file.display()))?;
    let device = load_or_create_device_key()?;
    let device_priv = validate_b64_32(&device.private_key_b64, "device private key")?;
    let plaintext =
        ecies_decrypt(&device_priv, &envelope).context("failed to decrypt export file")?;
    let payload: ExportPayload =
        serde_json::from_slice(&plaintext).context("invalid export payload JSON")?;
    validate_export_payload(&payload)?;

    let mut store = load_dialogue_store()?;
    let mut stats = ImportStats::default();
    for server in &payload.servers {
        import_server_profile(&mut store, server, &mut stats)?;
    }
    if !payload.servers.is_empty() {
        save_dialogue_store(&store)?;
    }
    maybe_import_current_admin(server_url, &payload, &mut stats)?;

    Ok(serde_json::json!({
        "profiles": stats.profiles,
        "dialogues": stats.dialogues,
        "key_entries": stats.key_entries,
        "admin_servers": stats.admin_servers,
        "skipped": stats.skipped,
        "conflicts": stats.conflicts,
    }))
}

fn cmd_import(server_url: &str, file: PathBuf) -> Result<()> {
    let s = import_core(server_url, &file)?;
    println!(
        "Import complete: profiles={}, dialogues={}, key_entries={}, admin_servers={}, skipped={}, conflicts={}",
        s["profiles"], s["dialogues"], s["key_entries"], s["admin_servers"], s["skipped"], s["conflicts"]
    );
    Ok(())
}

/// Публичный device-pubkey принимающего устройства (для обмена под export).
fn device_pubkey_b64() -> Result<String> {
    Ok(load_or_create_device_key()?.pubkey_b64)
}

/// PIN vault'а UI-клиента: явный аргумент → env PARANOIA_UI_PIN → запрос с tty.
/// Отдельно от PARANOIA_CLI_PIN (тот шифрует СВОЙ стор по схеме key_from_pin).
fn read_ui_pin(explicit: Option<String>) -> Result<String> {
    if let Some(p) = explicit {
        return Ok(p);
    }
    if let Ok(p) = std::env::var("PARANOIA_UI_PIN") {
        return Ok(p);
    }
    eprint!("Enter UI vault PIN: ");
    read_password().context("failed to read UI PIN")
}

/// Структурный список профилей CLI-стора с авторитетным server_id (из signing
/// key) и собеседниками (names). Общее ядро для `server-id` и MCP-тулзы `whoami`.
fn collect_server_id_profiles() -> Result<Vec<serde_json::Value>> {
    let store = load_dialogue_store()?;
    let mut profiles = Vec::new();
    for (pid, profile) in &store.profiles {
        // Авторитетно деривируем из signing key; username стора — fallback.
        let server_id = match profile_signing_key_b64(profile)? {
            Some(sk) => derive_server_id_b64(&sk).unwrap_or_else(|_| profile.username.clone()),
            None => profile.username.clone(),
        };
        let display = profile
            .names
            .get(&server_id)
            .cloned()
            .unwrap_or_else(|| profile.username.clone());
        let peers: Vec<_> = profile
            .names
            .iter()
            .map(|(sid, name)| serde_json::json!({ "server_id": sid, "name": name }))
            .collect();
        profiles.push(serde_json::json!({
            "profile_id": pid,
            "server_url": profile.server_url,
            "display_name": display,
            "server_id": server_id,
            "peers": peers,
        }));
    }
    Ok(profiles)
}

/// SERVER-ID: показать server_id (идентичность для сервера = `--username`).
/// Без аргумента — перечислить профили CLI-стора; с `--signing-key-b64` —
/// вычислить из произвольного ключа, не трогая стор.
fn cmd_server_id(signing_key_b64: Option<String>, json: bool) -> Result<()> {
    if let Some(sk) = signing_key_b64 {
        let sid = derive_server_id_b64(&sk)?;
        if json {
            println!("{}", serde_json::json!({ "server_id": sid }));
        } else {
            println!("{sid}");
        }
        return Ok(());
    }

    let profiles = collect_server_id_profiles()?;

    if json {
        println!("{}", serde_json::json!({ "profiles": profiles }));
    } else if profiles.is_empty() {
        println!("(в CLI-сторе нет профилей — используй `sync-from-ui` или `import`)");
    } else {
        for p in &profiles {
            println!(
                "server_id={} (display={}) server_url={}",
                p["server_id"].as_str().unwrap_or(""),
                p["display_name"].as_str().unwrap_or(""),
                p["server_url"].as_str().unwrap_or(""),
            );
            if let Some(arr) = p["peers"].as_array() {
                for peer in arr {
                    println!(
                        "    peer name={} server_id={}",
                        peer["name"].as_str().unwrap_or(""),
                        peer["server_id"].as_str().unwrap_or(""),
                    );
                }
            }
        }
    }
    Ok(())
}

/// Вернуть активный vault обратно на CLI-стор. `read_ui_profiles` переключает
/// глобальный singleton на UI-vault; без восстановления последующие операции в
/// том же процессе (например, в MCP) открыли бы CLI paranoia.db чужим db_key.
fn restore_cli_vault() -> Result<()> {
    paranoia_lib::local_vault::lock();
    init_vault_for_cli()
}

/// Ядро sync-from-ui: прочитать профиль(и) из UI-vault и материализовать в
/// CLI-сторе (dialogues по server_id, names заполнен, signing key перешифрован
/// под PIN CLI-стора). ВСЕГДА восстанавливает CLI-vault (успех/ошибка). Возвращает
/// сводку JSON. Общее ядро подкоманды `sync-from-ui` и MCP-тулзы provision_from_ui.
fn sync_from_ui_core(
    default_server_url: &str,
    app_data_root: &Path,
    ui_pin: &str,
    selector: Option<&str>,
) -> Result<serde_json::Value> {
    let out = sync_from_ui_inner(default_server_url, app_data_root, ui_pin, selector);
    let _ = restore_cli_vault(); // вернуть CLI-vault в любом случае
    out
}

fn sync_from_ui_inner(
    default_server_url: &str,
    app_data_root: &Path,
    ui_pin: &str,
    selector: Option<&str>,
) -> Result<serde_json::Value> {
    let profiles = ui_store::read_ui_profiles(app_data_root, ui_pin, selector)?;

    let mut store = load_dialogue_store()?;
    let mut n_profiles = 0usize;
    let mut n_dialogues = 0usize;
    let mut n_keys = 0usize;
    let mut details = Vec::new();

    for up in &profiles {
        let server_url = if up.server.trim().is_empty() {
            default_server_url.to_string()
        } else {
            up.server.trim().to_string()
        };
        validate_b64_32(&up.private_key, "UI signing key")?;
        // server_id авторитетно из signing key; client.json как fallback.
        let server_id = derive_server_id_b64(&up.private_key)
            .unwrap_or_else(|_| up.server_id.trim().to_string());
        if server_id.is_empty() {
            bail!("не удалось определить server_id для профиля '{}'", up.username);
        }

        let pid = profile_id(&server_url, &server_id);
        let existed = store.profiles.contains_key(&pid);
        // Перешифровать signing key под PIN CLI-стора (схема key_from_pin), пока
        // не взяли &mut на профиль (read_pin читает PARANOIA_CLI_PIN). Не зависит
        // от активного vault — поэтому ок даже при переключённом на UI vault.
        let signing_ct = encrypt_profile_secret_b64(&up.private_key)?;

        let profile = store
            .profiles
            .entry(pid)
            .or_insert_with(ProfileDialogueStore::default);
        profile.server_url = server_url.clone();
        profile.username = server_id.clone();
        profile.signing_key_b64 = String::new();
        profile.signing_key_ct_b64 = signing_ct;
        if !existed {
            n_profiles += 1;
        }
        // Своё имя — под собственный server_id (self-чат «Избранное» резолвится).
        if !up.username.trim().is_empty() {
            profile
                .names
                .entry(server_id.clone())
                .or_insert_with(|| up.username.trim().to_string());
        }

        for d in &up.dialogues {
            let peer_sid = if d.peer_server_id.trim().is_empty() {
                d.peer.trim().to_string()
            } else {
                d.peer_server_id.trim().to_string()
            };
            if peer_sid.is_empty() {
                continue;
            }
            let display = if !d.local_name.trim().is_empty() {
                d.local_name.trim()
            } else {
                d.peer.trim()
            };
            if !display.is_empty() && display != peer_sid {
                profile.names.insert(peer_sid.clone(), display.to_string());
            }

            let mut touched = false;
            for (start_seq, key_b64) in &d.keyring {
                let entry = key_entry_from_base64(*start_seq, key_b64.as_str())?;
                match merge_profile_keyring_entry(profile, &peer_sid, entry) {
                    MergeOutcome::Imported => {
                        n_keys += 1;
                        touched = true;
                    }
                    MergeOutcome::Skipped | MergeOutcome::Conflict => {}
                }
            }
            if touched {
                n_dialogues += 1;
            }
        }

        details.push(serde_json::json!({
            "username": up.username,
            "server_id": server_id,
            "dialogues": up.dialogues.len(),
        }));
    }

    save_dialogue_store(&store)?;
    Ok(serde_json::json!({
        "profiles": n_profiles,
        "dialogues": n_dialogues,
        "key_entries": n_keys,
        "details": details,
    }))
}

/// SYNC-FROM-UI: подтянуть профиль(и) НАПРЯМУЮ из стора UI-клиента, без
/// export/import. После этого send/receive работают с тем же диалогом, что и UI
/// (общий — серверный — стейт диалога).
fn cmd_sync_from_ui(
    default_server_url: &str,
    app_data_root: PathBuf,
    pin: Option<String>,
    selector: Option<String>,
) -> Result<()> {
    let ui_pin = read_ui_pin(pin)?;
    let res = sync_from_ui_core(default_server_url, &app_data_root, &ui_pin, selector.as_deref())?;
    println!(
        "Synced from UI store: profiles={} dialogues={} key_entries={}",
        res["profiles"], res["dialogues"], res["key_entries"]
    );
    if let Some(details) = res["details"].as_array() {
        for item in details {
            println!(
                "  username={} server_id={} dialogues={}",
                item["username"].as_str().unwrap_or(""),
                item["server_id"].as_str().unwrap_or(""),
                item["dialogues"]
            );
        }
    }
    println!("→ используй server_id выше как --username (он же выводится `server-id`).");
    Ok(())
}

/// MCP: собрать конфиг из CLI-флагов + env PARANOIA_MCP_*/PARANOIA_UI_* и
/// запустить сервер. server_url/db_path/reserve берём из общих флагов CLI.
async fn cmd_mcp(
    server_url: &str,
    reserve_server_urls: &[String],
    db_path: &str,
    username: Option<String>,
    peer: Option<String>,
    log: Option<PathBuf>,
) -> Result<()> {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    let username = username
        .or_else(|| env("PARANOIA_MCP_USERNAME"))
        .or_else(|| env("PARANOIA_MCP_SELF_HASH"))
        .unwrap_or_default();
    let self_hash = env("PARANOIA_MCP_SELF_HASH").unwrap_or_else(|| username.clone());
    let peer = peer.or_else(|| env("PARANOIA_MCP_PEER")).unwrap_or_default();
    let log_path = log
        .or_else(|| env("PARANOIA_MCP_LOG").map(PathBuf::from))
        .unwrap_or_else(|| {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join("messages.jsonl")
        });
    let ui_app_data_root = env("PARANOIA_UI_APP_DATA_ROOT");
    let ui_pin = env("PARANOIA_UI_PIN").or_else(|| env("PARANOIA_CLI_PIN"));
    let channel = env("PARANOIA_MCP_CHANNEL")
        .map(|v| matches!(v.as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false);
    // Скоуп темы: несколько channel-сессий на одном аккаунте, каждая в своей ветке.
    let channel_topic = env("PARANOIA_MCP_CHANNEL_TOPIC").filter(|s| !s.trim().is_empty());

    let cfg = mcp_server::McpConfig {
        server_url: server_url.to_string(),
        reserve_server_urls: reserve_server_urls.to_vec(),
        db_path: db_path.to_string(),
        username,
        peer,
        self_hash,
        log_path,
        ui_app_data_root,
        ui_pin,
        channel,
        channel_topic,
    };
    mcp_server::serve(cfg).await
}

#[derive(Parser)]
#[command(name = "ParanoiaEasyCli")]
struct Cli {
    #[arg(long, default_value = "https://paranoia.example.com/api")]
    server_url: String,

    #[arg(long = "reserve-server-url")]
    reserve_server_urls: Vec<String>,

    #[arg(long, default_value = "paranoia.db")]
    db_path: String,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Админские команды
    Admin {
        #[command(subcommand)]
        cmd: AdminCmd,
    },
    /// Пользовательские команды
    User {
        #[command(subcommand)]
        cmd: UserCmd,
    },
    /// Управление ключами диалогов
    Dialogue {
        #[command(subcommand)]
        cmd: DialogueCmd,
    },
    /// Управление device key для шифрованного export/import
    DeviceKey {
        #[command(subcommand)]
        cmd: DeviceKeyCmd,
    },
    /// Создать зашифрованный export-файл профиля
    Export {
        #[arg(long, value_enum)]
        profile: CliExportProfile,
        #[arg(long)]
        username: Option<String>,
        #[arg(long = "peer")]
        peers: Vec<String>,
        #[arg(long)]
        receiver_pub: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Импортировать зашифрованный export-файл профиля
    Import {
        #[arg(long)]
        file: PathBuf,
    },
    /// Показать server_id профилей (= --username для сервера) или вычислить из ключа
    ServerId {
        /// Вычислить server_id из signing key (base64, 32 байта), не читая стор
        #[arg(long = "signing-key-b64")]
        signing_key_b64: Option<String>,
        /// Машиночитаемый вывод (JSON) — для MCP/скриптов
        #[arg(long)]
        json: bool,
    },
    /// Подтянуть профиль НАПРЯМУЮ из стора UI-клиента (vault), без export/import
    SyncFromUi {
        /// Каталог AppData UI-клиента (где vault.json и profiles/)
        #[arg(long = "app-data-root")]
        app_data_root: PathBuf,
        /// PIN vault'а UI-клиента (или env PARANOIA_UI_PIN; иначе спросит с tty)
        #[arg(long)]
        pin: Option<String>,
        /// Выбрать один профиль по username/server_id/имени каталога (по умолч. — все)
        #[arg(long)]
        profile: Option<String>,
    },
    /// MCP: сервер (без под-команды) либо мастер установки (`mcp install`)
    Mcp {
        /// server_id профиля по умолчанию (иначе env PARANOIA_MCP_USERNAME)
        #[arg(long)]
        username: Option<String>,
        /// peer по умолчанию (иначе env PARANOIA_MCP_PEER)
        #[arg(long)]
        peer: Option<String>,
        /// durable-лог входящих (иначе env PARANOIA_MCP_LOG или <cwd>/messages.jsonl)
        #[arg(long)]
        log: Option<PathBuf>,
        #[command(subcommand)]
        cmd: Option<McpCmd>,
    },
    /// Интерактивный консольный мессенджер (TUI): список диалогов, лента,
    /// ввод, live-приём, реакции, вложения. Профиль — из --username/env.
    Tui {
        /// server_id профиля (иначе env PARANOIA_MCP_USERNAME/SELF_HASH или
        /// единственный профиль в сторе)
        #[arg(long)]
        username: Option<String>,
    },
    /// Задать локальный ник профиля (показывается в выборе профиля в TUI)
    ProfileName {
        #[arg(long)]
        username: String,
        #[arg(long)]
        name: String,
    },
    /// Отправка текстового сообщения
    Send {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        text: String,
        /// Тема (ветка диалога) по имени; пусто → «Главная». Тема создаётся
        /// неявно и появляется у собеседника автоматически.
        #[arg(long)]
        topic: Option<String>,
    },
    /// Темы (ветки) диалога: список / удаление
    Topic {
        #[command(subcommand)]
        cmd: TopicCmd,
    },
    /// Отправить эмодзи-реакцию на сообщение по message_id
    React {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        message_id: String,
        #[arg(long)]
        emoji: String,
    },
    /// Послать тестовый Offer-звонок peer'у (отладка приёма входящих в фоне)
    CallOffer {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
    },
    /// Послать Hangup (kind=2) по call_id (отладка сброса/протухших офферов)
    CallHangup {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long = "call-id")]
        call_id: String,
    },
    /// Получение новых сообщений
    Receive {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        /// Long-poll: подождать появления нового сообщения до N мс (сервер держит
        /// запрос), потом вытянуть. `0` (по умолч.) — мгновенно (короткий поллинг).
        /// Сервер капает величину своим notify_long_poll_max_ms.
        #[arg(long, default_value_t = 0)]
        long_poll_ms: u32,
        /// Показывать только сообщения этой темы (по имени). Пусто — все.
        #[arg(long)]
        topic: Option<String>,
    },
    /// Непрерывное получение: цикл receive. С --long-poll-ms сервер держит запрос
    /// (near-real-time); иначе пауза --interval между опросами (короткий поллинг).
    Watch {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        /// Пауза между опросами в режиме короткого поллинга, сек.
        #[arg(long, default_value_t = 20)]
        interval: u64,
        /// Удержание long-poll, мс (0 = короткий поллинг с паузой --interval).
        #[arg(long, default_value_t = 25000)]
        long_poll_ms: u32,
        /// Показывать только сообщения этой темы (по имени). Пусто — все.
        #[arg(long)]
        topic: Option<String>,
    },
    /// Отправить файл/картинку (канал авто-выбирается по размеру).
    SendFile {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        path: PathBuf,
        /// Тема (ветка диалога) по имени; пусто → «Главная».
        #[arg(long)]
        topic: Option<String>,
    },
    /// Скачать вложение полученного сообщения по message-id в файл.
    Download {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        message_id: String,
        #[arg(long)]
        out: PathBuf,
    },
    /// Очистка истории на сервере
    Clear {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        cut_seq: u64,
    },
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliExportProfile {
    Client,
    Admin,
    Full,
}

#[derive(Subcommand)]
enum DeviceKeyCmd {
    /// Показать публичный ключ принимающего устройства
    Show,
}

/// Источник профиля при установке.
#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum InstallSource {
    /// Подтянуть из действующего стора UI-клиента (vault) напрямую — нужен PIN UI
    Ui,
    /// Импортировать зашифрованный export-файл (нужен обмен device-key с хозяином)
    Import,
    /// Профиль уже подключён — только зарегистрировать в хостах
    None,
}

#[derive(Subcommand)]
enum McpCmd {
    /// Мастер установки: провижининг профиля + регистрация в MCP-хостах.
    /// Интерактивен для человека; с флагами/`--non-interactive` — для агента.
    Install {
        /// Рабочий каталог рантайма (стор/БД/ключи). По умолч. ~/.local/share/paranoia-mcp
        #[arg(long)]
        workdir: Option<PathBuf>,
        /// PIN CLI-стора. Иначе спросит (tty) или env PARANOIA_CLI_PIN
        #[arg(long)]
        pin: Option<String>,
        /// Источник профиля: ui | import | none
        #[arg(long, value_enum)]
        source: Option<InstallSource>,
        /// (ui) каталог AppData UI-клиента
        #[arg(long)]
        ui_app_data_root: Option<PathBuf>,
        /// (ui) PIN vault UI-клиента
        #[arg(long)]
        ui_pin: Option<String>,
        /// (import) путь к зашифрованному export-файлу
        #[arg(long)]
        export_file: Option<PathBuf>,
        /// server_id профиля (если в сторе их несколько)
        #[arg(long)]
        username: Option<String>,
        /// peer по умолчанию (имя/server_id)
        #[arg(long)]
        peer: Option<String>,
        /// Хосты через запятую: claude-code,claude-desktop,cursor,windsurf,cline,codex.
        /// Пусто — автоопределение установленных (или спросит).
        #[arg(long, value_delimiter = ',')]
        hosts: Vec<String>,
        /// Не задавать вопросов (агент/скрипт): недостающее обязательное → ошибка
        #[arg(long)]
        non_interactive: bool,
        /// Показать план без записи
        #[arg(long)]
        dry_run: bool,
        /// Машиночитаемый вывод (JSON) на stdout
        #[arg(long)]
        json: bool,
        /// Режим КАНАЛА (push): вместо регистрации pull-MCP создать channel-плагин
        /// (PARANOIA_MCP_CHANNEL=1), убрать pull-MCP и показать команду запуска.
        #[arg(long)]
        channel: bool,
    },
}

#[derive(Subcommand)]
enum AdminCmd {
    /// Генерация админских ключей
    Init,
    /// Регистрация пользователя на сервере
    RegUser {
        #[arg(long)]
        username: String,
    },
}

#[derive(Subcommand)]
enum UserCmd {
    /// Генерация пользовательских ключей
    Init,
}

#[derive(Subcommand)]
enum DialogueCmd {
    /// Установить ключ диалога (hex) явно
    Init {
        #[arg(long)]
        peer: String,
        #[arg(long)]
        session_key_hex: String,
    },
    /// Запросить ключ диалога из stdin
    SetKey {
        #[arg(long)]
        peer: String,
    },
}

#[derive(Subcommand)]
enum TopicCmd {
    /// Список тем диалога: имя, число сообщений.
    List {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
    },
    /// Удалить тему целиком (все её сообщения, у обеих сторон).
    Delete {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        /// Имя темы.
        #[arg(long)]
        topic: String,
    },
}

/// CLI — это dev-инструмент: гонять «промышленную» policy с интерактивным
/// PIN'ом тут оверкилл. Инициализируем vault в текущей папке (см. `.paranoia-cli-data/`)
/// и заводим/анлокаем фиксированным PIN'ом из переменной окружения
/// `PARANOIA_CLI_PIN` (по умолчанию — заведомо нестойкий "paranoia-cli-dev",
/// который НЕ предназначен для прод-данных).
fn init_vault_for_cli() -> Result<()> {
    let pin = std::env::var("PARANOIA_CLI_PIN").unwrap_or_else(|_| "paranoia-cli-dev".to_string());
    init_vault_with_pin(&pin)
}

/// Инициализировать/разблокировать CLI-vault в текущем каталоге заданным PIN.
/// Вынесено из `init_vault_for_cli`, чтобы TUI мог спросить PIN интерактивно.
fn init_vault_with_pin(pin: &str) -> Result<()> {
    use paranoia_lib::local_vault;
    let root = std::env::current_dir()
        .context("cwd")?
        .join(".paranoia-cli-data");
    std::fs::create_dir_all(&root).with_context(|| format!("mkdir {}", root.display()))?;
    local_vault::vault::set_app_data_root(root.clone());
    if let Err(e) = local_vault::recover_pending_rekey() {
        eprintln!("warn: recover_pending_rekey: {e}");
    }
    match local_vault::status().context("vault status")? {
        local_vault::VaultStatus::NotInitialized => {
            local_vault::set_pin(pin).context("vault set_pin")?;
        }
        local_vault::VaultStatus::Locked => {
            local_vault::unlock(pin).context("vault unlock — неверный PIN?")?;
        }
        local_vault::VaultStatus::Unlocked => {}
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    // MCP/скрипты: если задан рабочий каталог — перейти в него ДО инициализации
    // vault. Стор (.paranoia-cli-data, DEVICE_KEY, paranoia.db) адресуется
    // относительно cwd, а ~/.paranoia_dialogues.json — относительно HOME; сводим
    // оба в WORKDIR (реплицирует поведение прежней python-обёртки run_cli).
    if let Ok(wd) = std::env::var("PARANOIA_MCP_WORKDIR") {
        if !wd.is_empty() {
            std::env::set_current_dir(&wd)
                .with_context(|| format!("PARANOIA_MCP_WORKDIR: chdir {wd}"))?;
            // SAFETY: однопоточный старт процесса, до спавна tokio-задач.
            unsafe { std::env::set_var("HOME", &wd) };
        }
    }
    // `mcp install` сам настраивает workdir/PIN и инициализирует vault уже в нём —
    // ранний init в исходном cwd ему не нужен (и насорил бы там .paranoia-cli-data).
    let is_mcp_install = matches!(
        &cli.command,
        Commands::Mcp {
            cmd: Some(McpCmd::Install { .. }),
            ..
        }
    );
    // TUI сам инициализирует vault: спрашивает PIN интерактивно (если не в env),
    // поэтому ранний init с дефолтным PIN ему не нужен.
    let is_tui = matches!(&cli.command, Commands::Tui { .. });
    if !is_mcp_install && !is_tui {
        init_vault_for_cli()?;
    }

    match cli.command {
        Commands::Admin { cmd } => match cmd {
            AdminCmd::Init => {
                admin_init()?;
            }
            AdminCmd::RegUser { username } => {
                admin_reg_user(&cli.server_url, &cli.reserve_server_urls, &username).await?;
            }
        },
        Commands::User { cmd } => match cmd {
            UserCmd::Init => {
                user_init()?;
            }
        },
        Commands::Dialogue { cmd } => match cmd {
            DialogueCmd::Init {
                peer,
                session_key_hex,
            } => {
                cmd_dialogue_init(&peer, &session_key_hex)?;
            }
            DialogueCmd::SetKey { peer } => {
                cmd_dialogue_set_key(&peer)?;
            }
        },
        Commands::DeviceKey { cmd } => match cmd {
            DeviceKeyCmd::Show => {
                cmd_device_key_show()?;
            }
        },
        Commands::Export {
            profile,
            username,
            peers,
            receiver_pub,
            out,
        } => {
            cmd_export(&cli.server_url, profile, username, peers, receiver_pub, out)?;
        }
        Commands::Import { file } => {
            cmd_import(&cli.server_url, file)?;
        }
        Commands::ServerId {
            signing_key_b64,
            json,
        } => {
            cmd_server_id(signing_key_b64, json)?;
        }
        Commands::SyncFromUi {
            app_data_root,
            pin,
            profile,
        } => {
            cmd_sync_from_ui(&cli.server_url, app_data_root, pin, profile)?;
        }
        Commands::Mcp {
            username,
            peer,
            log,
            cmd,
        } => match cmd {
            Some(McpCmd::Install {
                workdir,
                pin,
                source,
                ui_app_data_root,
                ui_pin,
                export_file,
                username: inst_username,
                peer: inst_peer,
                hosts,
                non_interactive,
                dry_run,
                json,
                channel,
            }) => {
                mcp_install::run(mcp_install::InstallOpts {
                    server_url: cli.server_url.clone(),
                    workdir,
                    pin,
                    source,
                    ui_app_data_root,
                    ui_pin,
                    export_file,
                    username: inst_username,
                    peer: inst_peer,
                    hosts,
                    non_interactive,
                    dry_run,
                    json,
                    channel,
                })?;
            }
            None => {
                cmd_mcp(
                    &cli.server_url,
                    &cli.reserve_server_urls,
                    &cli.db_path,
                    username,
                    peer,
                    log,
                )
                .await?;
            }
        },
        Commands::Send {
            username,
            peer,
            text,
            topic,
        } => {
            cmd_send(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                &text,
                topic,
            )
            .await?;
        }
        Commands::Topic { cmd } => match cmd {
            TopicCmd::List { username, peer } => {
                cmd_topic_list(
                    &cli.server_url,
                    &cli.reserve_server_urls,
                    &username,
                    &cli.db_path,
                    &peer,
                )
                .await?;
            }
            TopicCmd::Delete { username, peer, topic } => {
                cmd_topic_delete(
                    &cli.server_url,
                    &cli.reserve_server_urls,
                    &username,
                    &cli.db_path,
                    &peer,
                    &topic,
                )
                .await?;
            }
        },
        Commands::Tui { username } => {
            tui::run(
                cli.server_url.clone(),
                cli.reserve_server_urls.clone(),
                cli.db_path.clone(),
                username,
            )
            .await?;
        }
        Commands::ProfileName { username, name } => {
            dialogue_store::set_profile_local_name(&username, &name)?;
            println!("Профилю {username} задан ник: {name}");
        }
        Commands::React {
            username,
            peer,
            message_id,
            emoji,
        } => {
            cmd_react(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                &message_id,
                &emoji,
            )
            .await?;
        }
        Commands::CallOffer { username, peer } => {
            cmd_call_offer(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
            )
            .await?;
        }
        Commands::CallHangup { username, peer, call_id } => {
            cmd_call_hangup(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                &call_id,
            )
            .await?;
        }
        Commands::Receive {
            username,
            peer,
            long_poll_ms,
            topic,
        } => {
            cmd_receive(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                long_poll_ms,
                topic,
            )
            .await?;
        }
        Commands::Watch {
            username,
            peer,
            interval,
            long_poll_ms,
            topic,
        } => {
            cmd_watch(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                interval,
                long_poll_ms,
                topic,
            )
            .await?;
        }
        Commands::SendFile {
            username,
            peer,
            path,
            topic,
        } => {
            cmd_send_file(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                &path,
                topic,
            )
            .await?;
        }
        Commands::Download {
            username,
            peer,
            message_id,
            out,
        } => {
            cmd_download(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                &message_id,
                &out,
            )
            .await?;
        }
        Commands::Clear {
            username,
            peer,
            cut_seq,
        } => {
            cmd_clear(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                cut_seq,
            )
            .await?;
        }
    }

    Ok(())
}
