use super::*;
use std::sync::{Arc, Mutex};
use tokio::net::UnixListener;

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "paranoia-codex-test-{:016x}",
            rand::random::<u64>()
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn cursor_survives_restart_and_rejects_corruption() {
    let dir = Scratch::new();
    let path = dir.0.join("cursor.json");
    assert!(State::load(&path).unwrap().is_none());
    let state = State {
        seq: 10,
        pending: Some(Pending {
            seq: 12,
            message_id: "m12".into(),
            reaction_sent: true,
            submitted: false,
        }),
    };
    state.save(&path).unwrap();
    let restored = State::load(&path).unwrap().unwrap();
    assert_eq!(restored.seq, 10);
    assert_eq!(restored.pending.unwrap().message_id, "m12");
    std::fs::write(&path, b"broken").unwrap();
    assert!(State::load(&path).is_err());
}

fn message() -> Message {
    Message {
        id: "m12".into(),
        dialogue: paranoia_lib::DialogueKey::new("me", "peer"),
        sender: "peer".into(),
        content: MessageContent::Text("text".into()),
        timestamp: chrono::Utc::now(),
        status: paranoia_lib::MessageStatus::Delivered,
        server_seq: Some(12),
        topic_id: Some("topic-id".into()),
        topic_name: Some("Topic".into()),
    }
}

#[test]
fn scope_excludes_other_topics_echoes_and_service_messages() {
    let mut m = message();
    assert!(in_scope(&m, "me", Some("topic-id")));
    assert!(!in_scope(&m, "me", Some("other-topic")));
    assert!(!in_scope(&m, "me", None));
    m.sender = "me".into();
    assert!(!in_scope(&m, "me", Some("topic-id")));
    m.sender = "peer".into();
    m.content = MessageContent::Reaction {
        target_id: "target".into(),
        emoji: "x".into(),
    };
    assert!(!in_scope(&m, "me", Some("topic-id")));
    m.content = MessageContent::Text("main".into());
    m.topic_id = None;
    assert!(in_scope(&m, "me", None));
}

#[test]
fn accounts_threads_and_topics_have_separate_state() {
    let tag = binding_tag(&["account", "peer", "topic", "thread"]);
    assert_ne!(tag, binding_tag(&["another", "peer", "topic", "thread"]));
    assert_ne!(tag, binding_tag(&["account", "peer", "other", "thread"]));
    assert_ne!(tag, binding_tag(&["account", "peer", "topic", "other"]));
    let dir = Scratch::new();
    let lock = dir.0.join("topic.lock");
    let first = try_acquire_pull(&lock).unwrap();
    assert!(try_acquire_pull(&lock).is_none());
    drop(first);
    assert!(try_acquire_pull(&lock).is_some());
}

#[derive(Default)]
struct Mock {
    queue: Vec<Value>,
    history: Vec<Value>,
    additions: usize,
    started: Vec<Value>,
    active: bool,
    disconnect_after_add: bool,
    add_error: Option<i64>,
}

async fn mock_server(listener: UnixListener, shared: Arc<Mutex<Mock>>) {
    loop {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        while let Some(Ok(WsMessage::Text(text))) = ws.next().await {
            let request: Value = serde_json::from_str(&text).unwrap();
            if request.get("id").is_none() {
                continue;
            }
            let result;
            let mut disconnect = false;
            let mut error_code = None;
            {
                let mut mock = shared.lock().unwrap();
                result = match request["method"].as_str().unwrap() {
                    "initialize" => json!({}),
                    "thread/read" => {
                        json!({"thread": {"id": "thread", "status": {"type": if mock.active { "active" } else { "idle" }}}})
                    }
                    "thread/queue/list" => json!({"data": mock.queue, "nextCursor": null}),
                    "thread/items/list" => json!({"data": mock.history, "nextCursor": null}),
                    "thread/queue/add" => {
                        error_code = mock.add_error.take();
                        if error_code != Some(-32602) {
                            mock.additions += 1;
                            mock.queue.push(json!({"id": "queued", "clientUserMessageId": request["params"]["clientUserMessageId"]}));
                        }
                        disconnect = mock.disconnect_after_add;
                        mock.disconnect_after_add = false;
                        json!({})
                    }
                    "thread/queue/start" => {
                        mock.started
                            .push(request["params"]["queuedSubmissionId"].clone());
                        mock.active = true;
                        json!({})
                    }
                    method => panic!("unexpected method {method}"),
                };
            }
            if disconnect {
                break;
            }
            let response = match error_code {
                Some(code) => json!({"id": request["id"], "error": {"code": code}}),
                None => json!({"id": request["id"], "result": result}),
            };
            ws.send(WsMessage::Text(response.to_string().into()))
                .await
                .unwrap();
        }
    }
}

fn mock_options(dir: &Scratch) -> Options {
    Options {
        socket: dir.0.join("codex.sock"),
        thread: "thread".into(),
        topic: "Topic".into(),
        after_message: None,
    }
}

#[tokio::test]
async fn lost_reply_and_reconnect_do_not_enqueue_twice() {
    let dir = Scratch::new();
    let options = mock_options(&dir);
    let listener = UnixListener::bind(&options.socket).unwrap();
    let shared = Arc::new(Mutex::new(Mock {
        disconnect_after_add: true,
        ..Mock::default()
    }));
    let server = tokio::spawn(mock_server(listener, shared.clone()));
    let mut codex = Codex::connect(&options).await.unwrap();
    let path = dir.0.join("state.json");
    let mut state = pending_state();
    state.save(&path).unwrap();
    assert!(
        submit(&mut codex, &mut state, &path, "paranoia:", Some("text"))
            .await
            .is_err()
    );
    let mut state = State::load(&path).unwrap().unwrap();
    assert_eq!(state.seq, 10);
    assert!(state.pending.as_ref().unwrap().submitted);
    drop(codex);
    let mut codex = Codex::connect(&options).await.unwrap();
    submit(&mut codex, &mut state, &path, "paranoia:", None)
        .await
        .unwrap();
    assert_eq!(state.seq, 12);
    assert!(state.pending.is_none());
    assert_eq!(shared.lock().unwrap().additions, 1);
    server.abort();
}

#[tokio::test]
async fn delivered_history_prevents_replay_and_idle_starts_only_own_queue() {
    let dir = Scratch::new();
    let options = mock_options(&dir);
    let listener = UnixListener::bind(&options.socket).unwrap();
    let shared = Arc::new(Mutex::new(Mock {
        history: vec![json!({"item": {"type": "userMessage", "clientId": "delivered"}})],
        queue: vec![
            json!({"id": "unrelated", "clientUserMessageId": "user"}),
            json!({"id": "later", "clientUserMessageId": "paranoia:00002"}),
            json!({"id": "first", "clientUserMessageId": "paranoia:00001"}),
        ],
        active: true,
        ..Mock::default()
    }));
    let server = tokio::spawn(mock_server(listener, shared.clone()));
    let mut codex = Codex::connect(&options).await.unwrap();
    assert!(codex.confirmed("delivered").await.unwrap());
    assert_eq!(shared.lock().unwrap().additions, 0);
    assert!(codex.start_queued("paranoia:").await.unwrap());
    assert!(shared.lock().unwrap().started.is_empty());
    shared.lock().unwrap().active = false;
    assert!(codex.start_queued("paranoia:").await.unwrap());
    assert_eq!(shared.lock().unwrap().started, vec![json!("first")]);
    server.abort();
}

fn pending_state() -> State {
    State {
        seq: 10,
        pending: Some(Pending {
            seq: 12,
            message_id: "m12".into(),
            reaction_sent: true,
            submitted: false,
        }),
    }
}

#[tokio::test]
async fn queue_to_history_gap_never_resends_or_advances_cursor() {
    let dir = Scratch::new();
    let options = mock_options(&dir);
    let listener = UnixListener::bind(&options.socket).unwrap();
    let shared = Arc::new(Mutex::new(Mock::default()));
    let server = tokio::spawn(mock_server(listener, shared.clone()));
    let mut codex = Codex::connect(&options).await.unwrap();
    let path = dir.0.join("state.json");
    let mut state = pending_state();
    state.pending.as_mut().unwrap().submitted = true;
    state.save(&path).unwrap();
    for _ in 0..3 {
        assert!(
            submit(&mut codex, &mut state, &path, "paranoia:", Some("text"))
                .await
                .is_err()
        );
        assert_eq!(State::load(&path).unwrap().unwrap().seq, 10);
    }
    shared.lock().unwrap().history.push(json!({"item": {
        "type": "userMessage", "clientId": "paranoia:00000000000000000012:m12"
    }}));
    submit(&mut codex, &mut state, &path, "paranoia:", None)
        .await
        .unwrap();
    assert_eq!(state.seq, 12);
    assert!(state.pending.is_none());
    assert_eq!(shared.lock().unwrap().additions, 0);
    server.abort();
}

#[tokio::test]
async fn internal_error_is_ambiguous_but_invalid_params_can_retry() {
    for code in [-32603, -32602] {
        let dir = Scratch::new();
        let options = mock_options(&dir);
        let listener = UnixListener::bind(&options.socket).unwrap();
        let shared = Arc::new(Mutex::new(Mock {
            add_error: Some(code),
            ..Mock::default()
        }));
        let server = tokio::spawn(mock_server(listener, shared.clone()));
        let mut codex = Codex::connect(&options).await.unwrap();
        let path = dir.0.join("state.json");
        let mut state = pending_state();
        state.save(&path).unwrap();
        assert!(
            submit(&mut codex, &mut state, &path, "paranoia:", Some("text"))
                .await
                .is_err()
        );
        assert_eq!(state.pending.as_ref().unwrap().submitted, code == -32603);
        assert_eq!(state.seq, 10);
        submit(&mut codex, &mut state, &path, "paranoia:", Some("text"))
            .await
            .unwrap();
        assert_eq!(state.seq, 12);
        assert_eq!(shared.lock().unwrap().additions, 1);
        server.abort();
    }
}

#[tokio::test]
#[ignore = "Запускается tests/codex_protocol.py на изолированном Codex"]
async fn native_lost_ack_recovers_once() {
    let socket = PathBuf::from(std::env::var("PARANOIA_CODEX_TEST_SOCKET").unwrap());
    let (ws, _) = tokio_tungstenite::client_async(
        "ws://localhost/",
        UnixStream::connect(&socket).await.unwrap(),
    )
    .await
    .unwrap();
    let mut codex = Codex {
        ws,
        next_id: 0,
        thread: String::new(),
    };
    codex.call("initialize", json!({"clientInfo": {"name": "paranoia_native_test", "version": "1"}, "capabilities": {"experimentalApi": true}})).await.unwrap();
    codex
        .ws
        .send(WsMessage::Text(
            json!({"method": "initialized"}).to_string().into(),
        ))
        .await
        .unwrap();
    let root = socket.parent().unwrap();
    let created = codex
        .call(
            "thread/start",
            json!({"cwd": root, "approvalPolicy": "never", "sandbox": "read-only"}),
        )
        .await
        .unwrap();
    let options = Options {
        socket,
        thread: created["thread"]["id"].as_str().unwrap().into(),
        topic: "Fixture".into(),
        after_message: None,
    };
    let _observer = codex;
    let dir = Scratch::new();
    let path = dir.0.join("state.json");
    let mut recoveries = 0;
    for i in 1..=30 {
        let proxy_path = dir.0.join(format!("proxy-{i}.sock"));
        let listener = UnixListener::bind(&proxy_path).unwrap();
        let proxy = tokio::spawn(drop_native_add_reply(listener, options.socket.clone()));
        let proxy_options = Options {
            socket: proxy_path,
            thread: options.thread.clone(),
            topic: options.topic.clone(),
            after_message: None,
        };
        let mut codex = Codex::connect(&proxy_options).await.unwrap();
        let prefix = format!("native-{i}:");
        let mut state = pending_state();
        state.save(&path).unwrap();
        assert!(
            submit(
                &mut codex,
                &mut state,
                &path,
                &prefix,
                Some("local fixture")
            )
            .await
            .is_err()
        );
        drop(codex);
        proxy.await.unwrap();
        let mut codex = Codex::connect(&options).await.unwrap();
        let mut state = State::load(&path).unwrap().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            match submit(&mut codex, &mut state, &path, &prefix, None).await {
                Ok(()) => break,
                Err(error) => {
                    assert!(std::time::Instant::now() < deadline, "{error}");
                    assert_eq!(state.seq, 10);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            }
        }
        assert_eq!(state.seq, 12);
        assert!(state.pending.is_none());
        recoveries += 1;
    }
    let mut codex = Codex::connect(&options).await.unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let page = codex
            .call(
                "thread/items/list",
                json!({"threadId": options.thread, "limit": 100, "sortDirection": "desc"}),
            )
            .await
            .unwrap();
        let mut counts = std::collections::HashMap::new();
        for entry in page["data"].as_array().unwrap() {
            if let Some(id) = entry["item"]["clientId"].as_str() {
                *counts.entry(id.to_string()).or_insert(0) += 1;
            }
        }
        if counts.len() == 30 {
            for count in counts.values() {
                assert_eq!(*count, 1);
            }
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "not all native messages reached history"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    println!("native: {recoveries} lost RPC replies recovered, 30 history entries, no duplicates");
}

async fn drop_native_add_reply(listener: UnixListener, socket: PathBuf) {
    let (stream, _) = listener.accept().await.unwrap();
    let mut downstream = tokio_tungstenite::accept_async(stream).await.unwrap();
    let stream = UnixStream::connect(socket).await.unwrap();
    let (mut upstream, _) = tokio_tungstenite::client_async("ws://localhost/", stream)
        .await
        .unwrap();
    let mut drop_id = None;
    loop {
        tokio::select! {
            Some(frame) = downstream.next() => {
                let frame = frame.unwrap();
                if let WsMessage::Text(text) = &frame {
                    let request: Value = serde_json::from_str(text).unwrap();
                    if request["method"] == "thread/queue/add" { drop_id = Some(request["id"].clone()); }
                }
                upstream.send(frame).await.unwrap();
            }
            Some(frame) = upstream.next() => {
                let frame = frame.unwrap();
                if let WsMessage::Text(text) = &frame {
                    let response: Value = serde_json::from_str(text).unwrap();
                    if drop_id.is_some() && response.get("id") == drop_id.as_ref() {
                        assert!(response.get("result").is_some(), "native queue/add rejected");
                        return;
                    }
                }
                downstream.send(frame).await.unwrap();
            }
        }
    }
}
