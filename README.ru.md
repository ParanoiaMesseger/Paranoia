<div align="center">

<img src="ParanoiaUiClient/resources/design/logo_lockup_animated.svg" alt="Paranoia" width="320">

# Paranoia

**Мессенджер со сквозным шифрованием, спроектированный против сильного нарушителя — цензора-провайдера, MITM и полностью скомпрометированного сервера.**

[![License: MIT](https://img.shields.io/badge/License-MIT-c91122.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/ParanoiaMesseger/Paranoia?color=c91122&label=release)](https://github.com/ParanoiaMesseger/Paranoia/releases/latest)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20Windows%20%7C%20macOS%20%7C%20Android%20%7C%20iOS-08070a.svg)](#установка)
[![Website](https://img.shields.io/badge/website-paranoia.run-c91122.svg)](https://paranoia.run/)

[English](README.md) · [Сайт](https://paranoia.run/) · [Скачать](https://github.com/ParanoiaMesseger/Paranoia/releases/latest) · [Модель безопасности](docs/SECURITY-MODEL.md)

</div>

---

## Что такое Paranoia

Paranoia — это защищённый мессенджер для мира, где нельзя доверять никому посередине: ни сети, ни серверу, ни даже центру сертификации. Сообщения шифруются сквозным образом на клиенте; сервер — это *zero-trust*-релей, который никогда не видит открытый текст, а даже полностью скомпрометированный сервер не может подделать, переиграть или незаметно переписать историю.

Помимо конфиденциальности, Paranoia делает упор на **скрытность**: служебный, административный и голосовой трафик заворачивается в маскировочный (cover) слой, так что для внешнего наблюдателя — включая DPI/ML-анализ — соединение выглядит как обычный HTTPS к обычному сайту.

> Полная модель угроз и обоснование решений: **[docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md)**.

## Ключевые возможности

- 🔒 **Сквозное шифрование** — содержимое недоступно ни серверу, ни MITM на уровне транспорта.
- 🕵️ **Маскировка трафика (cover-слой)** — служебный/админский/VoIP-трафик скрыт в едином cover-туннеле под обычный веб-трафик.
- 🧱 **Zero-trust сервер** — скомпрометированному серверу достаётся только шифртекст; он не может вставить или изменить сообщения.
- ✍️ **Целостность и аутентичность** — каждое сообщение подписано; сервер не может сфабриковать историю от имени пользователя.
- 🗑️ **Право на забвение** — пользователь может инициировать удаление своих данных с сервера.
- 🛰️ **Сопротивление цензуре** — резервные адреса сервера, маскировка под сайт, раздача через CDN.
- 📞 **Защищённые звонки** — шифрованный VoIP с фолбэком через TURN.
- 🌍 **Кроссплатформенность** — Linux, Windows, macOS, Android, iOS из единой кодовой базы Qt/QML.

## Установка

Свежие установщики и бинарники — на **[странице релизов](https://github.com/ParanoiaMesseger/Paranoia/releases/latest)**:

| Платформа | Файл |
|---|---|
| Linux (x86_64) | `paranoia-linux-x86_64.deb` |
| Windows | `paranoia-windows-x86_64-installer.exe` |
| macOS (arm64) | `paranoia-macos-arm64.dmg` |
| Android | `paranoia-android-arm64.apk` |
| iOS | `paranoia-ios-arm64.ipa` |
| Сервер | `paranoia-amd64` · `paranoia-arm64` · `paranoia-armhf` |

Десктоп- и мобильные приложения также сами проверяют и устанавливают обновления из этих релизов.

## Архитектура

Paranoia разделён на независимые компоненты:

| Компонент | Язык | Роль |
|---|---|---|
| [`ParanoiaServer`](ParanoiaServer) | Rust | Zero-trust релей-сервер (хранит только шифртекст + метаданные) |
| [`ParanoiaLibrary`](ParanoiaLibrary) | Rust | Ядро криптографии и протокола, доступно клиентам через FFI |
| [`ParanoiaUiClient`](ParanoiaUiClient) | C++ / Qt6 / QML | Кроссплатформенный десктоп- и мобильный клиент |
| [`ParanoiaEasyCli`](ParanoiaEasyCli) | Rust | Клиент командной строки |
| [`ParanoiaCover`](ParanoiaCover) | — | Слой маскировки / cover-трафика |

## Сборка из исходников

Требуется: **Rust** (stable) и **Qt 6.10+** для клиента.

```bash
# Сервер (Rust)
cd ParanoiaServer && cargo build --release

# Клиент (Qt/QML) — собирается через CMake-пресеты под ваш набор Qt 6.10
cd ParanoiaUiClient && cmake --preset linux-release && cmake --build build/linux-release
```

Подробные руководства — в [`docs/`](docs) (сборка под Android, маршрутизация nginx, cover-слой, обмен ключами и т.д.).

## Документация и политики

- [Модель безопасности и анализ угроз](docs/SECURITY-MODEL.md)
- [Шифрование локального хранилища](LocalStorageEncryptionPolicy.md)
- [Статусы доставки](MessageDeliveryStatusPolicy.md) · [Уведомления](NotificationsPolicy.md) · [Мультиустройства](MultiDevicePolicy.md)
- [Приватность имён](UsernamePrivacyPolicy.md) · [Резервные адреса сервера](ReserveServerUrlPolicy.md) · [VoIP](VoipPolicy.md)
- [Экспортный комплаенс](EXPORT_COMPLIANCE.md)

## Лицензия

Распространяется под [лицензией MIT](LICENSE). Ознакомьтесь с [EXPORT_COMPLIANCE.md](EXPORT_COMPLIANCE.md) насчёт правил экспорта криптографии.

---

<div align="center">
<sub>Сайт: <a href="https://paranoia.run/">paranoia.run</a></sub>
</div>
