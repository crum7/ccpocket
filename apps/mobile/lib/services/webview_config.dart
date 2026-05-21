/// Reads optional JavaScript-injected configuration from the host page when
/// the Flutter app is running as Flutter web inside an embedding webview
/// (for example, the CCPocket VSCode extension).
///
/// The host page is expected to set, BEFORE `main.dart.js` loads:
///
/// ```js
/// window.ccpocketConfig = {
///   bridgeUrl: "ws://localhost:8765",
///   token: null,
///   source: "vscode-extension",
/// };
/// ```
///
/// The `token` field is optional and may also be a string holding the API
/// key when the bridge was started with `BRIDGE_API_KEY`.
///
/// On non-web platforms (iOS, Android, macOS, Windows, Linux), the stub
/// implementation always returns `null` so the regular discovery / manual
/// entry UX remains unchanged.
library;

export 'webview_config_stub.dart'
    if (dart.library.js_interop) 'webview_config_web.dart';
