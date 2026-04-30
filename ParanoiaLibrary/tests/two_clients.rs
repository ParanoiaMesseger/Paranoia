use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::SigningKey;
use paranoia_lib::{
    AdminKeyPair, ClientConfig, DialogueConfig, DialogueKey, MessageContent, ParanoiaClient,
};
use std::{
    fs,
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
use tempfile::TempDir;

const TEST_PORT_START: usize = 41000;
const TEST_PORT_END: usize = 65000;

static NEXT_TEST_PORT: AtomicUsize = AtomicUsize::new(TEST_PORT_START);
static SERVER_START_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

// ── helper: клиент с явным путём к БД ────────────────────────────────────────
fn build_client_db(
    db_path: &str,
    server_url: &str,
    username: &str,
    signing_key: SigningKey,
) -> ParanoiaClient {
    ParanoiaClient::new(ClientConfig {
        server_url: server_url.to_string(),
        username: username.to_string(),
        signing_key,
        db_path: db_path.to_string(),
    })
    .expect("create client")
}

#[tokio::test]
async fn two_clients_exchange_and_restore_history_from_sqlite() {
    let server_bin = match std::env::var("CARGO_BIN_EXE_paranoia") {
        Ok(path) => path,
        Err(_) => return,
    };

    let admin = AdminKeyPair::generate();
    let temp = TempDir::new().expect("create temp dir");
    let (server_url, mut server) =
        start_server(&server_bin, temp.path(), &admin.pubkey_b64()).await;

    let alice_key = signing_key();
    let bob_key = signing_key();
    let alice_pub = B64.encode(alice_key.verifying_key().to_bytes());
    let bob_pub = B64.encode(bob_key.verifying_key().to_bytes());

    let alice = build_client(temp.path(), &server_url, "alice", alice_key.clone());
    let bob = build_client(temp.path(), &server_url, "bob", bob_key.clone());
    alice
        .transport()
        .reg(
            "alice",
            &alice_pub,
            &admin.sign_user_registration("alice", &alice_pub),
        )
        .await
        .expect("register alice");
    bob.transport()
        .reg(
            "bob",
            &bob_pub,
            &admin.sign_user_registration("bob", &bob_pub),
        )
        .await
        .expect("register bob");

    let session_key = [7u8; 32];
    let alice_dialogue = alice.open_dialogue(dialogue_config("alice", "bob", session_key));
    let bob_dialogue = bob.open_dialogue(dialogue_config("bob", "alice", session_key));

    alice_dialogue
        .send_text("hello bob")
        .await
        .expect("alice sends message");
    let (received, decrypt_errors) = bob_dialogue.receive().await.expect("bob receives");
    assert_eq!(decrypt_errors, 0);
    assert_eq!(received.len(), 1);
    assert!(matches!(&received[0].content, MessageContent::Text(text) if text == "hello bob"));

    drop(bob_dialogue);
    drop(bob);

    let restarted_bob = build_client(temp.path(), &server_url, "bob", bob_key);
    let restarted_dialogue =
        restarted_bob.open_dialogue(dialogue_config("bob", "alice", session_key));
    let history = restarted_dialogue
        .history(10, None)
        .await
        .expect("read restored history");

    assert_eq!(history.len(), 1);
    assert!(matches!(&history[0].content, MessageContent::Text(text) if text == "hello bob"));

    server.kill().ok();
    server.wait().ok();
}

fn signing_key() -> SigningKey {
    let mut secret = [0u8; 32];
    rand::fill(&mut secret);
    SigningKey::from_bytes(&secret)
}

fn build_client(
    root: &Path,
    server_url: &str,
    username: &str,
    signing_key: SigningKey,
) -> ParanoiaClient {
    ParanoiaClient::new(ClientConfig {
        server_url: server_url.to_string(),
        username: username.to_string(),
        signing_key,
        db_path: root
            .join(format!("{username}.sqlite"))
            .to_string_lossy()
            .into_owned(),
    })
    .expect("create client")
}

fn dialogue_config(username: &str, peer: &str, session_key: [u8; 32]) -> DialogueConfig {
    DialogueConfig {
        key: DialogueKey::new(username, peer),
        session_key,
    }
}

fn write_server_config(root: &Path, port: u16, admin_key: &str) -> PathBuf {
    let config_path = root.join("Paranoia.json");
    let store_path = root.join("store");
    let config = serde_json::json!({
        "port": port,
        "store_path": store_path,
        "admin_key": admin_key,
        "users": {}
    });
    fs::write(&config_path, serde_json::to_vec_pretty(&config).unwrap()).expect("write config");
    config_path
}

async fn start_server(server_bin: &str, root: &Path, admin_key: &str) -> (String, Child) {
    let _start_guard = SERVER_START_LOCK.lock().await;
    let (port, reservation) = reserve_test_port();
    let server_url = format!("http://127.0.0.1:{port}");
    let config_path = write_server_config(root, port, admin_key);

    drop(reservation);
    let server = spawn_server(server_bin, &config_path);
    wait_for_server(&server_url).await;

    (server_url, server)
}

fn reserve_test_port() -> (u16, TcpListener) {
    for _ in TEST_PORT_START..TEST_PORT_END {
        let port = NEXT_TEST_PORT.fetch_add(1, Ordering::Relaxed);
        if port > TEST_PORT_END {
            NEXT_TEST_PORT.store(TEST_PORT_START, Ordering::Relaxed);
            continue;
        }

        if let Ok(listener) = TcpListener::bind(("127.0.0.1", port as u16)) {
            return (port as u16, listener);
        }
    }

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind free port");
    let port = listener.local_addr().expect("read local addr").port();
    (port, listener)
}

fn spawn_server(server_bin: &str, config_path: &Path) -> Child {
    Command::new(server_bin)
        .env("PARANOIA_CONFIG", config_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn server")
}

async fn wait_for_server(server_url: &str) {
    let client = reqwest::Client::new();
    for _ in 0..100 {
        if client
            .post(format!("{server_url}/pull"))
            .send()
            .await
            .is_ok()
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("server did not start in time");
}

// ── Task 6: determinate ───────────────────────────────────────────────────────

/// После determinate(cut_seq) сервер больше не отдаёт удалённые сообщения.
/// Клиент с незаполненной историей (last_pulled_seq=0) не получает ничего.
#[tokio::test]
async fn determinate_clears_server_history() {
    let server_bin = match std::env::var("CARGO_BIN_EXE_paranoia") {
        Ok(path) => path,
        Err(_) => return,
    };

    let admin = AdminKeyPair::generate();
    let temp = TempDir::new().expect("create temp dir");
    let (server_url, mut server) =
        start_server(&server_bin, temp.path(), &admin.pubkey_b64()).await;

    let alice_key = signing_key();
    let bob_key = signing_key();
    let alice_pub = B64.encode(alice_key.verifying_key().to_bytes());
    let bob_pub = B64.encode(bob_key.verifying_key().to_bytes());

    let alice = build_client(temp.path(), &server_url, "alice", alice_key.clone());
    let bob = build_client(temp.path(), &server_url, "bob", bob_key.clone());
    alice
        .transport()
        .reg(
            "alice",
            &alice_pub,
            &admin.sign_user_registration("alice", &alice_pub),
        )
        .await
        .expect("register alice");
    bob.transport()
        .reg(
            "bob",
            &bob_pub,
            &admin.sign_user_registration("bob", &bob_pub),
        )
        .await
        .expect("register bob");

    let session_key = [7u8; 32];
    let alice_dialogue = alice.open_dialogue(dialogue_config("alice", "bob", session_key));

    // Alice отправляет 3 сообщения (seq=1, 2, 3 на сервере)
    alice_dialogue.send_text("msg1").await.expect("send 1");
    alice_dialogue.send_text("msg2").await.expect("send 2");
    alice_dialogue.send_text("msg3").await.expect("send 3");

    // Alice стирает историю на сервере до seq=3 включительно
    alice_dialogue
        .clear_server_history(3)
        .await
        .expect("determinate");

    // Bob с чистой БД (last_pulled_seq=0) не должен получить ни одного сообщения
    let fresh_bob_db = temp.path().join("bob_fresh.sqlite");
    let fresh_bob = build_client_db(&fresh_bob_db.to_string_lossy(), &server_url, "bob", bob_key);
    let fresh_dialogue = fresh_bob.open_dialogue(dialogue_config("bob", "alice", session_key));
    let (msgs, errs) = fresh_dialogue.receive().await.expect("fresh bob receive");
    assert_eq!(errs, 0, "decrypt errors unexpected");
    assert_eq!(
        msgs.len(),
        0,
        "server history should be empty after determinate"
    );

    server.kill().ok();
    server.wait().ok();
}

// ── Task 6: неверный ключ диалога ─────────────────────────────────────────────

/// Bob пытается расшифровать сообщение Alice неправильным ключом.
/// receive() возвращает ([], decrypt_errors=1) — текст сообщения не раскрывается.
#[tokio::test]
async fn wrong_dialogue_key_causes_decrypt_error() {
    let server_bin = match std::env::var("CARGO_BIN_EXE_paranoia") {
        Ok(path) => path,
        Err(_) => return,
    };

    let admin = AdminKeyPair::generate();
    let temp = TempDir::new().expect("create temp dir");
    let (server_url, mut server) =
        start_server(&server_bin, temp.path(), &admin.pubkey_b64()).await;

    let alice_key = signing_key();
    let bob_key = signing_key();
    let alice_pub = B64.encode(alice_key.verifying_key().to_bytes());
    let bob_pub = B64.encode(bob_key.verifying_key().to_bytes());

    let alice = build_client(temp.path(), &server_url, "alice", alice_key.clone());
    let bob = build_client(temp.path(), &server_url, "bob", bob_key.clone());
    alice
        .transport()
        .reg(
            "alice",
            &alice_pub,
            &admin.sign_user_registration("alice", &alice_pub),
        )
        .await
        .expect("register alice");
    bob.transport()
        .reg(
            "bob",
            &bob_pub,
            &admin.sign_user_registration("bob", &bob_pub),
        )
        .await
        .expect("register bob");

    let correct_key = [7u8; 32];
    let wrong_key = [42u8; 32]; // Bob будет использовать неправильный ключ

    let alice_dialogue = alice.open_dialogue(dialogue_config("alice", "bob", correct_key));
    let bob_dialogue = bob.open_dialogue(dialogue_config("bob", "alice", wrong_key));

    alice_dialogue
        .send_text("secret text")
        .await
        .expect("alice sends");

    let (msgs, decrypt_errors) = bob_dialogue.receive().await.expect("bob receives");
    assert_eq!(decrypt_errors, 1, "expected exactly one decrypt error");
    assert_eq!(
        msgs.len(),
        0,
        "no messages should be delivered with wrong key"
    );

    server.kill().ok();
    server.wait().ok();
}

// ── Task 6: duplicate seq после сброса БД ────────────────────────────────────

/// После удаления локальной SQLite у Alice её счётчик seq сбрасывается в 1.
/// Попытка отправить сообщение с уже использованным seq=1 отклоняется сервером.
/// Ошибка содержит "Duplicate seq", что classify_send_error() кодирует как "duplicate_seq".
#[tokio::test]
async fn duplicate_seq_after_db_reset_is_rejected_by_server() {
    let server_bin = match std::env::var("CARGO_BIN_EXE_paranoia") {
        Ok(path) => path,
        Err(_) => return,
    };

    let admin = AdminKeyPair::generate();
    let temp = TempDir::new().expect("create temp dir");
    let (server_url, mut server) =
        start_server(&server_bin, temp.path(), &admin.pubkey_b64()).await;

    let alice_key = signing_key();
    let bob_key = signing_key();
    let alice_pub = B64.encode(alice_key.verifying_key().to_bytes());
    let bob_pub = B64.encode(bob_key.verifying_key().to_bytes());

    let alice = build_client(temp.path(), &server_url, "alice", alice_key.clone());
    let bob = build_client(temp.path(), &server_url, "bob", bob_key.clone());
    alice
        .transport()
        .reg(
            "alice",
            &alice_pub,
            &admin.sign_user_registration("alice", &alice_pub),
        )
        .await
        .expect("register alice");
    bob.transport()
        .reg(
            "bob",
            &bob_pub,
            &admin.sign_user_registration("bob", &bob_pub),
        )
        .await
        .expect("register bob");

    let session_key = [7u8; 32];
    let alice_dialogue = alice.open_dialogue(dialogue_config("alice", "bob", session_key));

    // Alice отправляет первое сообщение (seq=1 сохраняется на сервере)
    alice_dialogue
        .send_text("first message")
        .await
        .expect("alice sends first");

    // Удаляем клиент и БД Alice — счётчик seq сбросится в 1
    drop(alice_dialogue);
    drop(alice);
    let alice_db = temp.path().join("alice.sqlite");
    fs::remove_file(&alice_db).expect("remove alice db");

    // Пересоздаём Alice с чистой БД (next_send_seq = 1)
    let fresh_alice = build_client(temp.path(), &server_url, "alice", alice_key);
    let fresh_dialogue = fresh_alice.open_dialogue(dialogue_config("alice", "bob", session_key));

    // Сервер должен отклонить seq=1, т.к. он уже существует
    let result = fresh_dialogue
        .send_text("second message with dup seq")
        .await;
    assert!(
        result.is_err(),
        "send must fail: seq=1 is already on the server"
    );

    let err_msg = result.unwrap_err().to_string();
    assert!(
        err_msg.contains("Duplicate seq"),
        "error must indicate duplicate seq; got: {err_msg}"
    );

    server.kill().ok();
    server.wait().ok();
}
