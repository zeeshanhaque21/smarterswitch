import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/transfer/lan_transport.dart';
import '../core/transfer/secure_socket_session.dart';
import '../core/transfer/transport.dart';
import '../core/transfer/wifi_direct_transport.dart';
import '../state/transfer_state.dart';

enum _PairPhase {
  rolePicker,
  receiverWaiting, // advertising, showing PIN, waiting for sender to connect
  senderDiscovering, // browsing for peers
  senderEnterPin, // a peer was tapped, asking for the PIN
  senderManualEntry, // typing host:port + PIN (no discovery)
  connecting, // sender → "PIN OK" round trip in progress
  connected,
  error,
}

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

/// Numbered "Step N: ..." row — used in the role picker so the workflow
/// reads as a sequence rather than two equally-weighted buttons.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});
  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Text(
            number,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ),
      ],
    );
  }
}

class _PairScreenState extends ConsumerState<PairScreen> {
  _PairPhase _phase = _PairPhase.rolePicker;
  String _statusLine = '';
  Transport? _transport;
  StreamSubscription<DiscoveredPeer>? _peerSub;
  final List<DiscoveredPeer> _peers = [];
  DiscoveredPeer? _chosenPeer;
  String _pin = '';
  String _pinInput = '';
  String? _errorMessage;

  /// Receiver-side: this device's IPv4 on the current Wi-Fi. Populated
  /// after we successfully bind the TCP server in advertise(). Surfaced
  /// on the receiverWaiting screen so the sender's user can type it in
  /// when discovery isn't available (no shared mDNS, Wi-Fi Direct
  /// flaky, etc).
  String? _receiverIp;
  int? _receiverPort;

  /// Sender-side manual-entry fields.
  String _manualHost = '';
  String _manualPort = '';

  /// Defaults to Wi-Fi Direct (works without a shared router). User can
  /// flip the link in the role picker to use the LAN-mDNS path instead.
  bool _useWifiDirect = true;
  bool _wifiDirectAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final available = await WifiDirectTransport.isAvailable();
      if (!mounted) return;
      setState(() {
        _wifiDirectAvailable = available;
        // If the device doesn't support Wi-Fi Direct at all, default to LAN.
        if (!available) _useWifiDirect = false;
      });
    });
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _transport?.close();
    super.dispose();
  }

  Transport _buildTransport() =>
      _useWifiDirect ? WifiDirectTransport() : LanTransport();

  /// Wi-Fi Direct + Wi-Fi-LAN discovery both want fine-location on API ≤ 32
  /// (legacy NEARBY_WIFI_DEVICES gate) and the new NEARBY_WIFI_DEVICES on
  /// API 33+. Request both proactively before starting either transport so
  /// discovery doesn't silently fail.
  Future<void> _requestNetworkPermissions() async {
    try {
      await Future.wait([
        Permission.locationWhenInUse.request(),
        Permission.nearbyWifiDevices.request(),
      ]);
    } catch (_) {
      // Older devices may not support Permission.nearbyWifiDevices; the
      // wrapper throws PlatformException. Either way, the transport is
      // resilient — it'll fail at discoverPeers if perms are missing and
      // the user can fall back via the LAN link.
    }
  }

  // ---------------------------------------------------------------- Receiver

  Future<void> _startAsReceiver() async {
    await _requestNetworkPermissions();
    final pin = _generatePin();
    final transport = _buildTransport();
    setState(() {
      _phase = _PairPhase.receiverWaiting;
      _pin = pin;
      _transport = transport;
      _statusLine = 'Setting up…';
      _errorMessage = null;
    });
    try {
      final myName = await _myDeviceName();
      await transport.advertise(displayName: myName);
      if (!mounted) return;
      // Capture the bound IP+port so the receiver-waiting screen can
      // show them for manual pairing (sender types these in if
      // discovery isn't available). Only LanTransport exposes the
      // bound port — Wi-Fi Direct uses a fixed port + GO IP that the
      // sender already knows.
      String? ip;
      int? port;
      if (transport is LanTransport) {
        port = transport.boundPort;
        try {
          ip = await NetworkInfo().getWifiIP();
        } catch (_) {/* permission or no Wi-Fi — leave ip null */}
      }
      setState(() {
        _statusLine = 'Waiting for the other phone…';
        _receiverIp = ip;
        _receiverPort = port;
      });
      final session = await transport.accept(pin: pin);
      if (!mounted) return;
      ref.read(transferStateProvider.notifier).setPairedSession(
            session: session,
            transportKind: transport.kind,
            role: DeviceRole.receiver,
          );
      // Hold onto the transport so its server socket stays open for the
      // session lifetime; the screen handing off doesn't tear it down.
      _transport = null;
      setState(() => _phase = _PairPhase.connected);
      // The NEW phone waits for the OLD phone to send a manifest. It does
      // NOT pick categories itself — that was the v0.2.2 bug ("both phones
      // show as target").
      if (mounted) context.go('/waiting');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage = 'Pairing failed: $e';
      });
    }
  }

  // ------------------------------------------------------------------ Sender

  Future<void> _startAsSender() async {
    await _requestNetworkPermissions();
    final transport = _buildTransport();
    setState(() {
      _phase = _PairPhase.senderDiscovering;
      _peers.clear();
      _transport = transport;
      _statusLine = 'Looking for the other phone…';
      _errorMessage = null;
    });
    try {
      _peerSub = transport.discover().listen((peer) {
        if (!mounted) return;
        if (_peers.any((p) => p.id == peer.id)) return;
        setState(() => _peers.add(peer));
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _phase = _PairPhase.error;
          _errorMessage = 'Discovery failed: $e';
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage = 'Discovery failed: $e';
      });
    }
  }

  Future<void> _attemptConnect() async {
    final transport = _transport;
    final peer = _chosenPeer;
    if (transport == null || peer == null) return;
    setState(() {
      _phase = _PairPhase.connecting;
      _statusLine = 'Connecting to ${peer.displayName}…';
      _errorMessage = null;
    });
    try {
      final session = await transport.connect(peer, pin: _pinInput);
      if (!mounted) return;
      ref.read(transferStateProvider.notifier).setPairedSession(
            session: session,
            transportKind: transport.kind,
            role: DeviceRole.sender,
          );
      _transport = null;
      setState(() => _phase = _PairPhase.connected);
      if (mounted) context.go('/select');
    } on PinMismatchException {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.senderEnterPin;
        _errorMessage = 'PIN didn\'t match. Try again.';
      });
    } on HandshakeTimeoutException {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage =
            'The other phone went silent during the handshake.\n\n'
            'Force-stop SmarterSwitch on both phones (Settings → Apps → '
            'SmarterSwitch → Force Stop) and try again. If you used '
            'Wi-Fi Direct, also disconnect any peers in Settings → '
            'Wi-Fi → Wi-Fi Direct.';
      });
    } catch (e) {
      if (!mounted) return;
      // Connection-refused / no-route-to-host on a Wi-Fi Direct interface
      // address means we're hitting a stale P2P advertisement. v0.13.1
      // filters those at discovery time, but if anything slips through,
      // surface a hint so the user knows what to clear.
      final msg = e.toString();
      final hint = msg.contains('Connection refused') ||
              msg.contains('No route to host')
          ? '\n\nIf this keeps happening: open Settings → Wi-Fi → Wi-Fi '
              'Direct, disconnect any peers, then force-stop SmarterSwitch '
              'on both phones and try again.'
          : '';
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage = 'Connection failed: $e$hint';
      });
    }
  }

  // ----------------------------------------------------------------- Helpers

  String _generatePin() {
    final r = math.Random.secure();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  Future<String> _myDeviceName() async {
    // No device-info plugin yet; fall back to the OS hostname which gives
    // useful labels on most Android devices ("pixel-7", "samsung-s23").
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'SmarterSwitch';
    }
  }

  /// Sender-side: enter the manual-pairing form. No discovery, no
  /// Wi-Fi Direct probing — straight to a TCP connect on a host:port
  /// the user types in.
  void _enterManualMode() {
    setState(() {
      _phase = _PairPhase.senderManualEntry;
      _manualHost = '';
      _manualPort = '';
      _pinInput = '';
      _errorMessage = null;
    });
  }

  Future<void> _attemptManualConnect() async {
    final host = _manualHost.trim();
    final port = int.tryParse(_manualPort.trim());
    if (host.isEmpty || port == null) {
      setState(() => _errorMessage =
          'Enter the IP address and port shown on the other phone.');
      return;
    }
    setState(() {
      _phase = _PairPhase.connecting;
      _statusLine = 'Connecting to $host:$port…';
      _errorMessage = null;
    });
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );
      final session = await SecureSocketSession.handshakeAsConnector(
        socket: socket,
        peerDisplayName: '$host:$port',
        pin: _pinInput,
      );
      if (!mounted) return;
      ref.read(transferStateProvider.notifier).setPairedSession(
            session: session,
            transportKind: 'Manual',
            role: DeviceRole.sender,
          );
      setState(() => _phase = _PairPhase.connected);
      if (mounted) context.go('/select');
    } on PinMismatchException {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.senderManualEntry;
        _errorMessage = 'PIN didn\'t match. Try again.';
      });
    } on HandshakeTimeoutException {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage =
            'The other phone didn\'t respond.\n\n'
            'Check both phones are on the same Wi-Fi (or that one phone\'s '
            'hotspot is enabled and the other has joined it), and that the '
            'IP and port match what\'s shown on the receiver.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage = 'Connection failed: $e';
      });
    }
  }

  Future<void> _resetToRolePicker() async {
    await _peerSub?.cancel();
    _peerSub = null;
    await _transport?.close();
    _transport = null;
    if (!mounted) return;
    setState(() {
      _phase = _PairPhase.rolePicker;
      _peers.clear();
      _chosenPeer = null;
      _pin = '';
      _pinInput = '';
      _errorMessage = null;
      _statusLine = '';
    });
  }

  // --------------------------------------------------------------- Rendering

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SmarterSwitch'),
        leading: _phase == _PairPhase.rolePicker
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _resetToRolePicker,
              ),
      ),
      body: SafeArea(child: _bodyForPhase()),
    );
  }

  Widget _bodyForPhase() {
    switch (_phase) {
      case _PairPhase.rolePicker:
        return _rolePicker();
      case _PairPhase.receiverWaiting:
        return _receiverWaiting();
      case _PairPhase.senderDiscovering:
        return _senderDiscovering();
      case _PairPhase.senderEnterPin:
        return _senderEnterPin();
      case _PairPhase.senderManualEntry:
        return _senderManualEntry();
      case _PairPhase.connecting:
        return _busy(_statusLine);
      case _PairPhase.connected:
        return _busy('Connected.');
      case _PairPhase.error:
        return _errorState();
    }
  }

  Widget _rolePicker() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Text(
            'Move data between two phones — without duplicates.',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          // Explicit two-step workflow so users don't think both phones do
          // the same thing. Same-screen-on-both was confusing in v0.2.0.
          _Step(
            number: '1',
            text: _useWifiDirect
                ? 'Open SmarterSwitch on both phones. No shared Wi-Fi '
                    'network needed — Wi-Fi Direct pairs them peer-to-peer.'
                : 'Open SmarterSwitch on both phones — and put them on the '
                    'same Wi-Fi network.',
          ),
          const SizedBox(height: 12),
          _Step(
            number: '2',
            text: 'On EACH phone, tap a different role below. One phone is '
                'the OLD phone (the source); the other is the NEW phone '
                '(the target).',
          ),
          const Spacer(),
          Text(
            'What is THIS phone?',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.phone_android),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Text('OLD phone',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('Has the data — sends to the other phone',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            onPressed: _startAsSender,
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.phone_iphone),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Text('NEW phone',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('Receives the data — shows a PIN to type on the old phone',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
            onPressed: _startAsReceiver,
          ),
          const SizedBox(height: 16),
          if (_wifiDirectAvailable)
            Center(
              child: TextButton(
                onPressed: () =>
                    setState(() => _useWifiDirect = !_useWifiDirect),
                child: Text(
                  _useWifiDirect
                      ? 'Already on the same Wi-Fi? Use that instead'
                      : 'Use Wi-Fi Direct (no shared network needed)',
                ),
              ),
            ),
          Center(
            child: TextButton(
              onPressed: _enterManualMode,
              child: const Text(
                'Discovery not working? Connect manually →',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiverWaiting() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          Text(
            'On the OLD phone, pick this device from the list,',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          Text(
            'then type this 6-digit PIN:',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _pin,
              style: const TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(_statusLine),
            ],
          ),
          if (_receiverIp != null && _receiverPort != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Text(
              'Or type this on the OLD phone:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            SelectableText(
              '${_receiverIp!}:${_receiverPort!}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap "Connect manually" on the OLD phone, enter the IP and port '
              'above, plus the PIN — works whenever both phones share a Wi-Fi.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _senderManualEntry() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Text(
            'Type the IP, port, and PIN shown on the NEW phone',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'IP address',
              hintText: '192.168.1.50',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (v) => setState(() => _manualHost = v),
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Port',
              hintText: '54321',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            onChanged: (v) => setState(() => _manualPort = v),
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'PIN',
              hintText: '123456',
              errorText: _errorMessage,
            ),
            keyboardType: TextInputType.number,
            maxLength: 6,
            onChanged: (v) => setState(() {
              _pinInput = v.replaceAll(RegExp(r'[^0-9]'), '');
            }),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (_manualHost.trim().isNotEmpty &&
                    _manualPort.trim().isNotEmpty &&
                    _pinInput.length == 6)
                ? _attemptManualConnect
                : null,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Widget _senderDiscovering() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text(
            'Looking for the NEW phone…',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'On the NEW phone, tap "NEW phone" so it starts showing a 6-digit PIN. '
            'Both phones must be on the same Wi-Fi network.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _peers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            'Searching…',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No phones found yet. The other phone needs to '
                            'have tapped "NEW phone" and be showing a PIN.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _peers.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final peer = _peers[i];
                      return ListTile(
                        leading: const Icon(Icons.smartphone),
                        title: Text(peer.displayName),
                        subtitle: Text(peer.id),
                        onTap: () {
                          setState(() {
                            _chosenPeer = peer;
                            _pinInput = '';
                            _phase = _PairPhase.senderEnterPin;
                          });
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _senderEnterPin() {
    final peer = _chosenPeer;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Text(
            'Enter the 6-digit PIN shown on ${peer?.displayName ?? "the other phone"}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: '123456',
              errorText: _errorMessage,
            ),
            style: const TextStyle(
              fontSize: 24,
              letterSpacing: 4,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            onChanged: (v) => setState(() {
              _pinInput = v.replaceAll(RegExp(r'[^0-9]'), '');
            }),
            onSubmitted: (_) {
              if (_pinInput.length == 6) _attemptConnect();
            },
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _pinInput.length == 6 ? _attemptConnect : null,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Widget _busy(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message),
        ],
      ),
    );
  }

  Widget _errorState() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.error_outline,
              size: 56, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? 'Something went wrong.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _resetToRolePicker,
            child: const Text('Start over'),
          ),
        ],
      ),
    );
  }
}
