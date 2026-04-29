# USB-C transport spike

**Status:** planned, not yet executed.
**Owner:** unassigned.
**Time-box:** 5 working days.

## Goal

Determine whether USB-C device-to-device transfer between two Android phones is feasible as a third `Transport` implementation alongside Wi-Fi Direct and same-LAN mDNS. Pass the spike if we can sustain ≥10 MB/s on at least one approach using a cable type the user is willing to recommend in-app.

## Approaches to test, in order

### 1. Android Open Accessory (AOA) over USB-C with PD Data Role Swap

Most promising. One phone in `UsbManager` host mode, the other in `UsbAccessory` accessory mode. Power Delivery's Data Role Swap renegotiates which side is host at the cable level. Real-world throughput in published numbers for AOA ranges 30–60 MB/s on USB 2.0 hardware.

Open questions:
- Which OEMs respect Data Role Swap requests from a third-party app? Samsung One UI is known to expose `setHostMode` only via a hidden internal API.
- Do current Pixel firmware images allow Accessory mode without OEM-signed builds?
- What's the manifest declaration: `<uses-feature android:name="android.hardware.usb.accessory"/>` is required, but the runtime path may need additional `<intent-filter>` registration.

### 2. OTG adapter bridge

Source: phone with USB-C-to-USB-A OTG adapter. Target: phone with regular USB-C-to-USB-A cable plugged into the OTG adapter. Source phone sees target as a USB device (typically MTP-mounted by default).

Likely throughput: USB 2.0-class, ~25 MB/s peak, ~15 MB/s sustained. Below the AOA target but cable availability is excellent — most users have OTG adapters lying around.

### 3. MTP-over-USB

Receiver mounts source via the Storage Access Framework's MTP provider. Slowest of the three, lossy for SMS / contacts / calendar (those aren't MTP-exposed surfaces) — only useful for photos. Documented as a fallback but not implemented unless 1+2 both fail.

## Cable matrix (to fill in during the spike)

| Cable | Markings | AOA | OTG | MTP | Sustained MB/s | Notes |
|-------|----------|-----|-----|-----|----------------|-------|
| USB-C ↔ USB-C, no markings (random box cable) | — | ? | ? | ? | ? | |
| USB-C ↔ USB-C, "10Gbps" rated | — | ? | ? | ? | ? | |
| USB-C ↔ USB-C, Thunderbolt 3 | — | ? | ? | ? | ? | |
| USB-C ↔ USB-A OTG adapter + USB-A cable | — | ? | ? | ? | ? | |

## OEM matrix (to fill in during the spike)

| Source ↔ Target | AOA pair | OTG pair | MTP pair | Notes |
|-----------------|----------|----------|----------|-------|
| Pixel 7 ↔ Pixel 7 | ? | ? | ? | |
| Pixel 7 ↔ Samsung S23 | ? | ? | ? | |
| Samsung S23 ↔ Samsung S23 | ? | ? | ? | |
| MIUI/HyperOS phone ↔ Pixel 7 | ? | ? | ? | |

## Exit criteria

**Pass:** ≥10 MB/s sustained on at least one approach + at least one cable type the user is willing to recommend in-app.
- Implement `UsbTransport` and `UsbChannel.kt`.
- Add `<uses-feature android:name="android.hardware.usb.host"/>` and `<uses-feature android:name="android.hardware.usb.accessory"/>` to the manifest.
- Surface as `TransportSpeedClass.usb`, ranked above `wifiDirect` in the probe order.

**Fail:** No approach beats Wi-Fi Direct's real-world throughput, or all approaches require non-consumer cables.
- Update this document with cable / OEM tables filled in.
- Add the relevant section to `ARCHITECTURE.md` § Out of scope so future contributors don't re-litigate the decision.

## Required hardware

- 2× Android phones (a Pixel + a Samsung is enough for a useful first pass).
- ≥3 USB-C-to-USB-C cables of varying quality.
- 1× USB-C-to-USB-A OTG adapter.
- 1× regular USB-C-to-USB-A cable.

## Estimated cost if it ships

Adding USB-C reduces "fastest-method" UX wait time by 10–30 seconds versus Wi-Fi Direct on a 1 GB photo library, but adds:
- ~3–5 days of impl time after the spike.
- An extra "USB cable required" path in the in-app onboarding.
- A documented cable-compatibility matrix the user must check.

If the spike clears the throughput bar but cable requirements are too restrictive (e.g. only Thunderbolt 3 cables work), recommend ship-as-fail and add cable-quality testing as a follow-up.
