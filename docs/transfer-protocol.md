# Transfer Protocol v0.18

This document describes the transfer protocol used by SmarterSwitch to migrate data between two Android phones over a secure Wi-Fi connection.

## Overview

The transfer happens over a TLS-encrypted TCP socket between two phones on the same local network. One phone acts as the **sender** (OLD phone) and the other as the **receiver** (NEW phone).

```mermaid
flowchart LR
    subgraph OLD["OLD Phone (Sender)"]
        S[TransferScreen]
        SR[SmsReader]
        CR[CallLogReader]
    end
    
    subgraph NEW["NEW Phone (Receiver)"]
        R[TransferScreen]
        SW[SmsWriter]
        CW[CallLogWriter]
    end
    
    S -->|TLS Socket| R
    SR --> S
    CR --> S
    R --> SW
    R --> CW
```

## Connection & Pairing

Before transfer begins, the phones establish a secure connection:

```mermaid
sequenceDiagram
    participant S as Sender (OLD)
    participant R as Receiver (NEW)
    
    Note over S,R: mDNS Discovery
    S->>S: Advertise "_smarterswitch._tcp"
    R->>R: Browse for service
    R->>S: TCP Connect
    
    Note over S,R: ECDH Key Exchange + PIN
    S->>R: Public Key A
    R->>S: Public Key B
    Note over S,R: Both derive shared secret<br/>using PIN as additional entropy
    
    Note over S,R: TLS Handshake
    S->>R: Encrypted session established
```

## Transfer Flow

### High-Level Sequence

```mermaid
sequenceDiagram
    participant S as Sender
    participant R as Receiver
    
    Note over S,R: Phase 1: Handshake
    S->>S: Wait for Resume
    R->>S: ResumeEnvelope
    S->>R: ReadyEnvelope
    
    Note over S,R: Phase 2: Category Transfer (repeat per category)
    S->>R: CategoryAnnounceEnvelope(sms, count=127)
    R->>S: CategoryAckEnvelope(sms)
    
    loop For each record
        S->>R: SmsRecordEnvelope(record)
    end
    
    S->>R: CategorySentEnvelope(sms, itemIds=[...])
    R->>S: CategoryReceivedEnvelope(sms, count=127, missing=[])
    
    Note over R: Background: Dedup & Write
    
    Note over S,R: Phase 3: Completion
    S->>R: TransferDoneEnvelope
    R->>R: Wait for all dedup tasks
    R->>R: Navigate to Done screen
```

### Sender State Machine

```mermaid
stateDiagram-v2
    [*] --> WaitingForResume: Start
    WaitingForResume --> SendingReady: Resume received
    SendingReady --> PreparingCategory: Ready sent
    
    PreparingCategory --> WaitingForCategoryAck: CategoryAnnounce sent
    WaitingForCategoryAck --> StreamingRecords: CategoryAck received
    
    StreamingRecords --> WaitingForCategoryReceived: All records sent,<br/>CategorySent sent
    WaitingForCategoryReceived --> PreparingCategory: CategoryReceived received,<br/>more categories
    WaitingForCategoryReceived --> SendingTransferDone: CategoryReceived received,<br/>no more categories
    
    SendingTransferDone --> Done: TransferDone sent
    Done --> [*]
```

### Receiver State Machine

```mermaid
stateDiagram-v2
    [*] --> RequestingPermissions: Start
    RequestingPermissions --> SendingResume: Permissions done
    SendingResume --> WaitingForReady: Resume sent
    WaitingForReady --> WaitingForData: Ready received
    
    WaitingForData --> WaitingForData: Record received<br/>(buffer it)
    WaitingForData --> WaitingForData: CategoryAnnounce<br/>(send CategoryAck)
    WaitingForData --> WaitingForData: CategorySent<br/>(send CategoryReceived,<br/>start background dedup)
    WaitingForData --> FinalizingWrites: TransferDone received
    
    FinalizingWrites --> Done: All dedup tasks complete
    Done --> [*]
```

## Envelope Types

All data is transmitted as JSON-encoded envelopes with a `kind` field for dispatch.

### Handshake Envelopes

| Envelope | Direction | Purpose |
|----------|-----------|---------|
| `ResumeEnvelope` | R → S | Receiver confirms listener is attached |
| `ReadyEnvelope` | S → R | Sender confirms it will start streaming |

### Category Control Envelopes

| Envelope | Direction | Purpose |
|----------|-----------|---------|
| `CategoryAnnounceEnvelope` | S → R | Announces category + item count |
| `CategoryAckEnvelope` | R → S | Confirms ready to receive category |
| `CategorySentEnvelope` | S → R | All items sent, includes item IDs for verification |
| `CategoryReceivedEnvelope` | R → S | Confirms receipt, lists any missing IDs |

### Data Envelopes

| Envelope | Category | Contents |
|----------|----------|----------|
| `SmsRecordEnvelope` | SMS/MMS | address, body, timestamp, type, threadId, mmsParts |
| `CallLogRecordEnvelope` | Call Log | number, timestamp, duration, direction, cachedName |
| `ContactRecordEnvelope` | Contacts | displayName, phones, emails, sourceAccountType |
| `CalendarEventEnvelope` | Calendar | uid, title, location, start/end times, recurrence |
| `MediaStartEnvelope` | Photos | sha256, fileName, byteSize, mimeType, kind |
| `MediaChunkEnvelope` | Photos | sha256, offset, base64-encoded bytes |
| `MediaEndEnvelope` | Photos | sha256 (signals file complete) |

### Completion Envelopes

| Envelope | Direction | Purpose |
|----------|-----------|---------|
| `CategoryDoneEnvelope` | S → R | Legacy: category complete (kept for back-compat) |
| `TransferDoneEnvelope` | S → R | All categories complete |

## Item ID Tracking

Each record is assigned a hash-based ID for deduplication and verification:

```mermaid
flowchart TD
    subgraph SMS["SMS ID Generation"]
        A[address] --> N1[normalize]
        B[body] --> H1[SHA256]
        T[timestamp] --> BK[bucket to minute]
        P[mmsParts] --> S1[sort + join]
        N1 & H1 & BK & S1 --> ID1[SmsDedupKey.toString]
    end
    
    subgraph CallLog["Call Log ID Generation"]
        C[number] --> N2[normalize]
        T2[timestamp] --> BK2[bucket to minute]
        D[duration]
        DR[direction]
        N2 & BK2 & D & DR --> ID2[CallLogDedupKey.toString]
    end
```

## Deduplication Flow

The receiver performs deduplication **after** all records for a category are received:

```mermaid
flowchart TD
    subgraph Receive["During Transfer"]
        R1[Receive records] --> B1[Buffer in memory]
        B1 --> R1
    end
    
    subgraph Dedup["After CategorySent"]
        B1 --> L1[Load local records]
        L1 --> I1[Build dedup index]
        I1 --> C1{For each<br/>incoming record}
        C1 -->|In index| SK[Skip - duplicate]
        C1 -->|Not in index| W1[Write to device]
        SK --> C1
        W1 --> C1
    end
    
    C1 -->|Done| DONE[Update tallies]
```

## Photos: Pre-flight Hash Protocol

Photos use a special pre-flight protocol to avoid sending duplicates:

```mermaid
sequenceDiagram
    participant S as Sender
    participant R as Receiver
    
    Note over S: Hash all photos locally<br/>(cached for future transfers)
    
    S->>R: PhotoHashesEnvelope([{sha256, pHash}, ...])
    
    Note over R: Compare against local photos
    
    R->>S: PhotoSkipListEnvelope([sha256s to skip])
    
    loop For each non-skipped photo
        S->>R: MediaStartEnvelope(header)
        S->>R: MediaChunkEnvelope(chunk 1)
        S->>R: MediaChunkEnvelope(chunk 2)
        S->>R: ...
        S->>R: MediaEndEnvelope
    end
```

## Error Handling

### Timeouts

| Wait | Timeout | Action on Timeout |
|------|---------|-------------------|
| Resume | 120s | Show "other phone not ready" error |
| Ready | 30s | Proceed anyway (best effort) |
| CategoryAck | 30s | Throw protocol error |
| CategoryReceived | 60s | Throw protocol error |

### Fire-and-Forget Acks

Receiver sends acks without blocking:

```dart
// Non-blocking - schedules send, continues immediately
session.sendFrame(CategoryAckEnvelope(category: cat).toBytes())
    .catchError((Object _) {});
```

This prevents the receiver's frame listener from blocking while waiting for socket writes.

## Wire Format

Each envelope is JSON-encoded and framed with a 4-byte big-endian length prefix:

```
┌─────────────┬────────────────────────────────────┐
│ Length (4B) │ JSON Payload (variable)            │
├─────────────┼────────────────────────────────────┤
│ 00 00 00 2A │ {"kind":"sms_record","record":{...}}│
└─────────────┴────────────────────────────────────┘
```

## Version History

| Version | Changes |
|---------|---------|
| v0.18.2 | Simplified to fire-and-forget acks, removed batch acks |
| v0.18.0 | Added CategoryAnnounce/Ack/Sent/Received handshakes |
| v0.17.3 | Added Ready handshake after Resume |
| v0.17.0 | Buffer-then-dedup receiver flow |
| v0.16.9 | Per-record acks for progress sync |
