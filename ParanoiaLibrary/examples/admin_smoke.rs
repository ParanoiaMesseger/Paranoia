//! Smoke-тест admin-API против локально запущенного ParanoiaServer.
//!
//! Использование:
//!   cargo run --example admin_smoke -- gen
//!     → печатает admin secret/pubkey (b64) для записи в конфиг сервера.
//!   PARANOIA_SERVER_URL=http://127.0.0.1:1599 \
//!   PARANOIA_ADMIN_SECRET=<b64> cargo run --example admin_smoke
//!     → прогоняет list/get/set/prune против сервера.

use paranoia_lib::AdminKeyPair;
use paranoia_lib::admin_api;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("gen") {
        let kp = AdminKeyPair::generate();
        println!("SECRET={}", kp.secret_b64());
        println!("PUBKEY={}", kp.pubkey_b64());
        return;
    }

    // reg <url> <admin_secret> <username>: генерирует ключ пользователя и
    // регистрирует его через admin-подпись.
    if args.get(1).map(String::as_str) == Some("reg") {
        let url = &args[2];
        let admin_secret = &args[3];
        let username = &args[4];
        let user_kp = AdminKeyPair::generate();
        let user_pub = user_kp.pubkey_b64();
        let admin = AdminKeyPair::from_secret_b64(admin_secret).expect("admin key");
        let sig = admin.sign_user_registration(username, &user_pub);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let cover =
            std::sync::Arc::new(paranoia_lib::client_cover_food::FoodDeliveryClientCover::new());
        let transport = paranoia_lib::transport::Transport::new(url, std::iter::empty::<&str>(), cover);
        match rt.block_on(transport.reg(username, &user_pub, &sig)) {
            Ok(()) => println!("registered {username} pubkey={user_pub}"),
            Err(e) => println!("reg failed: {e}"),
        }
        return;
    }

    // threadtest <url> <secret>: из спавненного потока вызвать list_users и reg
    // (имитация worker-потока QtConcurrent в панели).
    if args.get(1).map(String::as_str) == Some("threadtest") {
        let url = args[2].clone();
        let secret = args[3].clone();
        let h = std::thread::spawn(move || {
            let reserve: Vec<String> = Vec::new();
            println!("[thread] list_users: {}", admin_api::list_users(&url, &reserve, &secret).unwrap());
            let user_kp = AdminKeyPair::generate();
            let user_pub = user_kp.pubkey_b64();
            let admin = AdminKeyPair::from_secret_b64(&secret).unwrap();
            let sig = admin.sign_user_registration("threaduser", &user_pub);
            let rt = tokio::runtime::Runtime::new().unwrap();
            let cover = std::sync::Arc::new(paranoia_lib::client_cover_food::FoodDeliveryClientCover::new());
            let transport = paranoia_lib::transport::Transport::new(&url, std::iter::empty::<&str>(), cover);
            match rt.block_on(transport.reg("threaduser", &user_pub, &sig)) {
                Ok(()) => println!("[thread] reg OK"),
                Err(e) => println!("[thread] reg ERR: {e:?}"),
            }
        });
        h.join().unwrap();
        return;
    }

    // mkexport <recipient_pubkey> <url> <admin_secret> <outfile>: собрать payload
    // с admin_servers, зашифровать ECIES на pubkey получателя, записать файл —
    // имитация обычного экспорта профиля «Админ» из клиента.
    if args.get(1).map(String::as_str) == Some("mkexport") {
        let pubkey = &args[2];
        let url = &args[3];
        let admin_secret = &args[4];
        let outfile = &args[5];
        let payload = serde_json::json!({
            "format_version": 1,
            "profile_type": "admin",
            "servers": [],
            "admin_servers": [{
                "url": url,
                "admin_private_key_b64": admin_secret,
                "reserve_server_urls": []
            }]
        });
        use base64::{Engine, engine::general_purpose::STANDARD as B64};
        let pk_bytes: [u8; 32] = B64.decode(pubkey).expect("b64").try_into().expect("32 bytes");
        let envelope = paranoia_lib::export::ecies_encrypt(&pk_bytes, payload.to_string().as_bytes())
            .expect("ecies_encrypt");
        std::fs::write(outfile, envelope).expect("write");
        println!("wrote {outfile}");
        return;
    }

    let url = std::env::var("PARANOIA_SERVER_URL").expect("PARANOIA_SERVER_URL");
    let secret = std::env::var("PARANOIA_ADMIN_SECRET").expect("PARANOIA_ADMIN_SECRET");
    let reserve: Vec<String> = Vec::new();

    println!("== list_users ==");
    println!("{}", admin_api::list_users(&url, &reserve, &secret).unwrap());

    println!("== list_dialogues ==");
    println!("{}", admin_api::list_dialogues(&url, &reserve, &secret).unwrap());

    println!("== get_config ==");
    println!("{}", admin_api::get_config(&url, &reserve, &secret).unwrap());

    println!("== set_config (turn_public_ip=203.0.113.7) ==");
    println!(
        "{}",
        admin_api::set_config(&url, &reserve, &secret, r#"{"turn_public_ip":"203.0.113.7"}"#).unwrap()
    );

    println!("== get_config (after set) ==");
    println!("{}", admin_api::get_config(&url, &reserve, &secret).unwrap());

    println!("== delete_user (nonexistent) ==");
    println!(
        "{}",
        admin_api::delete_user(&url, &reserve, &secret, "no_such_user").unwrap()
    );

    println!("== prune_dialogues ==");
    println!("{}", admin_api::prune_dialogues(&url, &reserve, &secret).unwrap());

    // Негативный тест: неверный ключ админа должен отвергаться сервером.
    let bogus = AdminKeyPair::generate().secret_b64();
    println!("== list_users with WRONG admin key (expect invalid_admin_signature) ==");
    println!("{}", admin_api::list_users(&url, &reserve, &bogus).unwrap());
}
