# SmarterSwitch

A cross-platform phone-migration app that **merges with deduplication** instead of overwriting. Solves the gap left by Samsung Smart Switch and Google's "Switch to Android" — both of which are setup-time, fresh-device tools that don't dedupe overlapping data when migrating onto a phone that's already in use.

## Why this exists

The 2026 phone-migration tooling landscape:

| Tool | Direction | Dedupe | Works on already-set-up target? |
|---|---|---|---|
| Samsung Smart Switch | → Samsung only | No | No |
| Google Switch to Android | → Pixel/Android | No | No (setup wizard only) |
| Apple Move to iOS | → iOS | No | No (setup wizard only) |
| iCloud / Google sync | Bidirectional, partial | Yes (cloud) | Yes |
| **SmarterSwitch** | **A ↔ B** | **Yes** | **Yes** |

The merge-with-dedup case is real: anyone who has used phone B, switched back to A, and now wants to return to B without losing what accumulated on B in the meantime.

## MVP scope

**Phase 1 — Android ↔ Android:**
- SMS/MMS with content-hash dedup (not just timestamp + body)
- Call log dedup
- Contacts (delegated to Google Contacts merge — we don't reinvent this)
- Photos/videos with perceptual + exact hash dedup
- Calendar events

**Phase 2 — iOS ↔ Android (limited):**
- Contacts, photos, calendar, files only
- SMS/call-log on iOS is **not possible** at the app layer; documented as out-of-scope. See `ARCHITECTURE.md` § Platform Constraints.

**Phase 3 — App data, WhatsApp, Signal:**
- WhatsApp: investigate Android `msgstore.db` merge (rooted/dev-mode only path; not Play Store viable).
- Signal: same.
- Most other apps: out-of-scope; restored via Google account.

## Stack

- **Flutter + Dart** for shared UI, orchestration, and the dedup engine (pure Dart, unit-testable).
- **Native Kotlin** for Android SMS/MMS/call-log access (default-SMS-app permission required), exposed via `MethodChannel`.
- **Native Swift** for iOS contacts/photos/calendar via Contacts, PhotoKit, EventKit, exposed via `FlutterMethodChannel`.
- **Local-only transfer** over LAN (mDNS-discovered peer + TLS) — no cloud relay, no account, no analytics. Privacy is the default.

## Project layout

```
smarterswitch/
├── README.md                  ← this file
├── ARCHITECTURE.md            ← module design, dedup algorithms, platform constraints
├── ROADMAP.md                 ← phased delivery plan
├── app/                       ← Flutter project (created by `flutter create`)
│   ├── lib/
│   │   ├── core/              ← dedup engine, hashing, transfer protocol (pure Dart)
│   │   ├── platform/          ← MethodChannel wrappers
│   │   ├── ui/                ← screens + routing
│   │   └── state/             ← state management (Riverpod)
│   ├── test/                  ← Dart unit tests
│   ├── android/app/src/main/kotlin/com/smarterswitch/app/native/   ← Kotlin modules
│   └── ios/Runner/native/     ← Swift modules
└── docs/
    └── dedup-algorithms.md    ← detailed hashing + matching rules
```

## Status

Scaffolded. No working code yet. See `ROADMAP.md` for the next steps.
