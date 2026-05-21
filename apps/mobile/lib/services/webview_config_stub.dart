/// Stub implementation of [WebviewConfig] for non-web platforms.
///
/// This file MUST NOT import any browser-only symbols (`dart:js_interop`,
/// `dart:html`, etc.) — it is compiled into iOS / Android / macOS / Windows
/// / Linux builds where those libraries are unavailable.
library;

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
/// Always returns `null` on non-web platforms.
WebviewConfig? readWebviewConfig() => null;
