# Disclaimer / Отказ от ответственности

## English

Paranoia is software distributed **as is** under the [MIT License](LICENSE), without
warranty of any kind. The license disclaims warranty; this document states the
intended use and the limits of what the software can do.

- **No technical measure provides safety by itself.** Encryption does not protect a
  compromised device, a weak PIN, leaked keys, or user error. The known limitations
  and residual risks are listed in [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md),
  section "Возможные угрозы" (Residual threats) — read it before relying on the
  software in any situation where the outcome matters.
- **The project operates no service.** There is no central server. Users deploy and
  administer their own instances and are solely responsible for operating them,
  including compliance with the law applicable to them.
- **Lawful use is the user's responsibility.** The project is not intended for
  unlawful activity and does not endorse it.
- **No guarantee of undetectability.** The cover layer raises the cost of detection;
  it does not make traffic indistinguishable, and it does not defeat metadata
  correlation or a long-running ML classifier.

See also [EXPORT_COMPLIANCE.md](EXPORT_COMPLIANCE.md) regarding cryptography export
regulations.

## Русский

Paranoia — программное обеспечение, распространяемое **«как есть»** по
[лицензии MIT](LICENSE), без каких-либо гарантий. Лицензия снимает гарантии
работоспособности; этот документ описывает назначение и границы возможностей.

- **Ни одна техническая мера не даёт безопасности сама по себе.** Шифрование не
  защищает скомпрометированное устройство, слабый PIN, утёкшие ключи и ошибки
  пользователя. Известные ограничения и остаточные риски перечислены в
  [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md), раздел «Возможные угрозы».
- **Проект не оказывает услуг связи.** Центрального сервера нет: пользователь сам
  разворачивает и администрирует свой сервер и несёт ответственность за его работу,
  включая соблюдение применимого к нему законодательства.
- **Законность использования — ответственность пользователя.** Проект не
  предназначен для противоправной деятельности и не поддерживает её.
- **Необнаружимость не гарантируется.** Cover-слой повышает стоимость детекции, но
  не делает трафик неотличимым и не защищает от корреляции метаданных и от
  ML-классификатора, обученного на длительном наблюдении.

См. также [EXPORT_COMPLIANCE.md](EXPORT_COMPLIANCE.md) о правилах экспорта криптографии.
