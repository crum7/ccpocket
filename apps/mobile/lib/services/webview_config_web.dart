/// Web implementation of [WebviewConfig].
///
/// Uses the modern `dart:js_interop` API (Flutter 3.11+ / Dart 3.x). The
/// deprecated `dart:js` and `dart:html` libraries are intentionally avoided.
library;

import 'dart:js_interop';

/// Extern view over `window.ccpocketConfig`.
///
/// Fields are typed as nullable [JSString] because we cannot assume the host
/// page actually provides every field. We coerce to Dart [String] manually
/// after reading.
@JS()
@staticInterop
class _CcpocketConfigJs {}

extension _CcpocketConfigJsProps on _CcpocketConfigJs {
  external JSString? get bridgeUrl;
  external JSString? get token;
  external JSString? get source;
}

@JS('ccpocketConfig')
external _CcpocketConfigJs? get _ccpocketConfig;

/// Configuration injected by a host webview (e.g. VSCode extension).
class WebviewConfig {
  const WebviewConfig({required this.bridgeUrl, this.token, this.source});

  /// WebSocket URL of the bridge server, e.g. `ws://localhost:8765`.
  final String bridgeUrl;

  /// Optional API key. When present it is appended as `?token=...` per the
  /// bridge contract (see [BridgeService.autoConnect]).
  final String? token;

  /// Free-form identifier for the host (e.g. `"vscode-extension"`).
  final String? source;
}

/// Reads the injected `window.ccpocketConfig` object.
///
/// Returns `null` when the host page did not inject the config, or when the
/// `bridgeUrl` field is missing / empty (no usable configuration).
WebviewConfig? readWebviewConfig() {
  final raw = _ccpocketConfig;
  if (raw == null) return null;

  final bridgeUrl = raw.bridgeUrl?.toDart;
  if (bridgeUrl == null || bridgeUrl.isEmpty) return null;

  final token = raw.token?.toDart;
  final source = raw.source?.toDart;

  return WebviewConfig(
    bridgeUrl: bridgeUrl,
    token: (token != null && token.isNotEmpty) ? token : null,
    source: (source != null && source.isNotEmpty) ? source : null,
  );
}
