use crate::client_cover::ClientCover;
use anyhow::{Context, Result, anyhow, bail};
use reqwest::{Client, StatusCode};
use serde::Serialize;
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Внутренний пакет на отправку (push).
pub struct CorePush {
    pub sender: String,
    pub recver: String,
    pub seq: u64,
    pub payload: Vec<u8>, // зашифрованный бинарь (ciphertext)
    pub sig: Vec<u8>,     // подпись Ed25519 (64 байта)
}

/// Внутренний запрос pull.
pub struct CorePull {
    pub sender: String,
    pub recver: String,
    pub after_seq: u64,
    pub to_seq: u64,
    pub sig: Vec<u8>,
}

/// Внутренний запрос notify: посчитать сообщения после seq без загрузки payload.
pub struct CoreNotify {
    pub sender: String,
    pub partner: String,
    pub seq: u64,
    pub sig: Vec<u8>,
}

/// Внутренний запрос determinate.
pub struct CoreDeterminate {
    pub sender: String,
    pub recver: String,
    pub cut_seq: u64,
    pub sig: Vec<u8>,
}

/// Ответ одного пакета с сервера (после pull).
#[derive(Debug, Clone)]
pub struct RawPacket {
    pub seq: u64,
    pub payload: Vec<u8>, // уже декодированный из base64
}

// Для /reg оставляем простой формат без cover.
#[derive(Serialize)]
struct RegRequest<'a> {
    username: &'a str,
    pub_key: &'a str,
    admin_sig: &'a str,
}

pub struct Transport {
    client: Client,
    server_urls: Vec<String>,
    cover: Arc<dyn ClientCover>,
}

enum EndpointError {
    Retry(anyhow::Error),
    Stop(anyhow::Error),
}

impl Transport {
    pub fn new<I, S>(server_url: &str, reserve_server_urls: I, cover: Arc<dyn ClientCover>) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut server_urls = Vec::new();
        push_server_url(&mut server_urls, server_url);
        for url in reserve_server_urls {
            push_server_url(&mut server_urls, url.as_ref());
        }

        Self {
            client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .build()
                .unwrap_or_else(|_| Client::new()),
            server_urls,
            cover,
        }
    }

    // ── регистрировать пользователя (без cover) ─────────────────────────

    pub async fn reg(
        &self,
        username: &str,
        user_pubkey_b64: &str,
        admin_sig_b64: &str,
    ) -> Result<()> {
        let req = RegRequest {
            username,
            pub_key: user_pubkey_b64,
            admin_sig: admin_sig_b64,
        };
        let resp = self.put_json("/reg", &serde_json::to_value(&req)?).await?;
        let success = resp
            .get("success")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if !success {
            anyhow::bail!("Reg failed: {}", resp);
        }
        Ok(())
    }

    // ── ядро протокола через cover ──────────────────────────────────────

    pub async fn push(&self, core: &CorePush) -> Result<()> {
        let body = self.cover.wrap_push(core)?;
        let resp = self.put_json("/push", &body).await?;
        self.cover.unwrap_push_response(&resp)
    }

    pub async fn pull(&self, core: &CorePull) -> Result<Vec<RawPacket>> {
        let body = self.cover.wrap_pull(core)?;
        let resp = self.put_json("/pull", &body).await?;
        self.cover.unwrap_pull_response(&resp)
    }

    pub async fn notify(&self, core: &CoreNotify) -> Result<u64> {
        let body = self.cover.wrap_notify(core)?;
        let resp = self.put_json("/notify", &body).await?;
        self.cover.unwrap_notify_response(&resp)
    }

    /// Зондировать /notify: считаем endpoint доступным, если сервер ответил
    /// валидным JSON, даже если на уровне протокола это ошибка
    /// (например, "user not registered" для фиктивного запроса).
    /// Возвращает Err только при сетевых/TLS/HTTP-ошибках или невалидном JSON.
    pub async fn probe(&self, core: &CoreNotify) -> Result<()> {
        let body = self.cover.wrap_notify(core)?;
        let _resp = self.put_json("/notify", &body).await?;
        Ok(())
    }

    pub async fn determinate(&self, core: &CoreDeterminate) -> Result<()> {
        let body = self.cover.wrap_determinate(core)?;
        let resp = self.put_json("/determinate", &body).await?;
        self.cover.unwrap_determinate_response(&resp)
    }

    // ── HTTP утилита ────────────────────────────────────────────────────

    async fn put_json(&self, path: &str, body: &Value) -> Result<Value> {
        let mut last_retry_error = None;
        for server_url in &self.server_urls {
            let url = format!("{}{}", server_url, path);
            match self.put_json_once(&url, body).await {
                Ok(resp) => return Ok(resp),
                Err(EndpointError::Retry(err)) => last_retry_error = Some(err),
                Err(EndpointError::Stop(err)) => return Err(err),
            }
        }

        match last_retry_error {
            Some(err) => Err(err).context("all server endpoints unavailable"),
            None => bail!("no server endpoints configured"),
        }
    }

    async fn put_json_once(
        &self,
        url: &str,
        body: &Value,
    ) -> std::result::Result<Value, EndpointError> {
        let resp = match self.client.put(url).json(body).send().await {
            Ok(resp) => resp,
            Err(err) if err.is_builder() => {
                return Err(EndpointError::Stop(
                    anyhow!(err).context("invalid server endpoint"),
                ));
            }
            Err(err) => {
                return Err(EndpointError::Retry(
                    anyhow!(err).context("server endpoint request failed"),
                ));
            }
        };

        let status = resp.status();
        if status.is_server_error() || status == StatusCode::TOO_MANY_REQUESTS {
            return Err(EndpointError::Retry(anyhow!(
                "server endpoint returned retryable HTTP status {status}"
            )));
        }
        if !status.is_success() {
            return Err(EndpointError::Stop(anyhow!(
                "server endpoint returned HTTP status {status}"
            )));
        }

        resp.json::<Value>().await.map_err(|err| {
            EndpointError::Stop(anyhow!(err).context("invalid server JSON response"))
        })
    }
}

fn push_server_url(server_urls: &mut Vec<String>, url: &str) {
    let url = url.trim().trim_end_matches('/').to_string();
    if !url.is_empty() && !server_urls.contains(&url) {
        server_urls.push(url);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{CoreDeterminate, CoreNotify, CorePull, CorePush, RawPacket};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    struct NoopCover;

    impl ClientCover for NoopCover {
        fn wrap_push(&self, _core: &CorePush) -> Result<Value> {
            unreachable!()
        }

        fn wrap_pull(&self, _core: &CorePull) -> Result<Value> {
            unreachable!()
        }

        fn wrap_notify(&self, _core: &CoreNotify) -> Result<Value> {
            unreachable!()
        }

        fn wrap_determinate(&self, _core: &CoreDeterminate) -> Result<Value> {
            unreachable!()
        }

        fn unwrap_pull_response(&self, _body: &Value) -> Result<Vec<RawPacket>> {
            unreachable!()
        }

        fn unwrap_notify_response(&self, _body: &Value) -> Result<u64> {
            unreachable!()
        }

        fn unwrap_push_response(&self, _body: &Value) -> Result<()> {
            unreachable!()
        }

        fn unwrap_determinate_response(&self, _body: &Value) -> Result<()> {
            unreachable!()
        }
    }

    fn noop_cover() -> Arc<dyn ClientCover> {
        Arc::new(NoopCover)
    }

    fn unused_local_url() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind unused port");
        let addr = listener.local_addr().expect("local addr");
        drop(listener);
        format!("http://{addr}")
    }

    fn spawn_json_server(
        status: &'static str,
        body: &'static str,
    ) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
        let url = format!("http://{}", listener.local_addr().expect("local addr"));
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let mut buf = [0u8; 2048];
            let _ = stream.read(&mut buf);
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .expect("write response");
        });
        (url, handle)
    }

    #[test]
    fn reserve_urls_are_normalized_and_deduplicated() {
        let transport = Transport::new(
            " https://paranoia.example.com/api/ ",
            ["https://cdn.example.com/", "https://cdn.example.com", "   "],
            noop_cover(),
        );

        assert_eq!(
            transport.server_urls,
            vec![
                "https://paranoia.example.com/api".to_string(),
                "https://cdn.example.com".to_string(),
            ]
        );
    }

    #[tokio::test]
    async fn reg_falls_back_to_reserve_url_on_primary_connection_error() {
        let primary_url = unused_local_url();
        let (reserve_url, reserve_server) = spawn_json_server("200 OK", r#"{"success":true}"#);
        let transport = Transport::new(
            &primary_url,
            std::iter::once(reserve_url.as_str()),
            noop_cover(),
        );

        transport
            .reg("alice", "user_pubkey", "admin_sig")
            .await
            .expect("reserve endpoint should handle request");
        reserve_server.join().expect("reserve server thread");
    }

    #[tokio::test]
    async fn reg_falls_back_to_reserve_url_on_retryable_http_status() {
        let (primary_url, primary_server) = spawn_json_server("502 Bad Gateway", "{}");
        let (reserve_url, reserve_server) = spawn_json_server("200 OK", r#"{"success":true}"#);
        let transport = Transport::new(
            &primary_url,
            std::iter::once(reserve_url.as_str()),
            noop_cover(),
        );

        transport
            .reg("alice", "user_pubkey", "admin_sig")
            .await
            .expect("reserve endpoint should handle request");
        primary_server.join().expect("primary server thread");
        reserve_server.join().expect("reserve server thread");
    }
}
