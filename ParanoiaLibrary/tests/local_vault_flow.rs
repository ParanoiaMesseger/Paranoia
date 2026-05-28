//! End-to-end проверка PIN flow: set_pin → encrypt JSON → lock → unlock →
//! lockout после серии неверных вводов. Не использует FFI — гоняет напрямую
//! публичные функции crate::local_vault.

use paranoia_lib::local_vault::{
    self, decrypt_attachment, decrypt_json_from_disk, encrypt_attachment,
    encrypt_json_to_disk, VaultStatus,
};
use std::sync::Mutex;
use tempfile::tempdir;

// Vault — глобальный singleton. Тесты должны идти строго последовательно,
// иначе одна гонка APP_DATA_ROOT/VAULT поломает другую. cargo по умолчанию
// гонит тесты в одном бинарнике параллельно через threads, поэтому
// сериализуем через mutex.
static TEST_MUTEX: Mutex<()> = Mutex::new(());

fn init_clean_tmpdir() -> tempfile::TempDir {
    let tmp = tempdir().expect("tempdir");
    local_vault::vault::set_app_data_root(tmp.path().to_path_buf());
    local_vault::lock();
    tmp
}

#[test]
fn full_pin_flow_set_lock_unlock() {
    let _g = TEST_MUTEX.lock().unwrap();
    let tmp = init_clean_tmpdir();

    // 1. Изначально vault не инициализирован.
    assert_eq!(local_vault::status().unwrap(), VaultStatus::NotInitialized);

    // 2. Устанавливаем PIN — vault сразу в unlocked.
    local_vault::set_pin("123456").expect("set_pin");
    assert_eq!(local_vault::status().unwrap(), VaultStatus::Unlocked);

    // 3. Пишем JSON-файл — на диске должны быть бинарные байты с magic 'PVL1'.
    let path = tmp.path().join("profiles.json");
    let plaintext = br#"{"v":1,"profiles":[]}"#;
    encrypt_json_to_disk(&path, plaintext).expect("encrypt");
    let raw = std::fs::read(&path).expect("read enc");
    assert!(raw.len() > 4 + 12 + 16, "encrypted file too short");
    assert_eq!(&raw[..4], b"PVL1");
    // Шифротекст не должен содержать plaintext.
    assert!(
        !raw.windows(plaintext.len()).any(|w| w == plaintext),
        "ciphertext leaks plaintext"
    );

    // 4. Расшифровка возвращает оригинал.
    let decoded = decrypt_json_from_disk(&path).expect("decrypt");
    assert_eq!(decoded, plaintext);

    // 5. lock — статус Locked.
    local_vault::lock();
    assert_eq!(local_vault::status().unwrap(), VaultStatus::Locked);

    // 6. Чтение после lock — должно упасть (vault_locked).
    assert!(decrypt_json_from_disk(&path).is_err());

    // 7. Неверный PIN.
    let err = local_vault::unlock("999999").unwrap_err();
    assert!(err.to_string().contains("wrong_pin"), "got: {err}");
    assert_eq!(local_vault::status().unwrap(), VaultStatus::Locked);

    // 8. Верный PIN — возвращаемся в Unlocked.
    local_vault::unlock("123456").expect("unlock");
    assert_eq!(local_vault::status().unwrap(), VaultStatus::Unlocked);

    // 9. Расшифровка снова работает.
    let decoded2 = decrypt_json_from_disk(&path).expect("decrypt2");
    assert_eq!(decoded2, plaintext);
}

#[test]
fn lockout_after_six_wrong_attempts() {
    let _g = TEST_MUTEX.lock().unwrap();
    let _tmp = init_clean_tmpdir();

    local_vault::set_pin("424242").expect("set_pin");
    local_vault::lock();

    // Первые 5 неудач — без задержки (политика §7.2).
    for i in 1..=5 {
        let err = local_vault::unlock("000000").unwrap_err();
        assert!(err.to_string().contains("wrong_pin"), "i={i} got: {err}");
        assert_eq!(
            local_vault::lockout_remaining_secs().unwrap(),
            0,
            "should not be locked out yet at attempt {i}"
        );
    }

    // 6-я неудача — должен включиться lockout на 30s.
    let err = local_vault::unlock("000000").unwrap_err();
    assert!(err.to_string().contains("wrong_pin"));
    let remaining = local_vault::lockout_remaining_secs().unwrap();
    assert!(
        (25..=30).contains(&remaining),
        "expected ~30s lockout, got {remaining}"
    );

    // Попытка с верным PIN'ом во время lockout — должна получить locked_out.
    let err = local_vault::unlock("424242").unwrap_err();
    assert!(err.to_string().contains("locked_out"), "got: {err}");
}

#[test]
fn change_pin_rekey_full_flow() {
    let _g = TEST_MUTEX.lock().unwrap();
    let tmp = init_clean_tmpdir();

    // Установить старый PIN, написать два JSON-файла под vault.
    paranoia_lib::local_vault::set_pin("oldpin12").expect("set old");
    let f1 = tmp.path().join("profiles.json");
    let f2 = tmp.path().join("device_key.json");
    encrypt_json_to_disk(&f1, br#"{"v":1,"profiles":["aaa"]}"#).unwrap();
    encrypt_json_to_disk(&f2, br#"{"v":1,"private_key_b64":"DEADBEEF"}"#).unwrap();

    // verify_pin: старый OK, неверный — wrong_pin.
    paranoia_lib::local_vault::verify_pin("oldpin12").expect("verify old ok");
    let err = paranoia_lib::local_vault::verify_pin("wrong").unwrap_err();
    assert!(err.to_string().contains("wrong_pin"));

    // Rekey flow: begin → file*2 → commit.
    paranoia_lib::local_vault::rekey_begin("newpin99").expect("rekey_begin");
    paranoia_lib::local_vault::rekey_file(&f1).expect("rekey f1");
    paranoia_lib::local_vault::rekey_file(&f2).expect("rekey f2");
    paranoia_lib::local_vault::rekey_commit().expect("rekey_commit");

    // Старый PIN больше не подходит, новый — да.
    let err = paranoia_lib::local_vault::verify_pin("oldpin12").unwrap_err();
    assert!(err.to_string().contains("wrong_pin"));
    paranoia_lib::local_vault::verify_pin("newpin99").expect("verify new ok");

    // Файлы читаются текущими (уже новыми) ключами.
    let d1 = decrypt_json_from_disk(&f1).expect("decrypt f1 new");
    assert_eq!(d1, br#"{"v":1,"profiles":["aaa"]}"#);
    let d2 = decrypt_json_from_disk(&f2).expect("decrypt f2 new");
    assert_eq!(d2, br#"{"v":1,"private_key_b64":"DEADBEEF"}"#);

    // После lock + unlock с новым PIN — всё работает.
    paranoia_lib::local_vault::lock();
    paranoia_lib::local_vault::unlock("newpin99").expect("unlock new");
    let d1b = decrypt_json_from_disk(&f1).expect("decrypt f1 again");
    assert_eq!(d1b, br#"{"v":1,"profiles":["aaa"]}"#);

    // Старый PIN на unlock даёт wrong_pin.
    paranoia_lib::local_vault::lock();
    let err = paranoia_lib::local_vault::unlock("oldpin12").unwrap_err();
    assert!(err.to_string().contains("wrong_pin"));
}

#[test]
fn attachments_encrypted_and_rekey_works() {
    let _g = TEST_MUTEX.lock().unwrap();
    let tmp = init_clean_tmpdir();

    paranoia_lib::local_vault::set_pin("pin-aaa").expect("set_pin");

    // Зашифровать вложение, проверить magic и невозможность найти plaintext.
    let msg_id = "msg-uuid-1";
    let plain = b"hello world attachment payload";
    let sealed = encrypt_attachment(msg_id.as_bytes(), plain).expect("encrypt");
    assert_eq!(&sealed[..4], b"PVL1");
    assert!(!sealed.windows(plain.len()).any(|w| w == plain),
            "sealed leaks plaintext");

    // Расшифровать обратно — байт-в-байт.
    let back = decrypt_attachment(msg_id.as_bytes(), &sealed).expect("decrypt");
    assert_eq!(back, plain);

    // Запишем .enc на диск и пройдём rekey.
    let enc_path = tmp.path().join("attach.enc");
    std::fs::write(&enc_path, &sealed).unwrap();

    paranoia_lib::local_vault::rekey_begin("pin-bbb").expect("rekey_begin");
    paranoia_lib::local_vault::rekey_attachment(msg_id.as_bytes(), &enc_path)
        .expect("rekey_attachment");
    paranoia_lib::local_vault::rekey_commit().expect("rekey_commit");

    // Файл на диске изменился (зашифрован на новом ключе).
    let after = std::fs::read(&enc_path).unwrap();
    assert_eq!(&after[..4], b"PVL1");
    assert_ne!(after, sealed, "rekey_attachment не перезашифровал файл");

    // Новый ключ должен расшифровать в исходный plaintext.
    let back2 = decrypt_attachment(msg_id.as_bytes(), &after).expect("decrypt new");
    assert_eq!(back2, plain);

    // Старый sealed-блоб новым ключом не открыть.
    assert!(decrypt_attachment(msg_id.as_bytes(), &sealed).is_err());
}

#[test]
fn rekey_abort_keeps_old_state() {
    let _g = TEST_MUTEX.lock().unwrap();
    let tmp = init_clean_tmpdir();

    paranoia_lib::local_vault::set_pin("pin11111").expect("set_pin");
    let f = tmp.path().join("data.json");
    encrypt_json_to_disk(&f, br#"{"v":1,"x":1}"#).unwrap();

    paranoia_lib::local_vault::rekey_begin("pin22222").expect("rekey_begin");
    // Не зовём rekey_file. Просто abort.
    paranoia_lib::local_vault::rekey_abort();

    // Старый PIN всё ещё работает.
    paranoia_lib::local_vault::verify_pin("pin11111").expect("old still ok");
    let err = paranoia_lib::local_vault::verify_pin("pin22222").unwrap_err();
    assert!(err.to_string().contains("wrong_pin"));
    // Файл читается старым ключом.
    let d = decrypt_json_from_disk(&f).unwrap();
    assert_eq!(d, br#"{"v":1,"x":1}"#);
}

/// Имитируем падение в середине rekey: rekey_file отработал по part'у файлов,
/// затем abort → файлы должны быть восстановлены под старым ключом.
#[test]
fn rekey_abort_after_partial_rewrite_restores_files() {
    let _g = TEST_MUTEX.lock().unwrap();
    let tmp = init_clean_tmpdir();

    paranoia_lib::local_vault::set_pin("oldoldold").expect("set_pin");
    let f1 = tmp.path().join("a.json");
    let f2 = tmp.path().join("b.json");
    encrypt_json_to_disk(&f1, br#"{"v":1,"a":1}"#).unwrap();
    encrypt_json_to_disk(&f2, br#"{"v":1,"b":2}"#).unwrap();
    let f1_before = std::fs::read(&f1).unwrap();
    let f2_before = std::fs::read(&f2).unwrap();

    paranoia_lib::local_vault::rekey_begin("newnewnew").expect("rekey_begin");
    paranoia_lib::local_vault::rekey_file(&f1).expect("rekey f1");
    // f2 НЕ перешифровали — имитация прерывания.
    paranoia_lib::local_vault::rekey_abort();

    // Старый PIN снова валиден (vault.json не менялся).
    paranoia_lib::local_vault::verify_pin("oldoldold").expect("old still ok");
    // f1 был перезаписан, но abort должен был его восстановить.
    let f1_after = std::fs::read(&f1).unwrap();
    let f2_after = std::fs::read(&f2).unwrap();
    assert_eq!(f1_after, f1_before, "rekey_abort не восстановил f1");
    assert_eq!(f2_after, f2_before, "f2 не должен был меняться");
    // Расшифровка под старым ключом всё ещё работает.
    let d1 = decrypt_json_from_disk(&f1).expect("decrypt f1 after abort");
    assert_eq!(d1, br#"{"v":1,"a":1}"#);
    let d2 = decrypt_json_from_disk(&f2).expect("decrypt f2 after abort");
    assert_eq!(d2, br#"{"v":1,"b":2}"#);
}

/// Имитируем SIGKILL: после rekey_file НЕ зовём ни commit, ни abort, просто
/// бросаем процесс — staging-каталог остаётся. recover_pending_rekey()
/// должен откатить файлы при следующем «старте» (= перезаход через set_app_data_root).
#[test]
fn recover_pending_rekey_restores_after_crash() {
    let _g = TEST_MUTEX.lock().unwrap();
    let tmp = init_clean_tmpdir();

    paranoia_lib::local_vault::set_pin("crash-old").expect("set_pin");
    let f = tmp.path().join("c.json");
    encrypt_json_to_disk(&f, br#"{"v":1,"c":3}"#).unwrap();
    let before = std::fs::read(&f).unwrap();

    paranoia_lib::local_vault::rekey_begin("crash-new").expect("rekey_begin");
    paranoia_lib::local_vault::rekey_file(&f).expect("rekey f");
    // SIGKILL: НЕ зовём ни commit, ни abort. Содержимое VAULT/PENDING в RAM
    // потеряется, но staging-каталог на диске останется.
    // Симулируем потерю in-memory состояния через локальный lock + drop PENDING.
    paranoia_lib::local_vault::lock();
    // Принудительно дропнем pending (как будто процесс умер): используем abort,
    // но БЕЗ восстановления — для теста переименуем staging, чтобы abort его не нашёл,
    // потом вернём имя обратно.
    let staging = tmp.path().join(".rekey-staging");
    let staging_park = tmp.path().join(".rekey-staging.park");
    std::fs::rename(&staging, &staging_park).expect("park staging");
    paranoia_lib::local_vault::rekey_abort(); // дропает PENDING, но staging уже скрыт
    std::fs::rename(&staging_park, &staging).expect("unpark staging");

    // Файл сейчас под НОВЫМ ключом, vault.json — под старым. Это inconsistent state.
    let mid = std::fs::read(&f).unwrap();
    assert_ne!(mid, before, "файл должен быть перезаписан под новым ключом");

    // «Перезапуск»: повторно set_app_data_root триггерит recover_pending_rekey.
    // В FFI это автоматическая часть paranoia_vault_init. В тестах вызовем явно.
    paranoia_lib::local_vault::recover_pending_rekey().expect("recover");

    // Staging должен исчезнуть.
    assert!(!staging.exists(), "staging должен быть удалён после recover");

    // Файл восстановлен под старым ключом.
    let after = std::fs::read(&f).unwrap();
    assert_eq!(after, before, "recover не восстановил файл");

    // unlock со старым PIN — работает.
    paranoia_lib::local_vault::unlock("crash-old").expect("unlock old after recover");
    let d = decrypt_json_from_disk(&f).expect("decrypt");
    assert_eq!(d, br#"{"v":1,"c":3}"#);
}

