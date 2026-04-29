import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smarterswitch/state/transfer_state.dart';
import 'package:smarterswitch/ui/select_screen.dart';

/// Boots the Select screen with a controlled initial state — bypasses the
/// CategoryProbe (which tries to reach the platform channels) so the test
/// exercises the UX layer in isolation.
Future<void> _pumpWithState(
  WidgetTester tester,
  TransferState seed,
) async {
  final router = GoRouter(
    initialLocation: '/select',
    routes: [
      GoRoute(path: '/select', builder: (_, _) => const SelectScreen()),
      GoRoute(path: '/scan', builder: (_, _) => const Scaffold(body: Text('SCAN'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        transferStateProvider.overrideWith(
          (ref) => _SeededNotifier(seed),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
}

class _SeededNotifier extends TransferStateNotifier {
  _SeededNotifier(TransferState seed) : super() {
    state = seed;
  }
  @override
  Future<void> probeAllCategoryCounts() async {
    // No-op for tests — the seed already provides the statuses we want.
  }
}

void main() {
  group('SelectScreen', () {
    testWidgets('shows all five categories with counts', (tester) async {
      await _pumpWithState(
        tester,
        const TransferState(
          categoryStatuses: {
            DataCategory.sms: CategoryStatus(
              category: DataCategory.sms,
              permissionState: PermissionState.granted,
              count: 5234,
            ),
            DataCategory.callLog: CategoryStatus(
              category: DataCategory.callLog,
              permissionState: PermissionState.granted,
              count: 412,
            ),
            DataCategory.contacts: CategoryStatus(
              category: DataCategory.contacts,
              permissionState: PermissionState.granted,
              count: 187,
            ),
            DataCategory.photos: CategoryStatus(
              category: DataCategory.photos,
              permissionState: PermissionState.granted,
              count: 12345,
              estimatedBytes: 4500000000,
            ),
            DataCategory.calendar: CategoryStatus(
              category: DataCategory.calendar,
              permissionState: PermissionState.granted,
              count: 89,
            ),
          },
        ),
      );

      expect(find.text('SMS / MMS'), findsOneWidget);
      expect(find.text('Call log'), findsOneWidget);
      expect(find.text('Contacts'), findsOneWidget);
      expect(find.text('Photos & videos'), findsOneWidget);
      expect(find.text('Calendar'), findsOneWidget);

      // Counts: 5234 → "5.2K", 412 → "412", 12345 → "12K"
      expect(find.text('5.2K'), findsOneWidget);
      expect(find.text('412'), findsOneWidget);
      expect(find.text('12K'), findsOneWidget);

      // Photo size estimate
      expect(find.textContaining('4.19 GB'), findsOneWidget);
    });

    testWidgets('all five default to selected; bottom CTA reflects total',
        (tester) async {
      await _pumpWithState(
        tester,
        const TransferState(
          categoryStatuses: {
            DataCategory.sms: CategoryStatus(
              category: DataCategory.sms,
              permissionState: PermissionState.granted,
              count: 100,
            ),
            DataCategory.callLog: CategoryStatus(
              category: DataCategory.callLog,
              permissionState: PermissionState.granted,
              count: 50,
            ),
            DataCategory.contacts: CategoryStatus(
              category: DataCategory.contacts,
              permissionState: PermissionState.granted,
              count: 25,
            ),
            DataCategory.photos: CategoryStatus(
              category: DataCategory.photos,
              permissionState: PermissionState.granted,
              count: 10,
            ),
            DataCategory.calendar: CategoryStatus(
              category: DataCategory.calendar,
              permissionState: PermissionState.granted,
              count: 5,
            ),
          },
        ),
      );

      // Total: 100+50+25+10+5 = 190
      expect(find.text('Continue with 5 categories (190 items)'), findsOneWidget);
    });

    testWidgets('permission-denied row shows Tap to allow', (tester) async {
      await _pumpWithState(
        tester,
        const TransferState(
          categoryStatuses: {
            DataCategory.sms: CategoryStatus(
              category: DataCategory.sms,
              permissionState: PermissionState.denied,
            ),
            DataCategory.callLog: CategoryStatus(
              category: DataCategory.callLog,
              permissionState: PermissionState.granted,
              count: 50,
            ),
            DataCategory.contacts: CategoryStatus(
              category: DataCategory.contacts,
              permissionState: PermissionState.granted,
              count: 25,
            ),
            DataCategory.photos: CategoryStatus(
              category: DataCategory.photos,
              permissionState: PermissionState.granted,
              count: 10,
            ),
            DataCategory.calendar: CategoryStatus(
              category: DataCategory.calendar,
              permissionState: PermissionState.granted,
              count: 5,
            ),
          },
        ),
      );

      expect(find.text('Tap to allow'), findsOneWidget);
      expect(find.text('Permission needed for this device'), findsOneWidget);
    });

    testWidgets('Select all toggle flips every checkbox', (tester) async {
      await _pumpWithState(
        tester,
        const TransferState(
          selectedCategories: {DataCategory.sms},
          categoryStatuses: {
            DataCategory.sms: CategoryStatus(
              category: DataCategory.sms,
              permissionState: PermissionState.granted,
              count: 100,
            ),
          },
        ),
      );

      // The header is currently "Select all" because not everything is on.
      expect(find.text('Select all'), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      // Once flipped, label switches to "Deselect all".
      expect(find.text('Deselect all'), findsOneWidget);
    });
  });
}
