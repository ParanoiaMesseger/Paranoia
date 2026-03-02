use anyhow::{Context, Result, anyhow};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use clap::{Parser, Subcommand};
use ed25519_dalek::SigningKey;
use paranoia_lib::{
    AdminKeyPair, ClientConfig, Dialogue, DialogueConfig, DialogueKey, MessageContent,
    ParanoiaClient, crypto,
};
use rpassword::read_password;
use sha2::{Digest, Sha256};
use std::fs;

mod dialogue_store;

use dialogue_store::{load_dialogue_store, set_dialogue_key};

const ADMIN_SECRETS: &str = "./ADMIN_SECRETS";
const USER_SECRETS: &str = "./USER_SECRETS";
const ADMIN_PUB: &str = "./ADMIN_PUB";
const USER_PUB: &str = "./USER_PUB";

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

/// ADMIN INIT: сгенерировать админскую пару, зашифровать секрет, записать pub.
fn admin_init() -> Result<()> {
    let pair = AdminKeyPair::generate(); // генерирует секрет 32 байта и pub.
    let sk_b64 = pair.secret_b64(); // base64(32 байта).
    let pk_b64 = pair.pubkey_b64(); // base64(32 байта).

    let pin = read_pin()?;
    let ciphertext = encrypt_blob(&pin, sk_b64.as_bytes())?;
    fs::write(ADMIN_SECRETS, ciphertext).context("failed to write ADMIN_SECRETS")?;
    fs::write(ADMIN_PUB, pk_b64).context("failed to write ADMIN_PUB")?;

    println!("Admin keys generated.");
    println!("Admin pubkey saved to ADMIN_PUB, put it into server config (admin_key).");
    Ok(())
}

fn load_admin_keypair() -> Result<AdminKeyPair> {
    let pin = read_pin()?;
    let data = fs::read(ADMIN_SECRETS).context("failed to read ADMIN_SECRETS")?;
    let plaintext = decrypt_blob(&pin, &data).context("wrong PIN or corrupted ADMIN_SECRETS")?;
    let sk_b64 = String::from_utf8(plaintext)?;
    AdminKeyPair::from_secret_b64(&sk_b64)
}

/// ADMIN REG-USER: подписать pub клиента и вызвать /reg через Transport.
async fn admin_reg_user(server_url: &str, username: &str) -> Result<()> {
    let admin = load_admin_keypair()?;
    let user_pub_b64 = fs::read_to_string(USER_PUB)
        .context("failed to read USER_PUB")?
        .trim()
        .to_string();

    let admin_sig_b64 = admin.sign_user_registration(username, &user_pub_b64);

    let cover =
        std::sync::Arc::new(paranoia_lib::client_cover_food::FoodDeliveryClientCover::new());
    let transport = paranoia_lib::transport::Transport::new(server_url, cover);
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
    rand::fill(&mut secret_bytes);
    let sk = SigningKey::from(secret_bytes);
    let pk = sk.verifying_key();

    let sk_b64 = B64.encode(secret_bytes);
    let pk_b64 = B64.encode(pk.to_bytes());

    let pin = read_pin()?;
    let ciphertext = encrypt_blob(&pin, sk_b64.as_bytes())?;
    fs::write(USER_SECRETS, ciphertext).context("failed to write USER_SECRETS")?;
    fs::write(USER_PUB, pk_b64).context("failed to write USER_PUB")?;

    println!("User keys generated.");
    println!("Send USER_PUB to admin to get registered.");
    Ok(())
}

fn load_user_signing_key() -> Result<SigningKey> {
    let pin = read_pin()?;
    let data = fs::read(USER_SECRETS).context("failed to read USER_SECRETS")?;
    let plaintext = decrypt_blob(&pin, &data).context("wrong PIN or corrupted USER_SECRETS")?;
    let sk_b64 = String::from_utf8(plaintext)?;
    let bytes = B64.decode(sk_b64.trim())?;
    if bytes.len() != 32 {
        return Err(anyhow!("user secret must be 32 bytes, got {}", bytes.len()));
    }
    let mut secret_bytes = [0u8; 32];
    secret_bytes.copy_from_slice(&bytes[..32]);
    Ok(SigningKey::from_bytes(&secret_bytes))
}

fn build_client(server_url: &str, username: &str, db_path: &str) -> Result<ParanoiaClient> {
    let signing_key = load_user_signing_key()?;
    let cfg = ClientConfig {
        server_url: server_url.to_string(),
        username: username.to_string(),
        signing_key,
        db_path: db_path.to_string(),
    };
    ParanoiaClient::new(cfg) // создаёт Transport + LocalStore.
}

fn build_dialogue(client: &ParanoiaClient, username: &str, peer: &str) -> Result<Dialogue> {
    let store = load_dialogue_store()?;
    let key_hex = store
        .entries
        .get(peer)
        .context("no session_key for this peer, use 'dialogue init' or 'dialogue set-key' first")?;
    let key_bytes = hex::decode(key_hex)?;
    if key_bytes.len() != 32 {
        return Err(anyhow!(
            "stored session_key for peer '{}' has invalid length {}",
            peer,
            key_bytes.len()
        ));
    }
    let mut session_key = [0u8; 32];
    session_key.copy_from_slice(&key_bytes[..32]);

    let dkey = DialogueKey::new(username, peer);
    let dcfg = DialogueConfig {
        key: dkey,
        session_key,
    };
    Ok(client.open_dialogue(dcfg))
}

/// SEND (text)
async fn cmd_send(
    server_url: &str,
    username: &str,
    db_path: &str,
    peer: &str,
    text: &str,
) -> Result<()> {
    let client = build_client(server_url, username, db_path)?;
    let dialogue = build_dialogue(&client, username, peer)?;
    let msg = dialogue.send_text(text).await?;
    println!("Sent: id={} seq={:?}", msg.id, msg.server_seq);
    Ok(())
}

/// RECEIVE
async fn cmd_receive(server_url: &str, username: &str, db_path: &str, peer: &str) -> Result<()> {
    let client = build_client(server_url, username, db_path)?;
    let dialogue = build_dialogue(&client, username, peer)?;
    let msgs = dialogue.receive().await?;
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
    username: &str,
    db_path: &str,
    peer: &str,
    cut_seq: u64,
) -> Result<()> {
    let client = build_client(server_url, username, db_path)?;
    let dialogue = build_dialogue(&client, username, peer)?;
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

#[derive(Parser)]
#[command(name = "ParanoiaEasyCli")]
struct Cli {
    #[arg(long, default_value = "https://paranoia.example.com/api")]
    server_url: String,

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
                admin_reg_user(&cli.server_url, &username).await?;
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
        Commands::Send {
            username,
            peer,
            text,
        } => {
            cmd_send(&cli.server_url, &username, &cli.db_path, &peer, &text).await?;
        }
        Commands::Receive { username, peer } => {
            cmd_receive(&cli.server_url, &username, &cli.db_path, &peer).await?;
        }
        Commands::Clear {
            username,
            peer,
            cut_seq,
        } => {
            cmd_clear(&cli.server_url, &username, &cli.db_path, &peer, cut_seq).await?;
        }
    }

    Ok(())
}
