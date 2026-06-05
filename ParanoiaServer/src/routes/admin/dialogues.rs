//! Admin-операции над диалогами: перечисление и прунинг.

use super::{AdminEnvelope, Capability, err_json, verify};
use crate::{AppState, crypto};
use axum::{Json, extract::State};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use tracing::{info, warn};

/// `PUT /admin/dialogues/list` — перечислить диалоги хранилища `(id, last_seq)`.
pub async fn list(
    State(state): State<Arc<AppState>>,
    Json(env): Json<AdminEnvelope>,
) -> Json<Value> {
    if let Err(e) = verify(&state, &env, "list_dialogues", "", Capability::Extended).await {
        return err_json(&e);
    }
    match state.store.list_dialogues() {
        Ok(list) => {
            let count = list.len();
            let dialogues: Vec<Value> = list
                .into_iter()
                .map(|(id, last, bytes)| {
                    json!({ "dialogue_id": id, "last_seq": last, "total_bytes": bytes })
                })
                .collect();
            Json(json!({ "success": true, "count": count, "dialogues": dialogues }))
        }
        Err(e) => err_json(&format!("store_error: {e}")),
    }
}

/// `PUT /admin/dialogues/prune` — удалить диалоги, у которых хотя бы один
/// участник больше не зарегистрирован.
///
/// «Валидные» диалоги — все пары (и self-пары) зарегистрированных пользователей.
/// Любой `dialogue_id` в хранилище вне этого множества трактуется как диалог без
/// живого участника и удаляется целиком.
pub async fn prune(
    State(state): State<Arc<AppState>>,
    Json(env): Json<AdminEnvelope>,
) -> Json<Value> {
    if let Err(e) = verify(&state, &env, "prune", "", Capability::Extended).await {
        return err_json(&e);
    }

    let valid: HashSet<String> = {
        let cfg = state.config.read().await;
        let names: Vec<String> = cfg.users.keys().cloned().collect();
        valid_dialogue_ids(&names)
    };

    let all = match state.store.list_dialogues() {
        Ok(v) => v,
        Err(e) => return err_json(&format!("store_error: {e}")),
    };

    let mut pruned: Vec<String> = Vec::new();
    for (id, _last, _bytes) in all {
        if valid.contains(&id) {
            continue;
        }
        if let Err(e) = state.store.remove_range(&id, 0, u64::MAX) {
            warn!("Failed to prune dialogue {id}: {e}");
            continue;
        }
        pruned.push(id);
    }
    info!("Admin pruned {} orphan dialogue(s)", pruned.len());
    Json(json!({ "success": true, "pruned": pruned.len(), "pruned_ids": pruned }))
}

/// Множество «живых» dialogue_id для набора зарегистрированных пользователей:
/// все упорядоченные пары плюс self-диалоги.
fn valid_dialogue_ids(users: &[String]) -> HashSet<String> {
    let mut set = HashSet::new();
    for (i, a) in users.iter().enumerate() {
        set.insert(crypto::make_dialogue_id(a, a));
        for b in &users[i + 1..] {
            set.insert(crypto::make_dialogue_id(a, b));
        }
    }
    set
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orphan_dialogue_is_detected_when_participant_removed() {
        // Зарегистрированы только alice и bob; carol удалена.
        let users = vec!["alice".to_string(), "bob".to_string()];
        let valid = valid_dialogue_ids(&users);

        let alice_bob = crypto::make_dialogue_id("alice", "bob");
        let alice_carol = crypto::make_dialogue_id("alice", "carol");
        let alice_self = crypto::make_dialogue_id("alice", "alice");

        // Диалог двух живых участников и self-диалог — валидны.
        assert!(valid.contains(&alice_bob));
        assert!(valid.contains(&alice_self));
        // Диалог с удалённым участником — осиротевший (подлежит прунингу).
        assert!(!valid.contains(&alice_carol));
    }

    #[test]
    fn dialogue_id_is_symmetric() {
        let users = vec!["bob".to_string(), "alice".to_string()];
        let valid = valid_dialogue_ids(&users);
        // Порядок участников не важен — id симметричен.
        assert!(valid.contains(&crypto::make_dialogue_id("alice", "bob")));
        assert!(valid.contains(&crypto::make_dialogue_id("bob", "alice")));
    }
}
