import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../providers/bridge_cubits.dart';
import '../../../services/bridge_connection.dart';
import '../../../services/bridge_service.dart';
import '../../../services/connection_manager.dart';

/// Scopes a subtree to a specific bridge connection, so the session screen it
/// hosts (and everything that reads `BridgeService` / the per-connection cubits
/// from context) talks to the right machine (design §3.1).
///
/// For the primary connection this is a pass-through: the global providers from
/// `main.dart` already point at that bridge, so re-providing would only
/// duplicate them. Only non-primary connections override the providers. If the
/// connection no longer exists it also falls back to the globals.
class PaneScope extends StatelessWidget {
  final String connectionId;
  final Widget child;

  const PaneScope({
    super.key,
    required this.connectionId,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (connectionId == BridgeConnection.primaryId) return child;

    final conn = context.read<ConnectionManager>().byId(connectionId);
    if (conn == null) return child;

    return RepositoryProvider<BridgeService>.value(
      value: conn.bridge,
      child: MultiBlocProvider(
        providers: [
          BlocProvider<ConnectionCubit>.value(value: conn.connectionCubit),
          BlocProvider<ActiveSessionsCubit>.value(
            value: conn.activeSessionsCubit,
          ),
          BlocProvider<RecentSessionsCubit>.value(
            value: conn.recentSessionsCubit,
          ),
          BlocProvider<GalleryCubit>.value(value: conn.galleryCubit),
          BlocProvider<FileListCubit>.value(value: conn.fileListCubit),
          BlocProvider<ProjectHistoryCubit>.value(
            value: conn.projectHistoryCubit,
          ),
        ],
        child: child,
      ),
    );
  }
}
