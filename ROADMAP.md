# Roadmap

Phased to derisk the hardest pieces first (SMS dedup correctness, default-SMS-app handoff, Play Store gating). Each phase has a working, demoable artifact.

## Phase 0 — Scaffold (current)

- [x] Project directory + planning docs
- [x] Flutter + Dart app scaffolded under `app/`
- [x] Android module skeleton (Kotlin) wired to a stub `MethodChannel` bridge
- [ ] iOS module skeleton (Swift) — deferred until a Mac is available; placeholder source files only

## Phase 1 — Android-only SMS dedup proof-of-concept

The product's hardest correctness problem first.

- [x] `SmsModule.kt`: read SMS via `content://sms`, emit normalized records
- [x] `lib/core/dedup/sms.dart`: composite-hash matcher; unit tests with synthetic dupes (timestamp jitter, body whitespace, address formatting)
- [ ] CLI harness (`tool/sms_diff.dart`) that takes two XML exports (from SMS Backup & Restore) and reports the dedup diff — proves the algorithm before the network/UI layers
- [ ] Validation set: real 5k+ SMS export from the user's S23 vs. Pixel 7 baseline; manually spot-check matches
- [ ] Default-SMS-app handoff flow: write a small set of new messages back, verify thread integrity in Google Messages

**Exit criterion:** zero false positives on the validation set; <1% false negatives explained by genuine carrier resends.

## Phase 2 — Android↔Android end-to-end

- [ ] mDNS pairing + PIN + TLS-PSK channel
- [ ] Manifest-then-payload streaming protocol
- [ ] Call log dedup (much simpler than SMS — should land in days)
- [ ] Photos: hash-only dedup first, perceptual second
- [ ] Contacts: read/write + delegation pointer to Google Contacts merge for synced contacts
- [ ] Calendar
- [ ] Transfer UI with per-category progress and resume

**Exit criterion:** S23 → Pixel 7 round trip on the user's actual data, completing without duplicates.

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
- Backwards-compat with proprietary Smart Switch / Switch to Android backup formats — complexity sink, not the value proposition.
