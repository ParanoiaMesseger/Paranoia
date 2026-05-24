//! Глобальный держатель master_key. Подключи живут только в RAM.
//! Никакого прямого доступа извне: только closure-API `with_*_key`.

use anyhow::{anyhow, bail, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::{atomic::{AtomicBool, Ordering}, Mutex, RwLock},
};
use zeroize::Zeroizing;

use super::{
    crypto::{self, KEY_LEN},
    state::{self, VaultState},
};

/// Каталог, куда складываются резервные копии исходных (старо-зашифрованных)
/// файлов на время rekey. Существование каталога ПОСЛЕ перезапуска процесса —
/// сигнал «rekey был прерван»; восстановление выполняет [`recover_pending_rekey`].
const STAGING_DIR: &str = ".rekey-staging";
const STAGING_MANIFEST: &str = "manifest.json";
const STAGING_BACKUPS_SUBDIR: &str = "backups";

#[derive(Serialize, Deserialize, Clone)]
struct RekeyEntry {
    orig: String,
    backup: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct RekeyManifest {
    v: u32,
    /// Целевая соль (vault.json после commit будет иметь именно её). На старте
    /// сравниваем с фактической: если совпадает — commit прошёл, нужна только
    /// очистка staging. Если не совпадает — rekey не доехал, восстанавливаем.
    new_salt_b64: String,
    entries: Vec<RekeyEntry>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VaultStatus {
    NotInitialized = 0,
    Locked = 1,
    Unlocked = 2,
}

/// Ключи в Box, не на стеке: при move структуры ActiveVault между владельцами
/// (например, при rekey_commit) heap-аллокация Box'а не меняет адрес. Это
/// необходимо чтобы mlock, выставленный после Box::new, продолжал защищать
/// именно те страницы памяти, где живёт ключ.
struct ActiveVault {
    /// Корень app-data — нужен для перезаписи vault.json после изменения lockout.
    app_data_root: PathBuf,
    /// Подключи (master не нужен после деривации — храним только производные).
    json_key: Box<Zeroizing<[u8; KEY_LEN]>>,
    db_key: Box<Zeroizing<[u8; KEY_LEN]>>,
    files_key: Box<Zeroizing<[u8; KEY_LEN]>>,
}

static VAULT: RwLock<Option<ActiveVault>> = RwLock::new(None);
/// Путь app-data для случая когда vault locked, но нужно вычитать VaultState
/// (lockout state, status и т.д.). Устанавливается из FFI на старте.
static APP_DATA_ROOT: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Pending-ключи для транзакционного rekey. Активный vault остаётся
/// разблокированным со старыми ключами; пока идёт rekey — каждый файл/БД
/// читаем активным, пишем pending. На commit — свап.
struct PendingVault {
    new_salt: [u8; super::crypto::SALT_LEN],
    json_key: Box<Zeroizing<[u8; KEY_LEN]>>,
    db_key: Box<Zeroizing<[u8; KEY_LEN]>>,
    files_key: Box<Zeroizing<[u8; KEY_LEN]>>,
    /// Корень staging-каталога. На abort: восстанавливаем из бэкапов и удаляем.
    /// На commit: удаляем после успешной записи vault.json.
    staging_dir: PathBuf,
    /// Манифест — что куда сохранено. Хранится и на диске (для recovery после
    /// SIGKILL), и в памяти (быстрая запись новых entries без re-read).
    manifest: Mutex<RekeyManifest>,
}

static PENDING: RwLock<Option<PendingVault>> = RwLock::new(None);

/// «Полная блокировка до перезапуска» (политика §7.2 пункт «>20 попыток»):
/// держим in-memory флаг, не персистим в vault.json. Сбрасывается при
/// перезапуске процесса (что и означает «до перезапуска»).
static EXHAUSTED_UNTIL_RESTART: AtomicBool = AtomicBool::new(false);

fn is_exhausted() -> bool { EXHAUSTED_UNTIL_RESTART.load(Ordering::SeqCst) }
fn set_exhausted() { EXHAUSTED_UNTIL_RESTART.store(true, Ordering::SeqCst); }
fn reset_exhausted() { EXHAUSTED_UNTIL_RESTART.store(false, Ordering::SeqCst); }

pub fn set_app_data_root(path: PathBuf) {
    *APP_DATA_ROOT.write().unwrap() = Some(path);
}

fn app_data_root() -> Result<PathBuf> {
    APP_DATA_ROOT
        .read()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("vault: app_data_root not set; call paranoia_vault_init first"))
}

pub fn status() -> Result<VaultStatus> {
    if VAULT.read().unwrap().is_some() {
        return Ok(VaultStatus::Unlocked);
    }
    let root = app_data_root()?;
    match VaultState::load(&root)? {
        Some(_) => Ok(VaultStatus::Locked),
        None => Ok(VaultStatus::NotInitialized),
    }
}

/// Установить PIN первый раз. Падает если vault уже инициализирован.
pub fn set_pin(pin: &str) -> Result<()> {
    if pin.is_empty() {
        bail!("vault: pin must not be empty");
    }
    let root = app_data_root()?;
    if VaultState::load(&root)?.is_some() {
        bail!("vault: already initialized — use change_pin");
    }
    let (state, master) = state::fresh_state(pin)?;
    state.save_atomic(&root)?;
    install_master(&root, &master)?;
    Ok(())
}

/// Применить результат неудачной попытки к state (увеличить счётчик и выставить
/// lockout). Возвращает true если активирован "exhausted until restart".
fn apply_failed_attempt(state: &mut VaultState) -> bool {
    state.failed_count = state.failed_count.saturating_add(1);
    match state::lockout_for_failures(state.failed_count) {
        state::LockoutAction::None => {
            state.lockout_until = None;
            false
        }
        state::LockoutAction::For(secs) => {
            state.lockout_until = Some(
                Utc::now() + chrono::Duration::seconds(secs as i64),
            );
            false
        }
        state::LockoutAction::ExhaustedUntilRestart => {
            // НЕ персистим 100 лет в vault.json — это сделало бы lockout
            // фактически permanent через рестарт. Держим in-memory флаг.
            // lockout_until НЕ ставим (или сбрасываем, чтобы при рестарте
            // юзер мог снова пытаться).
            state.lockout_until = None;
            set_exhausted();
            true
        }
    }
}

/// Разблокировать существующий vault. Коды ошибок:
///  - "wrong_pin": PIN неверный (verifier не расшифровался).
///  - "locked_out": активна задержка — см. `lockout_remaining_secs`.
///  - "not_initialized": vault.json отсутствует.
pub fn unlock(pin: &str) -> Result<()> {
    let root = app_data_root()?;
    let Some(mut state) = VaultState::load(&root)? else {
        bail!("not_initialized");
    };

    if is_exhausted() {
        bail!("locked_out");
    }
    let remaining = state::lockout_remaining(&state);
    if remaining > 0 {
        bail!("locked_out");
    }

    match state::verify_pin(&state, pin) {
        Ok(master) => {
            state.failed_count = 0;
            state.lockout_until = None;
            state.save_atomic(&root)?;
            reset_exhausted();
            install_master(&root, &master)?;
            Ok(())
        }
        Err(_) => {
            apply_failed_attempt(&mut state);
            state.save_atomic(&root)?;
            bail!("wrong_pin");
        }
    }
}

pub fn lock() {
    let mut guard = VAULT.write().unwrap();
    *guard = None;
}

pub fn lockout_remaining_secs() -> Result<u64> {
    if is_exhausted() {
        return Ok(u64::MAX);
    }
    let root = app_data_root()?;
    Ok(VaultState::load(&root)?
        .map(|s| state::lockout_remaining(&s))
        .unwrap_or(0))
}

/// Проверка PIN (без замены активных ключей). Обязана соблюдать ту же политику
/// rate-limit'а, что и unlock: иначе через verify_pin (используемый в
/// change-PIN flow) можно обходить lockout — brute-force без задержек.
pub fn verify_pin(pin: &str) -> Result<()> {
    let root = app_data_root()?;
    let Some(mut state) = VaultState::load(&root)? else {
        bail!("not_initialized");
    };
    if is_exhausted() {
        bail!("locked_out");
    }
    if state::lockout_remaining(&state) > 0 {
        bail!("locked_out");
    }
    match state::verify_pin(&state, pin) {
        Ok(_master) => {
            // Успешная проверка PIN — сбрасываем счётчик, как и unlock.
            state.failed_count = 0;
            state.lockout_until = None;
            state.save_atomic(&root)?;
            reset_exhausted();
            Ok(())
        }
        Err(_) => {
            apply_failed_attempt(&mut state);
            state.save_atomic(&root)?;
            bail!("wrong_pin");
        }
    }
}

// ── Транзакционный rekey ─────────────────────────────────────────────────────

/// Шаг 1: подготовить новые ключи (из нового PIN'а и новой соли).
/// Активный vault остаётся unlocked со СТАРЫМИ ключами.
/// На время rekey'а pending хранит новые ключи; commit/abort их освобождает.
pub fn rekey_begin(new_pin: &str) -> Result<()> {
    if new_pin.is_empty() {
        bail!("vault: pin must not be empty");
    }
    if !is_unlocked() {
        bail!("vault_locked");
    }
    if PENDING.read().unwrap().is_some() {
        bail!("rekey already in progress — call commit or abort first");
    }
    let root = app_data_root()?;
    let staging = root.join(STAGING_DIR);
    if staging.exists() {
        // Не должно случаться: recover_pending_rekey() обязан был отработать
        // при инициализации vault. Если попали сюда — лучше явный fail, чем
        // тихо смешать чужие бэкапы с новой попыткой rekey.
        bail!(
            "rekey staging already exists at {:?} — call recover_pending_rekey first",
            staging
        );
    }
    std::fs::create_dir_all(staging.join(STAGING_BACKUPS_SUBDIR))?;

    let mut new_salt = [0u8; crypto::SALT_LEN];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut new_salt);
    let new_master = crypto::derive_master(new_pin, &new_salt)?;
    // Box даёт стабильный heap-адрес: mlock'нутые страницы продолжат защищать
    // именно эти байты после move в PENDING.
    let json_key  = Box::new(crypto::derive_subkey(&new_master, crypto::HKDF_INFO_JSON));
    let db_key    = Box::new(crypto::derive_subkey(&new_master, crypto::HKDF_INFO_DB));
    let files_key = Box::new(crypto::derive_subkey(&new_master, crypto::HKDF_INFO_FILES));
    // &** : Box deref → Zeroizing deref → &[u8;KEY_LEN]. Адрес heap-страницы.
    mlock_best_effort(&**json_key);
    mlock_best_effort(&**db_key);
    mlock_best_effort(&**files_key);

    let manifest = RekeyManifest {
        v: 1,
        new_salt_b64: B64.encode(new_salt),
        entries: Vec::new(),
    };
    save_manifest(&staging, &manifest)?;

    *PENDING.write().unwrap() = Some(PendingVault {
        new_salt,
        json_key,
        db_key,
        files_key,
        staging_dir: staging,
        manifest: Mutex::new(manifest),
    });
    Ok(())
}

fn save_manifest(staging: &Path, manifest: &RekeyManifest) -> Result<()> {
    let path = staging.join(STAGING_MANIFEST);
    let tmp = staging.join(format!("{}.tmp", STAGING_MANIFEST));
    let bytes = serde_json::to_vec(manifest)?;
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

fn backup_filename_for(path: &Path) -> String {
    // sha256(абсолютного пути) даёт стабильное имя файла бэкапа: один и тот же
    // orig всегда мапится в один backup → повторный rekey_file/rekey_db по
    // тому же пути не плодит мусор.
    let mut h = Sha256::new();
    h.update(path.to_string_lossy().as_bytes());
    let digest = h.finalize();
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    format!("{hex}.bin")
}

/// Скопировать исходный файл в staging и зафиксировать (orig, backup) в манифесте.
/// Должно вызываться ДО любого in-place изменения `path`. Идемпотентно для
/// одного и того же `path`: повторные вызовы перезаписывают тот же backup.
fn stage_backup(pending: &PendingVault, path: &Path) -> Result<()> {
    if !path.exists() {
        // Нечего бэкапить (например, attachment-cache может быть пустым) —
        // запишем «пустой» entry, чтобы recovery просто удалил orig при
        // откате (он был создан после rekey_begin).
        let mut m = pending.manifest.lock().unwrap();
        if !m.entries.iter().any(|e| Path::new(&e.orig) == path) {
            m.entries.push(RekeyEntry {
                orig: path.to_string_lossy().to_string(),
                backup: String::new(),
            });
            save_manifest(&pending.staging_dir, &m)?;
        }
        return Ok(());
    }
    let backup_name = backup_filename_for(path);
    let backup_path = pending
        .staging_dir
        .join(STAGING_BACKUPS_SUBDIR)
        .join(&backup_name);
    // Сначала пишем .tmp + rename, чтобы прерывание не оставило половинный backup.
    let tmp = pending
        .staging_dir
        .join(STAGING_BACKUPS_SUBDIR)
        .join(format!("{backup_name}.tmp"));
    std::fs::copy(path, &tmp)?;
    std::fs::rename(&tmp, &backup_path)?;
    // Только теперь фиксируем в манифесте.
    let mut m = pending.manifest.lock().unwrap();
    let backup_str = backup_path.to_string_lossy().to_string();
    let orig_str = path.to_string_lossy().to_string();
    if let Some(existing) = m.entries.iter_mut().find(|e| e.orig == orig_str) {
        existing.backup = backup_str;
    } else {
        m.entries.push(RekeyEntry {
            orig: orig_str,
            backup: backup_str,
        });
    }
    save_manifest(&pending.staging_dir, &m)?;
    Ok(())
}

/// Шаг 2 (для каждого vault-protected файла): прочитать со старым json_key,
/// записать с новым json_key атомарно in-place.
/// СНАЧАЛА копирует оригинал в staging (для rollback на abort/crash), затем
/// делает in-place перешифровку.
pub fn rekey_file(path: &Path) -> Result<()> {
    let pending_guard = PENDING.read().unwrap();
    let pending = pending_guard.as_ref().ok_or_else(|| anyhow!("no_pending_rekey"))?;
    stage_backup(pending, path)?;
    // Расшифровать активным.
    let plaintext = super::io::decrypt_json_from_disk(path)?;
    // Зашифровать pending json_key (нам нужно собрать bytes с magic).
    let sealed = crypto::seal(&**pending.json_key, &plaintext)?;
    let mut out = Vec::with_capacity(4 + sealed.len());
    out.extend_from_slice(b"PVL1");
    out.extend_from_slice(&sealed);
    write_atomic_file(path, &out)?;
    Ok(())
}

/// Шаг 2 (для каждого зашифрованного attachment файла): decrypt активным
/// per-file ключом, encrypt новым. `salt` — то же значение, что использовалось
/// при первичном шифровании (обычно байты message_id).
pub fn rekey_attachment(salt: &[u8], path: &Path) -> Result<()> {
    let pending_guard = PENDING.read().unwrap();
    let pending = pending_guard.as_ref().ok_or_else(|| anyhow!("no_pending_rekey"))?;
    stage_backup(pending, path)?;
    // Decrypt активным files_key (через `super::io::decrypt_attachment`).
    let sealed = std::fs::read(path)?;
    let plaintext = super::io::decrypt_attachment(salt, &sealed)?;
    // Encrypt pending per-file key.
    let pending_file_key = crypto::derive_attachment_key(&**pending.files_key, salt);
    let new_sealed = crypto::seal(&pending_file_key, &plaintext)?;
    let mut out = Vec::with_capacity(4 + new_sealed.len());
    out.extend_from_slice(b"PVL1");
    out.extend_from_slice(&new_sealed);
    write_atomic_file(path, &out)?;
    Ok(())
}

/// Шаг 2 (для каждой SQLite базы): открыть со старым db_key, PRAGMA rekey
/// с новым. SQLCipher rekey НЕ атомарен относительно крэша — поэтому
/// бэкапим .db + .db-wal + .db-shm перед операцией.
pub fn rekey_db(db_path: &Path) -> Result<()> {
    let pending_guard = PENDING.read().unwrap();
    let pending = pending_guard.as_ref().ok_or_else(|| anyhow!("no_pending_rekey"))?;
    let active_guard = VAULT.read().unwrap();
    let active = active_guard.as_ref().ok_or_else(|| anyhow!("vault_locked"))?;

    // Бэкап .db + WAL/SHM при наличии. Делаем ДО открытия соединения, чтобы
    // PRAGMA rekey не успел частично изменить файл до бэкапа.
    stage_backup(pending, db_path)?;
    let db_str = db_path.to_string_lossy();
    let wal = PathBuf::from(format!("{}-wal", db_str));
    let shm = PathBuf::from(format!("{}-shm", db_str));
    if wal.exists() {
        stage_backup(pending, &wal)?;
    }
    if shm.exists() {
        stage_backup(pending, &shm)?;
    }

    use rusqlite::Connection;
    let conn = Connection::open(db_path)?;
    // cipher_* ДО key — те же параметры, что в LocalStore::open.
    conn.execute_batch(
        "PRAGMA cipher_page_size = 4096;\
         PRAGMA kdf_iter = 1;\
         PRAGMA cipher_hmac_algorithm = HMAC_SHA512;",
    )?;
    let old_key = format!("PRAGMA key = \"x'{}'\";", hex::encode(&**active.db_key));
    conn.execute_batch(&old_key)
        .map_err(|e| anyhow!("sqlcipher key (old): {e}"))?;
    // Проверяем — старый ключ должен подходить.
    conn.query_row("SELECT count(*) FROM sqlite_master;", [], |_| Ok(()))
        .map_err(|e| anyhow!("sqlcipher old key verify: {e}"))?;
    let new_key = format!("PRAGMA rekey = \"x'{}'\";", hex::encode(&**pending.db_key));
    conn.execute_batch(&new_key)
        .map_err(|e| anyhow!("sqlcipher rekey: {e}"))?;
    Ok(())
}

/// Шаг 3: записать новый VaultState (новая соль + verifier на новом json_key),
/// затем атомарно свапнуть активные ключи на pending.
/// ВАЖНО: save_atomic должен полностью завершиться УСПЕХОМ ДО того, как мы
/// заберём pending из Option. Иначе на ошибке save (disk full / SIGKILL после
/// записи .tmp) мы потеряем pending — vault.json остался со СТАРОЙ солью,
/// а все файлы уже перешифрованы НОВЫМ ключом → обе версии master потеряны.
pub fn rekey_commit() -> Result<()> {
    let root = app_data_root()?;
    // Verifier шифруется на НОВОМ json_key. Делаем это с pending в read-lock:
    // если потом save_atomic упадёт, pending остаётся в RwLock — оркестратор
    // может вызвать rekey_abort() (или просто решит retry).
    const VERIFIER_PT: &[u8] = b"{\"v\":1,\"verifier\":\"paranoia-vault-v1\"}";
    {
        let pending_guard = PENDING.read().unwrap();
        let pending = pending_guard.as_ref().ok_or_else(|| anyhow!("no_pending_rekey"))?;
        let verifier = crypto::seal(&**pending.json_key, VERIFIER_PT)?;
        let new_state = VaultState::new_fresh(&pending.new_salt, &verifier);
        // Атомарная запись vault.json. Если упадёт — pending остался, ключи целы.
        new_state.save_atomic(&root)?;
    }

    // save_atomic завершилось успешно. Теперь забираем pending и инсталлируем
    // как активный — этот шаг чисто in-memory, не может упасть.
    let pending = PENDING
        .write()
        .unwrap()
        .take()
        .ok_or_else(|| anyhow!("no_pending_rekey"))?;
    let staging = pending.staging_dir.clone();
    let mut active = VAULT.write().unwrap();
    *active = Some(ActiveVault {
        app_data_root: root,
        json_key: pending.json_key,
        db_key: pending.db_key,
        files_key: pending.files_key,
    });
    drop(active);
    // Staging больше не нужен — vault.json уже под новым ключом, файлы тоже.
    // Если удалить не получилось — это не data loss: recover_pending_rekey
    // при старте увидит совпадение new_salt с актуальной vault.salt и спокойно
    // удалит каталог.
    let _ = std::fs::remove_dir_all(&staging);
    Ok(())
}

/// Откатить rekey: восстановить файлы из бэкапов, выбросить pending-ключи,
/// удалить staging. Безопасно вызывать после ЛЮБОГО шага rekey_file/db/attachment
/// (или вообще без них). НЕ безопасно вызывать после успешного rekey_commit —
/// но к тому моменту pending уже взят .take()'ом, так что фактически no-op.
pub fn rekey_abort() {
    let Some(pending) = PENDING.write().unwrap().take() else {
        return;
    };
    restore_from_manifest(&pending.staging_dir);
    let _ = std::fs::remove_dir_all(&pending.staging_dir);
}

fn restore_from_manifest(staging_dir: &Path) {
    let manifest_path = staging_dir.join(STAGING_MANIFEST);
    let Ok(bytes) = std::fs::read(&manifest_path) else {
        return;
    };
    let Ok(manifest): Result<RekeyManifest, _> = serde_json::from_slice(&bytes) else {
        return;
    };
    // Восстанавливаем в обратном порядке: если какой-то путь упомянут дважды
    // (теоретически — не должен, имена уникальны через sha256), последняя
    // запись должна быть применена первой.
    for entry in manifest.entries.iter().rev() {
        let orig = PathBuf::from(&entry.orig);
        if entry.backup.is_empty() {
            // Файл изначально отсутствовал; rekey мог его создать. Удаляем.
            let _ = std::fs::remove_file(&orig);
            continue;
        }
        let backup = PathBuf::from(&entry.backup);
        if backup.exists() {
            // rename вместо copy: атомарный restore и backup исчезает.
            let _ = std::fs::rename(&backup, &orig);
        }
    }
}

/// Восстановление после прерванного rekey. Вызывается на старте процесса,
/// ДО любых попыток разблокировать vault. Идемпотентна.
///
/// Логика:
///  - нет `.rekey-staging/` → нечего делать.
///  - есть staging, нет манифеста → мусор (создан до записи манифеста),
///    просто удалить.
///  - есть staging + манифест:
///      - сравнить `manifest.new_salt` с фактической `vault.json.salt`:
///          - совпадают → rekey успел докатиться до save_atomic vault.json,
///            данные согласованы; staging — мусор, удаляем.
///          - НЕ совпадают (или vault.json отсутствует) → rekey прерван,
///            восстанавливаем файлы из бэкапов и удаляем staging.
pub fn recover_pending_rekey() -> Result<()> {
    let root = app_data_root()?;
    let staging = root.join(STAGING_DIR);
    if !staging.exists() {
        return Ok(());
    }
    let manifest_path = staging.join(STAGING_MANIFEST);
    if !manifest_path.exists() {
        let _ = std::fs::remove_dir_all(&staging);
        return Ok(());
    }
    let manifest: RekeyManifest =
        serde_json::from_slice(&std::fs::read(&manifest_path)?)?;

    let already_committed = match VaultState::load(&root)? {
        Some(s) => {
            // Сравниваем base64 как строку — он канонический для конкретной соли.
            s.salt_b64 == manifest.new_salt_b64
        }
        None => false,
    };

    if !already_committed {
        restore_from_manifest(&staging);
    }
    let _ = std::fs::remove_dir_all(&staging);
    Ok(())
}

fn write_atomic_file(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = match path.file_name() {
        Some(name) => path.with_file_name(format!("{}.tmp", name.to_string_lossy())),
        None => bail!("invalid path: {:?}", path),
    };
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn install_master(
    app_data_root: &Path,
    master: &Zeroizing<[u8; KEY_LEN]>,
) -> Result<()> {
    // Box на heap: mlock защищает стабильный адрес страниц после move в static.
    let json_key  = Box::new(crypto::derive_subkey(master, crypto::HKDF_INFO_JSON));
    let db_key    = Box::new(crypto::derive_subkey(master, crypto::HKDF_INFO_DB));
    let files_key = Box::new(crypto::derive_subkey(master, crypto::HKDF_INFO_FILES));

    mlock_best_effort(&**json_key);
    mlock_best_effort(&**db_key);
    mlock_best_effort(&**files_key);

    let mut guard = VAULT.write().unwrap();
    *guard = Some(ActiveVault {
        app_data_root: app_data_root.to_path_buf(),
        json_key,
        db_key,
        files_key,
    });
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn mlock_best_effort(buf: &[u8]) {
    unsafe {
        let _ = libc::mlock(buf.as_ptr() as *const libc::c_void, buf.len());
        // Игнорируем EPERM (RLIMIT_MEMLOCK) — best-effort.
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn mlock_best_effort(_buf: &[u8]) {
    // iOS/macOS/Windows: либо требует entitlements, либо отдельные API.
    // Согласно решению — no-op без ошибки.
}

/// Closure-API: ключ не покидает блок. Падает с ошибкой если vault locked.
pub fn with_json_key<R, F: FnOnce(&[u8; KEY_LEN]) -> R>(f: F) -> Result<R> {
    let guard = VAULT.read().unwrap();
    let v = guard.as_ref().ok_or_else(|| anyhow!("vault_locked"))?;
    Ok(f(&**v.json_key))
}

pub fn with_db_key<R, F: FnOnce(&[u8; KEY_LEN]) -> R>(f: F) -> Result<R> {
    let guard = VAULT.read().unwrap();
    let v = guard.as_ref().ok_or_else(|| anyhow!("vault_locked"))?;
    Ok(f(&**v.db_key))
}

pub fn with_files_key<R, F: FnOnce(&[u8; KEY_LEN]) -> R>(f: F) -> Result<R> {
    let guard = VAULT.read().unwrap();
    let v = guard.as_ref().ok_or_else(|| anyhow!("vault_locked"))?;
    Ok(f(&**v.files_key))
}

/// Проверка состояния без аллокаций — используется горячими путями IO.
pub fn is_unlocked() -> bool {
    VAULT.read().unwrap().is_some()
}

/// Текущий app_data_root активного vault (или из APP_DATA_ROOT, если locked).
pub fn current_root() -> Result<PathBuf> {
    if let Some(v) = VAULT.read().unwrap().as_ref() {
        return Ok(v.app_data_root.clone());
    }
    app_data_root()
}
