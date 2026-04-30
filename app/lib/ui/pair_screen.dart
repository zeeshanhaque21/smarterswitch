import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/transfer/lan_transport.dart';
import '../core/transfer/transport.dart';
import '../state/transfer_state.dart';

enum _PairPhase {
  rolePicker,
  receiverWaiting, // advertising, showing PIN, waiting for sender to connect
  senderDiscovering, // browsing for peers
  senderEnterPin, // a peer was tapped, asking for the PIN
  connecting, // sender → "PIN OK" round trip in progress
  connected,
  error,
}

class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  _PairPhase _phase = _PairPhase.rolePicker;
  String _statusLine = '';
  LanTransport? _transport;
  StreamSubscription<DiscoveredPeer>? _peerSub;
  final List<DiscoveredPeer> _peers = [];
  DiscoveredPeer? _chosenPeer;
  String _pin = '';
  String _pinInput = '';
  String? _errorMessage;

  @override
  void dispose() {
    _peerSub?.cancel();
    _transport?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- Receiver

  Future<void> _startAsReceiver() async {
    final pin = _generatePin();
    final transport = LanTransport();
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
      setState(() => _statusLine = 'Waiting for the other phone…');
      final session = await transport.accept(pin: pin);
      if (!mounted) return;
      ref.read(transferStateProvider.notifier).setPairedSession(
            session: session,
            transportKind: transport.kind,
            role: DeviceRole.receiver,
          );
      // Hold onto the transport so its server socket stays open for the
      // session lifetime; the screen handing off to /select doesn't tear
      // it down.
      _transport = null;
      setState(() => _phase = _PairPhase.connected);
      if (mounted) context.go('/select');
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
    final transport = LanTransport();
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PairPhase.error;
        _errorMessage = 'Connection failed: $e';
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
      case _PairPhase.connecting:
        return _busy(_statusLine);
      case _PairPhase.connected:
        return _busy('Connected.');
      case _PairPhase.error:
        return _errorState();
    }
  }

  Widget _rolePicker() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text(
            'Move data between two phones — without duplicates.',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Both phones run this app on the same Wi-Fi network. No cloud, no account.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const Spacer(),
          FilledButton.icon(
            icon: const Icon(Icons.upload),
            label: const Text('This phone is the SOURCE'),
            onPressed: _startAsSender,
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.download),
            label: const Text('This phone is the TARGET'),
            onPressed: _startAsReceiver,
          ),
          const SizedBox(height: 32),
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
            'On the other phone, choose SOURCE,',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          Text(
            'pick this device, then enter:',
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
            'Looking for the other phone…',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Make sure the other phone is on the same Wi-Fi and showing a 6-digit PIN.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _peers.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Searching…'),
                      ],
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
