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
    time::Duration,
};
use tempfile::TempDir;

#[tokio::test]
async fn two_clients_exchange_and_restore_history_from_sqlite() {
    let server_bin = match std::env::var("CARGO_BIN_EXE_paranoia") {
        Ok(path) => path,
        Err(_) => return,
    };

    let temp = TempDir::new().expect("create temp dir");
    let port = free_port();
    let server_url = format!("http://127.0.0.1:{port}");
    let admin = AdminKeyPair::generate();
    let config_path = write_server_config(temp.path(), port, &admin.pubkey_b64());
    let mut server = spawn_server(&server_bin, &config_path);

    wait_for_server(&server_url).await;

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

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind free port")
        .local_addr()
        .expect("read local addr")
        .port()
}
