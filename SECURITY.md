# Security Policy

## Reporting a vulnerability

Report security issues privately to **support@paranoia.run** — do not open a public
issue for an unfixed vulnerability.

Please include: affected component (`ParanoiaServer`, `ParanoiaLibrary`,
`ParanoiaUiClient`, `ParanoiaEasyCli`, `ParanoiaCover`), version or commit,
reproduction steps, and the impact you believe it has.

Expect an acknowledgement within 7 days. Fixes are released as a new tagged version;
reporters are credited in the release notes unless they ask otherwise.

## Scope

In scope: the protocol and its implementation — cryptography, signatures, replay and
overwrite handling, the cover layer, local storage encryption, key exchange and
key transfer.

Out of scope: the limitations already documented in
[docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md) § "Возможные угрозы" — a fully
compromised client device, IP/timing metadata visible to the server, domain or IP
blocking by a censor, and detection by an ML classifier trained on long observation.
These are known, accepted trade-offs rather than vulnerabilities. Reports that
narrow or quantify them are still welcome.

## Supported versions

Only the latest released version is supported. Fixes are not backported.
