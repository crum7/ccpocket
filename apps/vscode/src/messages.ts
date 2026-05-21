/**
 * Message contract between the VSCode extension host and the Flutter webview.
 *
 * Both the extension and the Flutter side must stay in sync with these
 * definitions. The Flutter side currently mirrors these by hand; once we
 * have codegen in place this file can be the single source of truth.
 */

/** Messages the webview (Flutter app) posts to the extension host. */
export type WebviewToHost =
  | { type: 'get-bridge-url' }
  | { type: 'open-file'; path: string; line?: number };

/** Messages the extension host posts back to the webview. */
export type HostToWebview =
  | { type: 'bridge-url'; bridgeUrl: string; token: string | null };
