Необходимо предусмотреть возможность давать для сервера резервные пути доступа. Например, для заворачивания трафика в CDN.

Вот что думается про cdn:
Схема абсолютно правильная и реализуется чисто через DNS + Yandex CDN без каких-либо изменений на origin-сервере.

## Схема архитектуры

```
Клиент (прямой путь)
  └─► paranoia.example.com (A-запись → твой IP)
        └─► Nginx → Axum origin

Клиент (CDN-путь, резервный)
  └─► cdn.example.com (CNAME → yccdn.ru)
        └─► Yandex CDN Edge
              └─► paranoia.example.com (Nginx) → Axum origin
```

## DNS-настройка

В DNS у `example.com` нужны две записи:

```dns
; Прямой доступ — A-запись на твой сервер
paranoia    IN  A      <твой_IP>

; CDN-путь — CNAME на Yandex CDN
cdn         IN  CNAME  e1b83ae3xxxxxxxx.topology.gslb.yccdn.ru.
```

`cdn` — отдельный CNAME, `paranoia` остаётся A-записью нетронутым. [yandex](https://yandex.cloud/en/docs/cdn/quickstart)

## Настройка CDN-ресурса в Yandex Cloud

При создании ресурса указываешь:

- **Domain name (cname):** `cdn.example.com`
- **Origin hostname:** `paranoia.example.com` (Yandex CDN будет стучаться сюда) [yandex](https://yandex.cloud/en/docs/cdn/operations/resources/create-resource)
- **Origin protocol:** HTTPS
- **SSL-сертификат:** Let's Encrypt через Certificate Manager — для `cdn.example.com`

```bash
yc cdn resource create \
  --cname cdn.example.com \
  --origin-hostname paranoia.example.com \
  --origin-protocol HTTPS \
  --ssl-certificate-type lets_encrypt \
  --allowed-http-methods GET,POST,HEAD,OPTIONS \
  --cache-enabled=false
```

## Nginx на сервере

Nginx должен принимать запросы от **обоих** доменов и передавать на Axum. Главное — добавить `cdn.example.com` в `server_name`:

```nginx
server {
    listen 443 ssl;
    server_name paranoia.example.com cdn.example.com;

    ssl_certificate     /etc/letsencrypt/live/paranoia.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/paranoia.example.com/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

> **Важно:** для `cdn.example.com` тебе нужен отдельный TLS-сертификат на сервере, либо wildcard `*.example.com`. Let's Encrypt выдаст его через `certbot --cert-name example.com -d paranoia.example.com -d cdn.example.com`.

## Переключение на стороне клиента (Paranoia)

Логика фолбэка в клиентском коде Paranoia:

```rust
const ENDPOINTS: &[&str] = &[
    "https://paranoia.example.com",   // прямой, пробуем первым
    "https://cdn.example.com",        // CDN-резерв
];

async fn send_request(path: &str, body: &[u8]) -> Result<Response> {
    for base in ENDPOINTS {
        let url = format!("{}{}", base, path);
        match client.post(&url).body(body.to_vec()).send().await {
            Ok(resp) => return Ok(resp),
            Err(_) => continue, // переходим к следующему
        }
    }
    Err(anyhow!("все эндпоинты недоступны"))
}
```

## Реализация в UI

- Резервный домен добавляется из списка администрируемых серверов, отдельной кнопкой у уже существующего сервера.
- Клиент может указать резервный адрес при входе/регистрации клиентского профиля и добавить его позже из текущего клиентского профиля.
- UI установки сервера не меняется.
- UI не настраивает DNS, CDN, TLS, nginx или сервер по SSH: считается, что резервный путь уже настроен админом вне приложения.
- Локально резервный URL сохраняется в `reserve_server_urls` отдельно для admin-профиля или client-профиля.
- Клиентская FFI-инициализация и admin-регистрация получают `reserve_server_urls`, поэтому существующая fallback-логика транспорта начинает использовать основной URL первым и резервные URL следом.
