use anyhow::{Context, Result, anyhow};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use clap::{Parser, Subcommand, ValueEnum};
use ed25519_dalek::SigningKey;
use paranoia_lib::{
    AdminKeyPair, ClientConfig, Dialogue, DialogueConfig, DialogueKey, DialogueKeyEntry,
    MessageContent, ParanoiaClient, crypto,
    export::{
        EXPORT_PAYLOAD_VERSION, ExportAdminServer, ExportDialogue, ExportKeyEntry, ExportPayload,
        ExportProfileType, ExportServer, ecies_decrypt, ecies_encrypt, generate_device_keypair,
        pubkey_from_private_key, validate_export_payload,
    },
};
use rand::RngCore;
use rpassword::read_password;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

mod dialogue_store;

use dialogue_store::{
    MergeOutcome, ProfileDialogueStore, base64_entry_to_key, key_entry_from_base64,
    key_entry_from_hex, load_dialogue_store, merge_profile_keyring_entry, profile_id,
    profile_keyring_entries, save_dialogue_store, set_dialogue_key,
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
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let msg = dialogue.send_text(text).await?;
    println!("Sent: id={} seq={:?}", msg.id, msg.server_seq);
    Ok(())
}

/// RECEIVE
async fn cmd_receive(
    server_url: &str,
    reserve_server_urls: &[String],
    username: &str,
    db_path: &str,
    peer: &str,
) -> Result<()> {
    let client = build_client(server_url, reserve_server_urls, username, db_path)?;
    let dialogue = build_dialogue(&client, server_url, username, peer)?;
    let (msgs, decrypt_errors) = dialogue.receive().await?;
    if decrypt_errors > 0 {
        eprintln!(
            "Warning: {decrypt_errors} message(s) could not be decrypted (wrong session key?)"
        );
    }
    for m in msgs {
        match &m.content {
            MessageContent::Text(t) => {
                println!("[{}] {}: {}", m.timestamp, m.sender, t);
            }
            other => {
                println!("[{}] {}: {:?}", m.timestamp, m.sender, other);
            }
        }
    }
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
        for (peer, entries) in &profile.dialogues {
            if !selected_peer(peer, peers) {
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
                    peer: peer.clone(),
                    peer_server_id: None,
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
) -> (&'a mut ProfileDialogueStore, bool) {
    let id = profile_id(&server.url, &server.username);
    let existed = store.profiles.contains_key(&id);
    let profile = store
        .profiles
        .entry(id)
        .or_insert_with(|| ProfileDialogueStore {
            server_url: server.url.clone(),
            username: server.username.clone(),
            signing_key_b64: String::new(),
            signing_key_ct_b64: String::new(),
            dialogues: Default::default(),
        });
    (profile, !existed)
}

fn import_server_profile(
    store: &mut dialogue_store::DialogueKeyStore,
    server: &ExportServer,
    stats: &mut ImportStats,
) -> Result<()> {
    validate_b64_32(&server.signing_key_b64, "imported user signing key")?;
    let (profile, created) = profile_for_import(store, server);
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
        let mut touched_dialogue = false;
        for entry in &dialogue.keyring {
            let entry = key_entry_from_base64(entry.start_seq, &entry.key)?;
            match merge_profile_keyring_entry(profile, &dialogue.peer, entry) {
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

fn cmd_import(server_url: &str, file: PathBuf) -> Result<()> {
    let metadata =
        fs::metadata(&file).with_context(|| format!("failed to stat {}", file.display()))?;
    if metadata.len() > MAX_EXPORT_FILE_BYTES {
        return Err(anyhow!("export file is larger than 16 MiB"));
    }
    let envelope =
        fs::read_to_string(&file).with_context(|| format!("failed to read {}", file.display()))?;
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

    println!(
        "Import complete: profiles={}, dialogues={}, key_entries={}, admin_servers={}, skipped={}, conflicts={}",
        stats.profiles,
        stats.dialogues,
        stats.key_entries,
        stats.admin_servers,
        stats.skipped,
        stats.conflicts
    );
    Ok(())
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
    /// Отправка текстового сообщения
    Send {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
        #[arg(long)]
        text: String,
    },
    /// Получение новых сообщений
    Receive {
        #[arg(long)]
        username: String,
        #[arg(long)]
        peer: String,
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

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
        Commands::Send {
            username,
            peer,
            text,
        } => {
            cmd_send(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
                &text,
            )
            .await?;
        }
        Commands::Receive { username, peer } => {
            cmd_receive(
                &cli.server_url,
                &cli.reserve_server_urls,
                &username,
                &cli.db_path,
                &peer,
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
