# Export Compliance / Заявление об экспортном соответствии

**Project:** Paranoia — free, open-source (MIT) secure messenger
**Status:** mass-market consumer application, publicly available open-source software
**Encryption:** strong end-to-end cryptography in a custom (proprietary) protocol for
message and call content.

> This document is a good-faith, conservative statement of the project's U.S.
> export-control position. It is **not legal advice**. Before the first App Store
> release, confirm the chosen path with a trade-compliance professional.

---

## 1. Mass-market nature (Note 3 to Category 5, Part 2 of the EAR)

Paranoia meets the criteria of a **mass-market** item:

- Generally available to the public, distributed free of charge through the App
  Store and other public channels, with no individual negotiation.
- Installed by the end user without further substantial support from the supplier.
- The cryptographic functionality cannot be easily changed by the user.
- Not designed or marketed for government end-users as a primary market.

In commercial terms this is unambiguously a mass-market consumer application.

## 2. Why this is NOT "no encryption" (Apple `ITSAppUsesNonExemptEncryption`)

The app implements real strong encryption as its core function and uses a
**custom protocol**. Under the EAR this is *"non-standard cryptography"*
(proprietary/unpublished protocol). Therefore:

- `ITSAppUsesNonExemptEncryption` is set to **`true`** in `ios/Info.plist.in`.
- We do **not** rely on the simple mass-market self-classification under License
  Exception ENC §740.17(b)(1): that track is **not** directly available to
  non-standard cryptography. (Setting the Apple flag to `false` to suppress the
  prompt would be a false export declaration — we do not do this.)

## 3. Primary basis for distribution: publicly available open-source software

Because the **complete source code is published under the MIT license**, it
qualifies as *publicly available* encryption source code under EAR **§740.13(e)**
(License Exception TSU) and **§742.15(b)**. Publicly available encryption source
code is **not subject to the EAR** once a one-time notification is e-mailed.

### Required one-time action (do once, when the repo is public)

Send a single e-mail (no reply required), retaining a copy as proof, to **both**:

- `crypt@bis.doc.gov` (U.S. Bureau of Industry and Security)
- `enc@nsa.gov` (NSA / ENC Encryption Request Coordinator)

Suggested body:

```
Subject: Notification of publicly available encryption source code (EAR 740.13(e) / 742.15(b))

This is a notification under 15 CFR 742.15(b) and 740.13(e).

Item:           Paranoia — open-source secure messenger (MIT license)
Source code URL: https://<PUBLIC-REPO-URL>
Description:     End-to-end encryption (custom protocol) for messaging/calls.
                 Complete corresponding source code is publicly available,
                 free of charge, at the URL above.

Submitter:      <name or project entity>
Contact e-mail: <role-based contact, e.g. security@paranoia.app>
```

> Note: only the *source code* is rendered "not subject to the EAR" by this
> notification. The *compiled binary* distributed via the App Store is treated as
> a mass-market item; if zero ambiguity is desired for the binary, file either a
> classification request (CCATS, §740.17(b)(2)) targeting **ECCN 5D992** or an
> annual self-classification report. For a free open-source project the
> publicly-available notification above is the standard, defensible position.

## 4. ECCN summary

| Item | ECCN target | Basis |
|------|-------------|-------|
| Source code (published) | not subject to the EAR | §740.13(e) / §742.15(b) after notification |
| Compiled mass-market app | 5D992 (mass market) | Note 3 to Cat. 5 Pt. 2 |

## 5. Apple App Store Connect answers (to use at submission time)

- "Does your app use encryption?" → **Yes**.
- "Does it qualify for an exemption?" → select the **publicly available /
  open-source** branch; reference the §740.13(e) notification above.
- Keep the sent BIS/ENC e-mail; optionally upload year-long documentation so
  the prompt is not repeated on every upload.

## 6. Checklist

- [x] `ITSAppUsesNonExemptEncryption = true` (honest declaration)
- [x] Source published under MIT (`LICENSE`)
- [ ] One-time §740.13(e) e-mail to BIS + ENC (when repo is public) — keep proof
- [ ] App Store Connect export-compliance wizard answered to match this document
- [ ] (Optional, for binary certainty) CCATS / annual self-classification report
