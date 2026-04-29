import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// Loopback Transport for unit tests.
///
/// Two instances share an [InMemoryHub]. One side advertises, the other
/// connects with the same PIN, and a pair of [PairedSession]s come up
/// connected through in-memory channels.
///
/// This lets us exercise everything above the transport layer (frame codec,
/// handshake protocol, WAL replay, manifest exchange, dedup orchestration)
/// without any platform code, and without flakiness from real network or
/// Wi-Fi Direct OEM quirks.
class InMemoryHub {
  final List<_PendingAdvert> _adverts = [];
  final StreamController<DiscoveredPeer> _discoveryEvents =
      StreamController<DiscoveredPeer>.broadcast();

  /// Discover stream: yields currently-advertised peers immediately on
  /// subscribe (so a late subscriber doesn't miss earlier adverts), then
  /// continues with live updates. Real Wi-Fi Direct discovery has the same
  /// "the system already knows about peers it saw before" property.
  Stream<DiscoveredPeer> discover() async* {
    for (final advert in List<_PendingAdvert>.from(_adverts)) {
      yield _toPeer(advert);
    }
    yield* _discoveryEvents.stream;
  }

  void _advertise(_PendingAdvert advert) {
    _adverts.add(advert);
    _discoveryEvents.add(_toPeer(advert));
  }

  void _stopAdvertising(_PendingAdvert advert) {
    _adverts.remove(advert);
  }

  _PendingAdvert? _consumeAdvert(String id) {
    final i = _adverts.indexWhere((a) => a.id == id);
    if (i < 0) return null;
    return _adverts.removeAt(i);
  }

  static DiscoveredPeer _toPeer(_PendingAdvert advert) => DiscoveredPeer(
        id: advert.id,
        displayName: advert.displayName,
        speedClass: TransportSpeedClass.lan,
      );
}

class _PendingAdvert {
  _PendingAdvert({
    required this.id,
    required this.displayName,
    required this.pin,
    required this.onPaired,
  });

  final String id;
  final String displayName;
  final String pin;
  final Completer<_LoopbackSession> onPaired;
}

class InMemoryTransport implements Transport {
  InMemoryTransport({required this.hub, required this.localId});

  final InMemoryHub hub;
  final String localId;

  String? _advertisedDisplayName;
  String? _advertisedPin;
  _PendingAdvert? _pendingAdvert;

  @override
  String get kind => 'In-memory';

  @override
  TransportSpeedClass get speedClass => TransportSpeedClass.lan;

  @override
  Stream<DiscoveredPeer> discover() => hub.discover();

  @override
  Future<void> advertise({required String displayName}) async {
    _advertisedDisplayName = displayName;
  }

  @override
  Future<void> stopAdvertising() async {
    final p = _pendingAdvert;
    if (p != null) {
      hub._stopAdvertising(p);
      _pendingAdvert = null;
    }
    _advertisedDisplayName = null;
    _advertisedPin = null;
  }

  @override
  Future<PairedSession> connect(
    DiscoveredPeer peer, {
    required String pin,
  }) async {
    final advert = hub._consumeAdvert(peer.id);
    if (advert == null) {
      throw StateError('Peer ${peer.id} no longer advertising');
    }
    if (advert.pin != pin) {
      // Reinstate the advert so a retry with the right PIN succeeds.
      hub._advertise(advert);
      throw const PinMismatchException();
    }
    final pair = _LoopbackSession.pair(
      senderName: localId,
      receiverName: advert.displayName,
    );
    advert.onPaired.complete(pair.receiverSide);
    return pair.senderSide;
  }

  @override
  Future<PairedSession> accept({required String pin}) async {
    final displayName = _advertisedDisplayName ?? localId;
    _advertisedPin = pin;
    final completer = Completer<_LoopbackSession>();
    final advert = _PendingAdvert(
      id: localId,
      displayName: displayName,
      pin: _advertisedPin!,
      onPaired: completer,
    );
    _pendingAdvert = advert;
    hub._advertise(advert);
    return completer.future;
  }

  @override
  Future<void> close() async {
    await stopAdvertising();
  }
}

class PinMismatchException implements Exception {
  const PinMismatchException();
  @override
  String toString() => 'PinMismatchException: PIN does not match the receiver';
}

class _LoopbackSession implements PairedSession {
  _LoopbackSession._({
    required this.peerDisplayName,
    required StreamController<Uint8List> outgoing,
    required Stream<Uint8List> incoming,
  })  : _outgoing = outgoing,
        _incoming = incoming;

  static _SessionPair pair({
    required String senderName,
    required String receiverName,
  }) {
    final aToB = StreamController<Uint8List>();
    final bToA = StreamController<Uint8List>();
    final senderSide = _LoopbackSession._(
      peerDisplayName: receiverName,
      outgoing: aToB,
      incoming: bToA.stream,
    );
    final receiverSide = _LoopbackSession._(
      peerDisplayName: senderName,
      outgoing: bToA,
      incoming: aToB.stream,
    );
    return _SessionPair(senderSide: senderSide, receiverSide: receiverSide);
  }

  @override
  final String peerDisplayName;

  final StreamController<Uint8List> _outgoing;
  final Stream<Uint8List> _incoming;

  @override
  Future<void> sendFrame(Uint8List frame) async {
    if (_outgoing.isClosed) {
      throw StateError('Session closed');
    }
    _outgoing.add(frame);
  }

  @override
  Stream<Uint8List> incomingFrames() => _incoming;

  @override
  String get resumeToken => '';

  @override
  Future<void> close() async {
    // Fire-and-forget. Awaiting the underlying close hangs if the peer never
    // subscribed to our outgoing stream (which is normal during teardown and
    // during tests) — single-subscription controllers wait for a listener
    // before signalling done, but at this point we don't expect one.
    if (!_outgoing.isClosed) {
      // ignore: discarded_futures
      _outgoing.close();
    }
  }
}

class _SessionPair {
  _SessionPair({required this.senderSide, required this.receiverSide});
  final _LoopbackSession senderSide;
  final _LoopbackSession receiverSide;
}
