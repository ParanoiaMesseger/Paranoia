use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::SigningKey;
use paranoia_lib::{
    AdminKeyPair, ClientConfig, DialogueConfig, DialogueKey, DialogueKeyEntry, MessageContent,
    ParanoiaClient,
};
use rand::RngCore;
use std::{
    fs,
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::Duration,
};
use tempfile::TempDir;

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
        reserve_server_urls: Vec::new(),
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

#[tokio::test]
async fn notify_counts_messages_without_pulling_payloads() {
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

    alice_dialogue.send_text("one").await.expect("send one");
    alice_dialogue.send_text("two").await.expect("send two");
    alice_dialogue.send_text("three").await.expect("send three");

    let pending = bob_dialogue.notify_count().await.expect("bob notify count");
    assert_eq!(pending, 3);

    let local_history = bob_dialogue
        .history(10, None)
        .await
        .expect("bob local history");
    assert!(
        local_history.is_empty(),
        "notify must not pull or decrypt payloads"
    );

    let (received, decrypt_errors) = bob_dialogue.receive().await.expect("bob receives");
    assert_eq!(decrypt_errors, 0);
    assert_eq!(received.len(), 3);

    let pending_after_receive = bob_dialogue
        .notify_count()
        .await
        .expect("bob notify after receive");
    assert_eq!(pending_after_receive, 0);

    server.kill().ok();
    server.wait().ok();
}

#[tokio::test]
async fn file_header_skips_body_until_explicit_download() {
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

    let data: Vec<u8> = (0..4096).map(|i| (i % 251) as u8).collect();
    alice_dialogue
        .send_file("payload.bin", "application/octet-stream", data.clone())
        .await
        .expect("alice sends file");
    alice_dialogue
        .send_text("after file")
        .await
        .expect("alice sends text after file");

    let (received, decrypt_errors) = bob_dialogue.receive().await.expect("bob receives");
    assert_eq!(decrypt_errors, 0);
    assert_eq!(received.len(), 2);

    let file_msg = &received[0];
    let file = match &file_msg.content {
        MessageContent::File(file) => file,
        other => panic!("expected file header message, got {other:?}"),
    };
    assert_eq!(file.filename, "payload.bin");
    assert_eq!(file.size, data.len());
    assert!(file.data.is_empty(), "receive must not download file body");
    assert!(!file.downloaded);
    assert!(file.body_to_seq > file_msg.server_seq.unwrap());
    assert!(matches!(&received[1].content, MessageContent::Text(text) if text == "after file"));

    let target_path = temp.path().join("downloaded.bin");
    bob_dialogue
        .download_attachment(file_msg.id.as_str(), target_path.to_str().unwrap())
        .await
        .expect("download attachment");
    assert_eq!(fs::read(&target_path).expect("read downloaded file"), data);

    let history = bob_dialogue.history(10, None).await.expect("history");
    let downloaded = history
        .iter()
        .find(|msg| msg.id == file_msg.id)
        .expect("file in history");
    let file = match &downloaded.content {
        MessageContent::File(file) => file,
        other => panic!("expected file in history, got {other:?}"),
    };
    assert!(file.downloaded);
    assert_eq!(file.data.len(), data.len());

    server.kill().ok();
    server.wait().ok();
}

#[tokio::test]
async fn multi_megabyte_file_sends_and_downloads_in_small_requests() {
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

    let data: Vec<u8> = (0..(3 * 1024 * 1024)).map(|i| (i % 251) as u8).collect();
    alice_dialogue
        .send_file("large.bin", "application/octet-stream", data.clone())
        .await
        .expect("alice sends large file");

    let (received, decrypt_errors) = bob_dialogue.receive().await.expect("bob receives");
    assert_eq!(decrypt_errors, 0);
    assert_eq!(received.len(), 1);
    let file_msg = &received[0];
    let file = match &file_msg.content {
        MessageContent::File(file) => file,
        other => panic!("expected file header message, got {other:?}"),
    };
    assert_eq!(file.size, data.len());
    assert!(
        file.chunk_count > 1,
        "large file must be sent in multiple chunks"
    );

    let target_path = temp.path().join("downloaded-large.bin");
    bob_dialogue
        .download_attachment(file_msg.id.as_str(), target_path.to_str().unwrap())
        .await
        .expect("download large attachment");
    assert_eq!(fs::read(&target_path).expect("read downloaded file"), data);

    server.kill().ok();
    server.wait().ok();
}

fn signing_key() -> SigningKey {
    let mut secret = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut secret);
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
        reserve_server_urls: Vec::new(),
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
    DialogueConfig::single_key(DialogueKey::new(username, peer), session_key)
}

fn dialogue_keyring_config(
    username: &str,
    peer: &str,
    entries: Vec<(u64, [u8; 32])>,
) -> DialogueConfig {
    DialogueConfig::with_keyring(
        DialogueKey::new(username, peer),
        entries
            .into_iter()
            .map(|(start_seq, key)| DialogueKeyEntry { start_seq, key })
            .collect(),
    )
    .expect("valid keyring")
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
            .put(format!("{server_url}/pull"))
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

// ── Multi-device: синхронизация seq после сброса БД ──────────────────────────

/// После удаления локальной SQLite Alice сначала делает pull, восстанавливает
/// последний серверный seq и отправляет следующее сообщение с seq=2.
#[tokio::test]
async fn fresh_device_syncs_seq_after_db_reset() {
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

    // Удаляем клиент и БД Alice — локальное состояние seq сбросится.
    drop(alice_dialogue);
    drop(alice);
    let alice_db = temp.path().join("alice.sqlite");
    fs::remove_file(&alice_db).expect("remove alice db");

    // Пересоздаём Alice с чистой БД. send_text() должен сначала подтянуть
    // серверную историю, сохранить неизвестный собственный пакет и выбрать seq=2.
    let fresh_alice = build_client(temp.path(), &server_url, "alice", alice_key);
    let fresh_dialogue = fresh_alice.open_dialogue(dialogue_config("alice", "bob", session_key));

    let sent = fresh_dialogue
        .send_text("second message after sync")
        .await
        .expect("fresh Alice sends with synchronized seq");
    assert_eq!(sent.server_seq, Some(2));

    let fresh_history = fresh_dialogue
        .history(10, None)
        .await
        .expect("fresh Alice restored own history");
    assert_eq!(fresh_history.len(), 2);
    assert!(
        matches!(&fresh_history[0].content, MessageContent::Text(text) if text == "first message")
    );
    assert!(
        matches!(&fresh_history[1].content, MessageContent::Text(text) if text == "second message after sync")
    );

    let bob_dialogue = bob.open_dialogue(dialogue_config("bob", "alice", session_key));
    let (bob_msgs, decrypt_errors) = bob_dialogue
        .receive()
        .await
        .expect("bob receives both messages");
    assert_eq!(decrypt_errors, 0);
    assert_eq!(bob_msgs.len(), 2);
    assert!(matches!(&bob_msgs[0].content, MessageContent::Text(text) if text == "first message"));
    assert!(
        matches!(&bob_msgs[1].content, MessageContent::Text(text) if text == "second message after sync")
    );

    server.kill().ok();
    server.wait().ok();
}

// ── B6c: keyring по start_seq без изменения wire-format ─────────────────────

#[tokio::test]
async fn rotated_keyring_reads_old_and_new_messages() {
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

    let key1 = [7u8; 32];
    let key2 = [9u8; 32];
    let alice_v1 = alice.open_dialogue(dialogue_config("alice", "bob", key1));
    alice_v1
        .send_text("before rotation")
        .await
        .expect("send v1");

    let alice_keyring = alice.open_dialogue(dialogue_keyring_config(
        "alice",
        "bob",
        vec![(1, key1), (2, key2)],
    ));
    let sent = alice_keyring
        .send_text("after rotation")
        .await
        .expect("send v2");
    assert_eq!(sent.server_seq, Some(2));

    let bob_keyring = bob.open_dialogue(dialogue_keyring_config(
        "bob",
        "alice",
        vec![(1, key1), (2, key2)],
    ));
    let (msgs, decrypt_errors) = bob_keyring.receive().await.expect("bob receives");

    assert_eq!(decrypt_errors, 0);
    assert_eq!(msgs.len(), 2);
    assert!(matches!(&msgs[0].content, MessageContent::Text(text) if text == "before rotation"));
    assert!(matches!(&msgs[1].content, MessageContent::Text(text) if text == "after rotation"));

    server.kill().ok();
    server.wait().ok();
}

#[tokio::test]
async fn wrong_keyring_start_seq_causes_decrypt_error() {
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

    let key1 = [7u8; 32];
    let key2 = [9u8; 32];
    alice
        .open_dialogue(dialogue_config("alice", "bob", key1))
        .send_text("before rotation")
        .await
        .expect("send v1");
    alice
        .open_dialogue(dialogue_keyring_config(
            "alice",
            "bob",
            vec![(1, key1), (2, key2)],
        ))
        .send_text("after rotation")
        .await
        .expect("send v2");

    let wrong_bob_keyring = bob.open_dialogue(dialogue_keyring_config(
        "bob",
        "alice",
        vec![(1, key1), (3, key2)],
    ));
    let (msgs, decrypt_errors) = wrong_bob_keyring
        .receive()
        .await
        .expect("bob receives with wrong keyring");

    assert_eq!(decrypt_errors, 1);
    assert_eq!(msgs.len(), 1);
    assert!(matches!(&msgs[0].content, MessageContent::Text(text) if text == "before rotation"));

    server.kill().ok();
    server.wait().ok();
}
