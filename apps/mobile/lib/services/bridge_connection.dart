import '../models/messages.dart';
import '../providers/bridge_cubits.dart';
import 'bridge_service.dart';

/// One live connection to a single bridge server.
///
/// Wraps a dedicated [BridgeService] (its own WebSocket) together with a stable
/// [id], a display [label], and the per-connection cubits derived from that
/// bridge's streams (design §3.1). Multiple connections can be alive at once;
/// because each has its own socket, session events never cross-mix.
///
/// The cubits are created lazily on first access, so the app's primary
/// connection (which is read through the global providers, not this object)
/// never allocates duplicates.
class BridgeConnection {
  /// Stable connection id. For machine-backed connections this is the machine's
  /// `uniqueKey` (host:port); the app's initial connection uses [primaryId].
  final String id;

  /// Human-readable label for pickers/headers (machine display name or URL).
  final String label;

  /// This connection's dedicated bridge client.
  final BridgeService bridge;

  BridgeConnection({
    required this.id,
    required this.label,
    required this.bridge,
  });

  /// The id used for the app's initial/primary connection (the existing global
  /// [BridgeService]) before any explicit machine is chosen.
  static const String primaryId = 'primary';

  ConnectionCubit? _connection;
  ActiveSessionsCubit? _activeSessions;
  RecentSessionsCubit? _recentSessions;
  GalleryCubit? _gallery;
  FileListCubit? _fileList;
  ProjectHistoryCubit? _projectHistory;

  ConnectionCubit get connectionCubit => _connection ??= ConnectionCubit(
    BridgeConnectionState.disconnected,
    bridge.connectionStatus,
  );

  ActiveSessionsCubit get activeSessionsCubit =>
      _activeSessions ??= ActiveSessionsCubit(const [], bridge.sessionList);

  RecentSessionsCubit get recentSessionsCubit => _recentSessions ??=
      RecentSessionsCubit(const [], bridge.recentSessionsStream);

  GalleryCubit get galleryCubit =>
      _gallery ??= GalleryCubit(const [], bridge.galleryStream);

  FileListCubit get fileListCubit =>
      _fileList ??= FileListCubit(const [], bridge.fileList);

  ProjectHistoryCubit get projectHistoryCubit => _projectHistory ??=
      ProjectHistoryCubit(const [], bridge.projectHistoryStream);

  /// Close any cubits that were created. Does not touch [bridge] (the owner —
  /// `ConnectionManager` — disposes that).
  Future<void> disposeCubits() async {
    await _connection?.close();
    await _activeSessions?.close();
    await _recentSessions?.close();
    await _gallery?.close();
    await _fileList?.close();
    await _projectHistory?.close();
    _connection = null;
    _activeSessions = null;
    _recentSessions = null;
    _gallery = null;
    _fileList = null;
    _projectHistory = null;
  }
}
