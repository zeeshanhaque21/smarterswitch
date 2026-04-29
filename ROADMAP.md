# Roadmap

Per the user's scope decisions during the no-PC-transfer plan: v1 holds release until **all five categories work end-to-end** (read, dedup, write) on Android↔Android. iOS is Phase 3.

## Phase 0 — Scaffold

- [x] Project directory + planning docs
- [x] Flutter + Dart app scaffolded under `app/`
- [x] Android module skeleton (Kotlin) wired via `MethodChannel`
- [x] iOS module skeleton (Swift) — placeholder `ios/Runner/native/ContactsChannel.swift`; full implementation deferred until a Mac is available

## v1 — Android↔Android, all five categories, no PC

Subdivided into tracks that can land in parallel. Each track has a "code complete" gate that requires no real-device testing, and a "validated" gate that does.

### Track A — Transport

- [x] `Transport` / `PairedSession` / `DiscoveredPeer` interfaces (`app/lib/core/transfer/transport.dart`)
- [x] `InMemoryTransport` for unit tests
- [x] `FrameCodec` (length-prefixed wire framing)
- [x] `CategoryWal` (per-category resumability)
- [x] `Handshake` (X25519 + HKDF + PIN-derived key material)
- [ ] **USB-C spike** (`docs/usb-c-spike.md`) — pass/fail in 5 working days
- [ ] `WifiDirectTransport` + `WifiDirectChannel.kt` (Android `WifiP2pManager`)
- [ ] `MdnsTransport` (`multicast_dns` pub package)
- [ ] `UsbTransport` + `UsbChannel.kt` — gated on spike
- [ ] `TransferForegroundService.kt` (so backgrounded transfers survive)
- [ ] Wire pair/scan/transfer screens to a real `PairedSession`
- [ ] AES-GCM seal frames using handshake-derived key

### Track B — Per-category readers / writers / dedup matchers

Read + count are wired (Select screen shows live counts on real hardware).
Dedup matchers are pure-Dart and unit-tested. Writers are the missing piece per category.

- [x] **SMS** read + count + dedup matcher + XML-parser CLI harness (`tool/sms_diff.dart`)
- [x] **Call log** count + dedup matcher
- [x] **Contacts** count + dedup matcher (multi-key + confidence)
- [x] **Photos/videos** count + size estimate + sha256+pHash matcher
- [x] **Calendar** count + dedup matcher (UID + composite fallback)
- [x] Multi-category CLI harness (`tool/dedup_diff.dart`) — JSON in, dedup report out
- [ ] SMS writer (default-SMS-app role grab/release dance)
- [ ] Call log writer (`CallLog.Calls.CONTENT_URI` insert + `WRITE_CALL_LOG`)
- [ ] Contacts writer (`ContactsContract` raw-contact insert)
- [ ] Photos writer (MediaStore insert with original timestamps)
- [ ] Calendar writer (`CalendarContract.Events` insert)
- [ ] Real readers (currently only count is implemented for the four new categories)

### Track C — UX

- [x] Pair / Select / Scan / Transfer / Done screens (with stubbed transport)
- [x] Per-category Select screen with live counts, byte estimates, "Tap to allow" inline permission CTAs, "Select all" toggle, running-total CTA
- [x] Conflict review screen (Contacts + Photos pHash) with three-way Keep both / Keep this / Use source
- [ ] Pair screen rewired to use `Transport` factory (probe Wi-Fi Direct, fall back to mDNS, surface USB-C if available)
- [ ] Scan screen rewired to stream the real per-category dedup diff
- [ ] Transfer screen rewired to stream foreground-service progress events
- [ ] Default-SMS-app role grab onboarding (in-app explainer before the system dialog)

### Validation gates (real device pair required)

- [ ] SMS validation set: 5k+ messages from user's S23 vs Pixel baseline; zero false-positive dedup; <1% false-negatives
- [ ] Real-device pair test on Wi-Fi Direct (S23 ↔ Pixel 7)
- [ ] Same on mDNS fallback (mobile data off, both on home Wi-Fi)
- [ ] Wrong-PIN reject test
- [ ] Drop-and-resume test (Wi-Fi off for 10s during transfer; verify WAL replay)
- [ ] Background test (foreground-service notification + transfer continues)
- [ ] OEM matrix: Samsung + Pixel + one MIUI device
- [ ] End-to-end round trip with all five categories selected
- [ ] Reverse round trip — should be all dedups, zero new transfers

**Exit criterion:** S23 → Pixel 7 round trip on the user's actual data, completing without duplicates across all five categories.

## Phase 3 — iOS as source

Reduced scope due to platform constraints (no SMS, no call log).

- [ ] Contacts, Photos, Calendar, Files
- [ ] Document the manual iCloud SMS export workflow as the only path for SMS-from-iOS

## Phase 4 — Polish & store submission

- [ ] Play Store Permissions Declaration for SMS / Call Log
- [ ] Privacy policy (no data leaves the LAN — easy story)
- [ ] App Store submission for iOS
- [ ] Crash reporting (opt-in, on-device only by default)

## Explicit non-goals

- WhatsApp / Signal chat merge (technically infeasible without root).
- Cloud relay (privacy stance).
- Restoring app settings (sandboxed).
- Backwards-compat with proprietary Smart Switch / Switch to Android backup formats.
- Google Nearby Connections (Play-Services dependency is off-brand for the no-cloud stance).
