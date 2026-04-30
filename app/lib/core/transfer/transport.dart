import 'dart:typed_data';

/// Abstract bidirectional channel between two SmarterSwitch instances.
///
/// Concrete implementations:
/// - `WifiDirectTransport` (primary; Android `WifiP2pManager`).
/// - `MdnsTransport` (fallback; same-LAN mDNS over `_smarterswitch._tcp`).
/// - `UsbTransport` (only if the USB-C spike at `docs/usb-c-spike.md`
///   succeeds — wraps Android `UsbManager` host/accessory APIs).
/// - `InMemoryTransport` (loopback; pure Dart; used by unit tests so the
///   protocol layer above is exercised without any platform code).
///
/// All transports surface the same handshake — discover/advertise, then
/// pair via a 6-digit PIN that drops out as TLS-PSK material in the layer
/// above. The protobuf/length-prefixed framing is identical across
/// transports because [PairedSession.sendFrame] / [incomingFrames] is
/// agnostic to how the underlying bytes physically traveled.
abstract class Transport {
  /// User-facing label, e.g. "Wi-Fi Direct", "Local Wi-Fi", "USB-C".
  String get kind;

  /// Approximate link bandwidth class. Used by the UI to set time
  /// estimates and rank transports in the picker.
  TransportSpeedClass get speedClass;

  /// Stream of peers currently visible. Implementations advertise
  /// themselves while listening, so two phones each calling [discover]
  /// see each other.
  Stream<DiscoveredPeer> discover();

  /// Receiver-side: start advertising as a target so a sender can find us.
  /// [displayName] is shown to the sender's user in the discover list.
  Future<void> advertise({required String displayName});

  Future<void> stopAdvertising();

  /// Sender-side: initiate pairing with [peer]. Resolves once the link is up
  /// AND the PIN handshake succeeded (so wrong PIN ⇒ exception, not a session
  /// the caller has to manually verify).
  Future<PairedSession> connect(
    DiscoveredPeer peer, {
    required String pin,
  });

  /// Receiver-side: accept the next incoming pairing request that presents
  /// the matching [pin]. Resolves to a session symmetric to the one returned
  /// by [connect].
  Future<PairedSession> accept({required String pin});

  /// Tear down. Idempotent.
  Future<void> close();
}

enum TransportSpeedClass {
  /// USB-C device-to-device. Highest measured throughput when available.
  usb,

  /// Wi-Fi Direct peer-to-peer; ~80–250 Mbps real-world.
  wifiDirect,

  /// Same-LAN over mDNS; varies with Wi-Fi quality, often 30–80 Mbps.
  lan,

  /// Bluetooth or any other slow path; 1–3 Mbps. Not implemented in v1
  /// but reserved here so future work doesn't churn the enum.
  slow,
}

/// A peer the local transport sees. The set of currently-visible peers
/// changes over time; subscribers to [Transport.discover] receive updates
/// as peers come and go.
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.id,
    required this.displayName,
    required this.speedClass,
  });

  /// Stable for the duration of one discovery run; opaque otherwise.
  final String id;

  /// Set by the peer in [Transport.advertise].
  final String displayName;

  /// What this transport reports for the link to this peer. Not necessarily
  /// the global transport's speedClass — e.g. an mDNS transport might
  /// report `lan`, but if the LAN happens to be a 2.4 GHz router the real
  /// throughput is closer to `slow`. Kept as the transport's nominal label.
  final TransportSpeedClass speedClass;

  @override
  String toString() => 'DiscoveredPeer($displayName, $id, $speedClass)';
}

/// Thrown by [Transport.connect] when the PIN the sender provided doesn't
/// match what the receiver is expecting. Distinct from generic connection
/// errors so the UI can offer a "try again" affordance rather than a full
/// reset.
class PinMismatchException implements Exception {
  const PinMismatchException();
  @override
  String toString() => 'PinMismatchException: PIN does not match the receiver';
}

/// Authenticated, length-prefixed-frame-capable bidirectional channel.
abstract class PairedSession {
  String get peerDisplayName;

  /// Send one frame. The transport handles length-prefix framing; the caller
  /// just supplies the encoded payload.
  Future<void> sendFrame(Uint8List frame);

  /// Hot stream of received frames. Closes when the peer disconnects or
  /// [close] is called.
  Stream<Uint8List> incomingFrames();

  /// Resume token: opaque blob persisted by the protocol layer so a re-pair
  /// after a drop hands the receiver back its progress (the WAL watermark).
  /// Empty string if this is the first session with this peer.
  String get resumeToken;

  Future<void> close();
}
