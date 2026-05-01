# Plan.md — текущая ветка testBranch

## Статус входных данных

- Исходный `Plan.md` в рабочем дереве и истории текущей ветки не найден.
- Зафиксированные ответы на опросник взяты из `ExportKeyring.md`.
- Криптографическая модель не изменялась: ECIES export остаётся `ephemeral X25519 ECDH + HKDF-SHA256 + ChaCha20-Poly1305`, wire-format сообщений, подписи, `PacketInner`, `dialogue_id:seq` и серверный API не менялись.

## Выполнено в этой итерации

- UI export/import приведён ближе к решениям `X1c/X2c/Y1c/Z1a/Z2a/Z3b`:
  - экспорт поддерживает явный выбор диалогов, а не только неявный экспорт всех;
  - backend валидирует тип профиля `client/admin/full`;
  - импорт keyring не перезаписывает конфликтующий ключ при совпадающем `start_seq`, а возвращает счётчик конфликтов;
  - импорт показывает количество импортированных ключей, пропущенных записей и конфликтов;
  - удаление export-файла перенесено в backend вместо хрупкого QML-вызова;
  - локальный `device_key.json` и export-файл получают owner-only permissions, где это поддерживает ОС.
- Создан каталог `docs/` с PlantUML-диаграммами протоколов:
  - `docs/registration.puml`;
  - `docs/message-protocols.puml`;
  - `docs/qr-json-key-exchange.puml`;
  - `docs/export-import-keyring.puml`;
  - `docs/cover-layer.puml`.

## Дальнейший план

1. Довести импорт client-профиля на новое устройство.
   - Сейчас импорт keyring выполняется только для активной локальной сессии с тем же `server+username`.
   - Следующий безопасный шаг: добавить явное подтверждение восстановления `client.json` из `signing_key_b64`, если активной сессии нет.

2. Добавить CLI-команды для device/export/import.
   - `device-key show` для публичного ключа принимающего устройства.
   - `export --profile client|admin|full --peer ... --receiver-pub ... --out ...`.
   - `import --file ...` с теми же правилами merge/conflict, что в UI.

3. Усилить валидацию export payload.
   - Ограничить количество серверов, диалогов и keyring entries на импорт.
   - Явно проверять base64 private/admin keys до сохранения.
   - Возвращать пользователю детальный отчёт по skipped/conflict entries.

4. Улучшить UX файлов.
   - Добавить native file picker для выбора export/import path.
   - Оставить предупреждение, что удаление файла после импорта не является secure delete.

5. Добавить тесты.
   - Unit/FFI тесты conflict merge для одинакового `start_seq` с разным ключом.
   - UI/backend тесты для выбора subset диалогов при экспорте.

## Опросник перед следующими изменениями

### Q1. Как импортировать client-профиль на чистом устройстве?

- [ ] **Q1a. Только в уже активную совпадающую сессию** — текущий самый консервативный режим: импортируются только keyring entries для текущих `server+username`.
- [ ] **Q1b. Восстанавливать `client.json` из export-файла при отсутствии активной сессии** — удобно для переноса на новое устройство, но нужно явное подтверждение пользователя перед сохранением private signing key.
- [ ] **Q1c. Делать полноценный multi-profile storage** — несколько `server+username` профилей на одном устройстве, дольше в реализации.

### Q2. Какой объём CLI export/import нужен первым?

- [ ] **Q2a. Только device public key и ECIES decrypt/encrypt smoke commands** — минимальная диагностика.
- [ ] **Q2b. Client-only export/import selected dialogues** — перенос обычного пользователя.
- [ ] **Q2c. Full profile export/import** — client/admin/full как в UI.

### Q3. Нужно ли ограничивать размер export-файла строже текущего лимита 16 MiB?

- [ ] **Q3a. Оставить 16 MiB** — достаточно для текущего JSON keyring/profile payload.
- [ ] **Q3b. Уменьшить до 4 MiB** — меньше риск accidental large-file import, но хуже для больших keyring.
- [ ] **Q3c. Сделать лимит настраиваемым** — гибче, но добавляет настройку и UX.
