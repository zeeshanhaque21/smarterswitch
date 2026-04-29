import 'package:go_router/go_router.dart';

import 'conflict_review_screen.dart';
import 'done_screen.dart';
import 'pair_screen.dart';
import 'scan_screen.dart';
import 'select_screen.dart';
import 'transfer_screen.dart';

/// 6-step migration flow per ARCHITECTURE.md § ui/.
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const PairScreen()),
    GoRoute(path: '/select', builder: (_, _) => const SelectScreen()),
    GoRoute(path: '/scan', builder: (_, _) => const ScanScreen()),
    GoRoute(
      path: '/conflicts',
      builder: (_, _) => const ConflictReviewScreen(),
    ),
    GoRoute(path: '/transfer', builder: (_, _) => const TransferScreen()),
    GoRoute(path: '/done', builder: (_, _) => const DoneScreen()),
  ],
);
