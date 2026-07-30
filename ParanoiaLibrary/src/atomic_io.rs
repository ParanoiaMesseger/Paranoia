//! Единый атомарный файловый writer для всего крейта (03#26).
//!
//! Раньше семантика «tmp + rename» была реализована независимо в пяти местах
//! (`dialogue.rs`, `local_vault/{io,vault,state}.rs`, `ffi.rs`): часть — с
//! фиксированным `{name}.tmp` (конкурентные писатели затирали tmp друг друга), а
//! `dialogue.rs` делал ещё и remove-перед-rename — неатомарное окно, теряющее цель
//! при падении между remove и rename. Здесь один безопасный вариант: уникальный
//! uuid-tmp рядом с целью + чистый rename. `std::fs::rename` и на POSIX, и на
//! Windows (там std использует `MoveFileEx` с `REPLACE_EXISTING`) атомарно
//! заменяет существующий файл, поэтому remove не нужен.

use anyhow::Result;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// Создать родительские каталоги цели (если путь их задаёт).
pub(crate) fn ensure_parent_dir(path: &Path) -> Result<()> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)?;
    }
    Ok(())
}

/// Уникальный временный путь рядом с целью: `.{имя}.{uuid}.part`. Uuid делает имя
/// неконфликтующим при параллельных писателях (в отличие от фиксированного `.tmp`).
pub(crate) fn temporary_output_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("output.bin");
    path.with_file_name(format!(".{file_name}.{}.part", Uuid::new_v4()))
}

/// Атомарно заменить `target` уже записанным `temp_path` одним rename — без
/// remove-перед-rename: rename атомарно перезаписывает существующий файл, а remove
/// создавал бы окно, где при падении между remove и rename цель терялась (03#26).
pub(crate) fn replace_file(temp_path: &Path, target: &Path) -> Result<()> {
    fs::rename(temp_path, target)?;
    Ok(())
}

/// Атомарно записать `data` в `path`: uuid-tmp → запись → rename поверх цели.
/// tmp подчищается при ошибке.
pub(crate) fn write_bytes_atomic(path: &Path, data: &[u8]) -> Result<()> {
    ensure_parent_dir(path)?;
    let temp_path = temporary_output_path(path);
    let result = (|| {
        fs::write(&temp_path, data)?;
        replace_file(&temp_path, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

/// Атомарно скопировать `source` в `target` через uuid-tmp + rename.
pub(crate) fn copy_file(source: &Path, target: &Path) -> Result<()> {
    if source == target {
        return Ok(());
    }
    ensure_parent_dir(target)?;
    let temp_path = temporary_output_path(target);
    let result = (|| {
        fs::copy(source, &temp_path)?;
        replace_file(&temp_path, target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}
