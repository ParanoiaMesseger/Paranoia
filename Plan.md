# Plan.md — текущая ветка testBranch

## Статус входных данных

- Исходный `Plan.md` в рабочем дереве и истории текущей ветки не найден.
- Зафиксированные ответы на опросник взяты из `ExportKeyring.md`.
- Криптографическая модель не изменялась: ECIES export остаётся `ephemeral X25519 ECDH + HKDF-SHA256 + ChaCha20-Poly1305`, wire-format сообщений, подписи, `PacketInner`, `dialogue_id:seq` и серверный API не менялись.

## Выполнено в этой итерации

- Реализован первый проход по ответам `Q1c/Q2c/Q3a` без изменения криптографической модели сообщений и export-контейнера:
  - UI backend перешёл на profile-scoped storage для `server+username`: `profiles/<profile_id>/client.json`, `profiles/<profile_id>/dialogs.json`, `profiles/<profile_id>/paranoia.db` и `profiles.json` manifest;
  - legacy `client.json`/`dialogs.json` мигрируются лениво при первом успешном login;
  - импорт client-профиля больше не ограничен активной совпадающей сессией и создаёт/обновляет отдельный profile по `server+username`;
  - конфликтующий keyring entry с тем же `start_seq`, но другим ключом не перезаписывается и учитывается в `conflicts`;
  - import payload ограничен 16 MiB, 16 client profiles, 16 admin profiles, 1024 dialogues и 8192 keyring entries;
  - private user/admin keys явно проверяются как base64(32 bytes) до сохранения;
  - добавлены backend методы `getClientProfiles()` и `switchClientProfile()` для следующего UI шага выбора профиля;
  - в UI export/import добавлен native file picker для выбора export/import path;
  - импорт показывает количество импортированных профилей, диалогов, ключей, admin-серверов, skipped entries и conflicts.
- Добавлены CLI-команды для full profile export/import:
  - `device-key show` генерирует/показывает X25519 public key принимающего устройства;
  - `export --profile client|admin|full --username ... --peer ... --receiver-pub ... --out ...` создаёт ECIES JSON envelope;
  - `import --file ...` расшифровывает envelope локальным `DEVICE_KEY`, валидирует payload и merge-ит client keyring по `server+username+peer+start_seq`;
  - CLI dialogue store стал profile-aware, при этом legacy `peer -> session_key_hex` остаётся fallback;
  - импортированные CLI profile signing keys сохраняются как PIN-encrypted ciphertext в owner-only `~/.paranoia_dialogues.json`, а не открытым текстом.
- В `ParanoiaLibrary/src/export.rs` добавлена переиспользуемая `validate_export_payload()` с unit-тестами.
- Выполнены проверки:
  - `cargo test --manifest-path ParanoiaLibrary/Cargo.toml export::tests`;
  - `cargo build --manifest-path ParanoiaEasyCli/Cargo.toml`;
  - `cmake --build ParanoiaUiClient/build/linux-debug --target appParanoiaUiClient`.
- Комиты текущей итерации:
  - `a7cbb07 CLI: добавляет export/import профилей`;
  - `2a7ed88 UI: добавляет multi-profile import`;
  - `00939d8 CLI: шифрует профильные signing keys`.

## Дальнейший план

1. Завершить UX multi-profile storage.
   - Добавить видимый selector профилей в UI: список `server+username`, активный профиль, переключение через `switchClientProfile()`.
   - Добавить явное подтверждение перед восстановлением client private signing key из export payload на чистом устройстве.
   - Показать предупреждение, что local profile storage содержит приватные ключи и требует защиты устройства/диска.

2. Свести UI и CLI validation/merge в одну реализацию.
   - Вынести merge/conflict keyring logic из UI/CLI в Rust library helper, чтобы исключить расхождение поведения.
   - Добавить FFI для `validate_export_payload()` или отдельного `import preview`.
   - Возвращать одинаковый отчёт: profiles/dialogues/key_entries/admin_servers/skipped/conflicts.

3. Довести CLI profile UX.
   - Добавить `profiles list` и `profiles use` либо явные `--server-url --username` подсказки после import.
   - Добавить `device-key rotate` только после отдельного решения о миграции export-получателей.
   - Документировать, что CLI admin import сейчас активирует admin key только для `--server-url`.

4. Добавить тесты на новые ветки.
   - Unit/FFI тесты validation limits: слишком много profiles/dialogues/keyring entries, invalid base64 private keys, duplicate `start_seq`.
   - Backend/unit тесты merge conflict для одинакового `start_seq` с другим ключом.
   - UI smoke test выбора subset диалогов и native file picker, если доступен test harness.

5. Подготовить документацию пользователя.
   - Кратко описать transfer flow: device public key -> export -> import -> delete export file.
   - Явно указать, что удаление export-файла не является secure delete.
   - Добавить раздел про перенос полного keyring при ротации ключей диалога.

## Опросник перед следующими изменениями

### Q1. Как импортировать client-профиль на чистом устройстве?

- [ ] **Q1a. Только в уже активную совпадающую сессию** — текущий самый консервативный режим: импортируются только keyring entries для текущих `server+username`.
- [ ] **Q1b. Восстанавливать `client.json` из export-файла при отсутствии активной сессии** — удобно для переноса на новое устройство, но нужно явное подтверждение пользователя перед сохранением private signing key.
- [+] **Q1c. Делать полноценный multi-profile storage** — несколько `server+username` профилей на одном устройстве, дольше в реализации.

### Q2. Какой объём CLI export/import нужен первым?

- [ ] **Q2a. Только device public key и ECIES decrypt/encrypt smoke commands** — минимальная диагностика.
- [ ] **Q2b. Client-only export/import selected dialogues** — перенос обычного пользователя.
- [+] **Q2c. Full profile export/import** — client/admin/full как в UI.

### Q3. Нужно ли ограничивать размер export-файла строже текущего лимита 16 MiB?

- [+] **Q3a. Оставить 16 MiB** — достаточно для текущего JSON keyring/profile payload.
- [ ] **Q3b. Уменьшить до 4 MiB** — меньше риск accidental large-file import, но хуже для больших keyring.
- [ ] **Q3c. Сделать лимит настраиваемым** — гибче, но добавляет настройку и UX.

### Q4. Какой UI для multi-profile нужен первым?

- [ ] **Q4a. Минимальный selector в текущем MainPage** — список профилей и кнопка переключения, быстрее всего.
- [ ] **Q4b. Отдельная страница управления профилями** — список, переключение, удаление локального профиля, лучше UX.
- [ ] **Q4c. Автологин в последний профиль без отдельного UI** — текущий backend уже близок, но multi-profile почти невидим пользователю.

### Q5. Как подтверждать восстановление client private signing key из export payload?

- [ ] **Q5a. Одно подтверждение перед импортом всего client/full payload** — проще, но меньше детализации.
- [ ] **Q5b. Подтверждение по каждому новому `server+username` профилю** — безопаснее для multi-profile import.
- [ ] **Q5c. Preview-only перед import** — сначала показать profiles/dialogues/admin keys, затем отдельная кнопка `Import`.

### Q6. Нужно ли менять локальную защиту UI `client.json`/`dialogs.json`?

- [ ] **Q6a. Оставить owner-only permissions как сейчас** — соответствует текущей desktop-модели и быстрее.
- [ ] **Q6b. Шифровать локальные profile files PIN/passphrase** — сильнее защищает при утечке файлов, но это уже отдельное изменение локальной security-модели и требует отдельного решения.
- [ ] **Q6c. Использовать OS keychain/keystore** — лучше UX, но требует платформенной реализации.
