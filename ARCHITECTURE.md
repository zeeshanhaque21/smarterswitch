# Architecture

## Platform constraints (read this first)

The product's feasible surface is defined by what each OS lets a third-party app touch. Many capabilities people *expect* from a migration tool are gated behind privileges only the OS vendor has.

### Android

| Data | Access | Notes |
|---|---|---|
| SMS / MMS | Yes | Requires being **default SMS app** during transfer, then handing role back. Play Store gating is strict — must justify in listing. |
| Call log | Yes | `READ_CALL_LOG` / `WRITE_CALL_LOG`. Play Store also gates this; need a "Permissions Declaration." |
| Contacts | Yes | `READ_CONTACTS` / `WRITE_CONTACTS`. |
| Photos / Videos | Yes | MediaStore + scoped storage; `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` on Android 13+. |
| Calendar | Yes | `READ_CALENDAR` / `WRITE_CALENDAR`. |
| App data | No | Sandbox isolation. Rooted-only or platform-signed. |
| WhatsApp DB | No (Play Store) | `msgstore.db` lives in WhatsApp's private dir. Reachable only via root, ADB backup (deprecated/broken on modern WA), or sideload. |

### iOS

| Data | Access | Notes |
|---|---|---|
| SMS / iMessage | **No** | Apple does not expose any API. No entitlement. Smart Switch and every third-party tool hits this wall. |
| Call log | **No** | Same. |
| Contacts | Yes | Contacts framework. |
| Photos / Videos | Yes | PhotoKit. |
| Calendar | Yes | EventKit. |
| Reminders | Yes | EventKit. |
| Files | Limited | UIDocumentPickerViewController; user-chosen scope. |
| App data | No | Sandbox. |
| WhatsApp / Signal chats | No | Sandboxed. |

**Implication:** any iOS-as-source migration cannot include SMS or call log. The product surfaces this as a documented limitation in the iOS source flow, with a pointer to Apple's Data & Privacy export portal as the only manual workaround.

## High-level architecture

```
┌─────────────────────────┐         ┌─────────────────────────┐
│   Source phone (A)      │   LAN   │   Target phone (B)      │
│  ┌──────────────────┐   │ ──────► │  ┌──────────────────┐   │
│  │ Native readers   │   │  TLS    │  │ Dedup engine     │   │
│  │ (SMS/Contacts/…) │   │ over    │  │ + Native writers │   │
│  └────────┬─────────┘   │ mDNS-   │  └────────┬─────────┘   │
│           │             │ paired  │           │             │
│           ▼             │  peer   │           ▼             │
│   Stream + hash         │         │   Compare hashes,       │
│   per record            │         │   skip duplicates,      │
│                         │         │   write new only        │
└─────────────────────────┘         └─────────────────────────┘
```

**No cloud relay.** Two phones pair on whatever local link is fastest available — Wi-Fi Direct primarily, same-LAN mDNS as fallback, USB-C if the spike clears (`docs/usb-c-spike.md`). All paths use the same 6-digit PIN handshake; transfer rides AES-GCM on top of a key derived from the PIN. No account, no telemetry.

## Modules

### `core/dedup`

The heart of the product. Per-data-type matching rules:

- **SMS/MMS** — composite hash of `(normalized_address, timestamp_to_minute, body_sha256, [mms_part_hashes])`. Timestamp bucketed to the minute to absorb carrier jitter. MMS parts hashed by content, not filename.
- **Call log** — `(normalized_number, timestamp_to_minute, duration_seconds, direction)`.
- **Contacts** — delegate to Google Contacts' built-in merge for the Google-synced subset; for non-synced (Samsung-local, SIM) contacts, key on `(normalized_phone | email | full_name)` with a confidence score and surface low-confidence matches to the user.
- **Photos/videos** — primary key `sha256(file_bytes)`; secondary perceptual hash (pHash for stills, video keyframe pHash) to catch resized/recompressed copies. User reviews pHash-only matches.
- **Calendar** — `(uid)` if present (CalDAV/iCal), else `(start_utc, duration, title_normalized, location_normalized)`.

Dedup runs **on the target**, after streaming the source's hash manifest first. The full payload is only transferred for records that don't match. This keeps transfer cost proportional to genuinely new data.

### `core/transfer`

A single Dart `Transport` interface with three concrete implementations, ranked by throughput:

- **Wi-Fi Direct (primary).** Android `WifiP2pManager`. Receiver pins `groupOwnerIntent = 15` so the receiver is deterministically the group owner; sender connects to the framework-assigned `192.168.49.1`. No shared Wi-Fi network needed.
- **Same-LAN mDNS (fallback).** Service `_smarterswitch._tcp`. Used when both phones are already on the same network or as fallback if Wi-Fi Direct group formation fails repeatedly.
- **USB-C (gated on spike).** Android `UsbManager` host/accessory mode + Power Delivery Data Role Swap. Implemented only if `docs/usb-c-spike.md` clears its ≥10 MB/s exit criterion on consumer-grade cables. See that file for the cable matrix.

Common protocol layer above the transport:

- 6-digit PIN handshake. X25519 ECDH between the peers, with HKDF-SHA256 keyed by `(shared_secret, salt=PIN)`. Wrong PIN ⇒ statistically unrelated derived key ⇒ first authenticated message fails MAC ⇒ clean reject.
- Wire format: length-prefixed (uint32 BE) frames over the link. Frames carry typed messages — Hello / Manifest / Record / Ack / Resume.
- AES-GCM seal per frame using the handshake-derived key (32 bytes).
- Resumable per-category. Each category gets its own monotonic uint64 sequence space and a write-ahead log on the receiver. On reconnect after a drop, receiver replays its highest-acked watermark to the sender; sender skips ahead. A photo-transfer drop doesn't restart SMS.

Loopback `InMemoryTransport` for unit tests so the protocol layer is exercisable without any platform code.

### `platform/android`

Kotlin native handlers registered against a `MethodChannel` per data type, attached to the `FlutterEngine` in `MainActivity`:

- `SmsModule` (channel `smarterswitch/sms`) — read via `content://sms`; write via the default-SMS-app role flow. Includes the dance of requesting `Telephony.Sms.getDefaultSmsPackage` → swap → restore.
- `CallLogModule` (`smarterswitch/calllog`) — `CallLog.Calls` content provider.
- `ContactsModule` (`smarterswitch/contacts`) — `ContactsContract`.
- `MediaModule` (`smarterswitch/media`) — MediaStore queries with hash computation off the main thread (use `EventChannel` to stream progress).
- `CalendarModule` (`smarterswitch/calendar`) — `CalendarContract`.

### `platform/ios`

Swift handlers registered against `FlutterMethodChannel` instances in `AppDelegate`:

- `ContactsModule` — Contacts framework.
- `PhotosModule` — PhotoKit (Limited Library prompt handled).
- `CalendarModule` — EventKit.
- `FilesModule` — DocumentPicker-mediated.

No SMS/call-log module — see Platform constraints.

### `ui/`

Flutter screens (under `lib/ui/`, routed via `go_router`):

1. **Pair** — pick role (sender / receiver), discover, PIN.
2. **Select data** — checklist of what to transfer; shows source-side counts.
3. **Scan & match** — receiver scans local data, builds hash index; sender sends manifest; UI shows "X new / Y duplicates / Z conflicts."
4. **Review conflicts** — for ambiguous matches (perceptual photo dupes, fuzzy contact matches).
5. **Transfer** — progress per category, resumable.
6. **Done** — summary + per-category report.

## Out of scope

- Cloud relay / cross-network transfer (privacy stance).
- Account system.
- iCloud-side iOS data extraction (use Apple's Data & Privacy portal manually).
- WhatsApp / Signal chat merging (technically infeasible without root; we will not ship a rooted-only path on Play Store).
- App settings / app data (sandboxed; out of reach).

## Open questions

- Play Store SMS-permission justification: needs a clear product narrative for Google's review. The "merge migration" angle is novel and may pass; needs a pre-submission review request.
- Default-SMS-app handoff UX on Android: how to sequence (sender role-grab vs. receiver role-grab) without leaving the user without SMS for an extended window.
- Photo perceptual hashing on-device: cost on a 30k-photo library. Likely needs a background indexing pass with progress UI.
