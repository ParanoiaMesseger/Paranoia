<div align="center">

<img src="ParanoiaUiClient/resources/design/logo_lockup_animated.svg" alt="Paranoia" width="320">

# Paranoia

**End-to-end encrypted messenger built against a strong adversary — censoring ISPs, MITM, and a fully compromised server.**

[![License: MIT](https://img.shields.io/badge/License-MIT-c91122.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/ParanoiaMesseger/Paranoia?color=c91122&label=release)](https://github.com/ParanoiaMesseger/Paranoia/releases/latest)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20Windows%20%7C%20macOS%20%7C%20Android%20%7C%20iOS-08070a.svg)](#download)
[![Website](https://img.shields.io/badge/website-paranoia.run-c91122.svg)](https://paranoia.run/)

[Русский](README.ru.md) · [Website](https://paranoia.run/) · [Download](https://github.com/ParanoiaMesseger/Paranoia/releases/latest) · [Security model](docs/SECURITY-MODEL.md)

</div>

---

## What is Paranoia

Paranoia is a secure messenger designed for a world where you trust no one in the middle — not the network, not the server, not even the certificate authority. Messages are end-to-end encrypted on the client; the server is a *zero-trust* relay that never sees plaintext, and even a fully compromised server cannot forge, replay, or silently rewrite history.

On top of confidentiality, Paranoia focuses on **stealth**: service, administrative and call traffic are wrapped in a masquerade ("cover") layer so that to an outside observer — including DPI/ML traffic analysis — the connection looks like ordinary HTTPS to a regular website.

> Full threat model and design rationale: **[docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md)**.

## Key features

- 🔒 **End-to-end encryption** — content is unreadable to the server and to a transport-level MITM.
- 🕵️ **Traffic masquerading (cover layer)** — service/admin/VoIP traffic is hidden inside a single cover tunnel that mimics normal web traffic.
- 🧱 **Zero-trust server** — a compromised server gets only ciphertext; it cannot inject or alter messages.
- ✍️ **Integrity & authenticity** — every message is signed; the server cannot fabricate history on a user's behalf.
- 🗑️ **Right to be forgotten** — users can initiate deletion of their own data from the server.
- 🛰️ **Censorship resistance** — reserve server URLs, masquerade as a website, distribution via CDN.
- 📞 **Secure VoIP** — encrypted calls with TURN fallback.
- 🌍 **Cross-platform** — Linux, Windows, macOS, Android, iOS from one Qt/QML codebase.

## Download

Grab the latest installers and binaries from the **[Releases page](https://github.com/ParanoiaMesseger/Paranoia/releases/latest)**:

| Platform | Asset |
|---|---|
| Linux (x86_64) | `paranoia-linux-x86_64.deb` |
| Windows | `paranoia-windows-x86_64-installer.exe` |
| macOS (arm64) | `paranoia-macos-arm64.dmg` |
| Android | `paranoia-android-arm64.apk` |
| iOS | `paranoia-ios-arm64.ipa` |
| Server | `paranoia-amd64` · `paranoia-arm64` · `paranoia-armhf` |

The desktop and mobile apps also check for and install updates from these releases automatically.

## Architecture

Paranoia is split into independent components:

| Component | Language | Role |
|---|---|---|
| [`ParanoiaServer`](ParanoiaServer) | Rust | Zero-trust relay server (stores only ciphertext + metadata) |
| [`ParanoiaLibrary`](ParanoiaLibrary) | Rust | Core cryptography and protocol, exposed to clients via FFI |
| [`ParanoiaUiClient`](ParanoiaUiClient) | C++ / Qt6 / QML | Cross-platform desktop & mobile client |
| [`ParanoiaEasyCli`](ParanoiaEasyCli) | Rust | Command-line client |
| [`ParanoiaCover`](ParanoiaCover) | — | Masquerade / cover-traffic layer |

## Building from source

Requirements: **Rust** (stable) and **Qt 6.10+** for the client.

```bash
# Server (Rust)
cd ParanoiaServer && cargo build --release

# Client (Qt/QML) — uses CMake presets against your Qt 6.10 kit
cd ParanoiaUiClient && cmake --preset linux-release && cmake --build build/linux-release
```

Deeper guides live in [`docs/`](docs) (Android build, nginx target routing, cover layer, key exchange, …).

## Documentation & policies

- [Security model & threat analysis](docs/SECURITY-MODEL.md)
- [Local storage encryption](LocalStorageEncryptionPolicy.md)
- [Message delivery status](MessageDeliveryStatusPolicy.md) · [Notifications](NotificationsPolicy.md) · [Multi-device](MultiDevicePolicy.md)
- [Username privacy](UsernamePrivacyPolicy.md) · [Reserve server URLs](ReserveServerUrlPolicy.md) · [VoIP](VoipPolicy.md)
- [Export compliance](EXPORT_COMPLIANCE.md)

## License

Released under the [MIT License](LICENSE). Please review [EXPORT_COMPLIANCE.md](EXPORT_COMPLIANCE.md) regarding cryptography export regulations.

---

<div align="center">
<sub>Website: <a href="https://paranoia.run/">paranoia.run</a></sub>
</div>
