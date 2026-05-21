import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { buildHtml, type BuildHtmlConfig } from './buildHtml.js';
import type { HostToWebview, WebviewToHost } from './messages.js';

let currentPanel: vscode.WebviewPanel | undefined;

interface CCPocketConfig extends BuildHtmlConfig {
  /** Absolute URI for the Flutter web build directory. */
  mobileWebRoot: vscode.Uri;
}

/**
 * Read all `ccpocket.*` settings and resolve `flutterBuildPath` to an absolute
 * URI. Relative paths are resolved against the extension directory so the
 * default `../mobile/build/web` keeps working in the monorepo layout.
 */
function readConfig(extensionUri: vscode.Uri): CCPocketConfig {
  const cfg = vscode.workspace.getConfiguration('ccpocket');
  const bridgeUrl = cfg.get<string>('bridgeUrl', 'ws://localhost:8765');
  const bridgeToken = cfg.get<string>('bridgeToken', '');
  const flutterBuildPath = cfg.get<string>('flutterBuildPath', '../mobile/build/web');

  const mobileWebRoot = path.isAbsolute(flutterBuildPath)
    ? vscode.Uri.file(flutterBuildPath)
    : vscode.Uri.joinPath(extensionUri, ...flutterBuildPath.split(/[\\/]+/));

  return { bridgeUrl, bridgeToken, flutterBuildPath, mobileWebRoot };
}

/**
 * Try to resolve a (possibly relative) file path to an absolute filesystem
 * path. Resolution order:
 *   1. If absolute and exists → return it.
 *   2. Try each workspace folder, preferring the active editor's folder.
 *   3. Fall back to the first workspace folder + path as-is (caller decides).
 */
function resolveFilePath(rawPath: string): string | undefined {
  if (path.isAbsolute(rawPath)) {
    return rawPath;
  }

  const folders = vscode.workspace.workspaceFolders ?? [];
  if (folders.length === 0) {
    return undefined;
  }

  // Order folders so the one containing the active editor is checked first.
  const activeUri = vscode.window.activeTextEditor?.document.uri;
  const ordered = [...folders].sort((a, b) => {
    if (!activeUri) return 0;
    const aMatch = activeUri.fsPath.startsWith(a.uri.fsPath) ? -1 : 0;
    const bMatch = activeUri.fsPath.startsWith(b.uri.fsPath) ? -1 : 0;
    return aMatch - bMatch;
  });

  for (const folder of ordered) {
    const candidate = path.join(folder.uri.fsPath, rawPath);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  // No existing match — fall back to the first workspace folder so the user
  // gets a sensible "file not found" error from showTextDocument instead of
  // silent failure.
  return path.join(ordered[0].uri.fsPath, rawPath);
}

async function openFileInEditor(payload: {
  path: string;
  line?: number;
}): Promise<void> {
  const resolved = resolveFilePath(payload.path);
  if (!resolved) {
    void vscode.window.showWarningMessage(
      `CC Pocket: cannot open "${payload.path}" — no workspace folder.`,
    );
    return;
  }

  try {
    const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(resolved));
    const line = typeof payload.line === 'number' && payload.line > 0 ? payload.line - 1 : 0;
    const position = new vscode.Position(line, 0);
    await vscode.window.showTextDocument(doc, {
      selection: new vscode.Range(position, position),
      preserveFocus: false,
    });
  } catch (err) {
    void vscode.window.showWarningMessage(
      `CC Pocket: failed to open "${payload.path}": ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
}

function postBridgeUrl(webview: vscode.Webview, cfg: CCPocketConfig): void {
  const message: HostToWebview = {
    type: 'bridge-url',
    bridgeUrl: cfg.bridgeUrl,
    token: cfg.bridgeToken && cfg.bridgeToken.length > 0 ? cfg.bridgeToken : null,
  };
  void webview.postMessage(message);
}

export function activate(context: vscode.ExtensionContext): void {
  const disposable = vscode.commands.registerCommand('ccpocket.open', () => {
    if (currentPanel) {
      currentPanel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const config = readConfig(context.extensionUri);

    const panel = vscode.window.createWebviewPanel(
      'ccpocket.panel',
      'CC Pocket',
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [
          // (a) Extension dir — for any static assets we ship with the extension.
          context.extensionUri,
          // (b) Flutter web build output — for index.html, main.dart.js, canvaskit, etc.
          config.mobileWebRoot,
        ],
      },
    );

    panel.webview.html = buildHtml(panel.webview, context.extensionUri, config.mobileWebRoot, config);

    panel.webview.onDidReceiveMessage(
      (message: WebviewToHost | { type?: string; [k: string]: unknown }) => {
        switch (message?.type) {
          case 'open-file': {
            const msg = message as Extract<WebviewToHost, { type: 'open-file' }>;
            if (typeof msg.path === 'string' && msg.path.length > 0) {
              void openFileInEditor({ path: msg.path, line: msg.line });
            }
            break;
          }
          case 'get-bridge-url': {
            // Re-read settings on every request so dynamic post-change fetches
            // see the freshest values.
            const latest = readConfig(context.extensionUri);
            postBridgeUrl(panel.webview, latest);
            break;
          }
          default:
            // Unknown messages are ignored.
            break;
        }
      },
      undefined,
      context.subscriptions,
    );

    // Reload the webview HTML on any ccpocket.* setting change so the injected
    // window.ccpocketConfig and the localResourceRoots-derived assets stay in
    // sync. (localResourceRoots is set at creation time; if flutterBuildPath
    // moves, the user will need to reopen the panel — we surface that via a
    // hint message.)
    const configSub = vscode.workspace.onDidChangeConfiguration((event) => {
      if (!event.affectsConfiguration('ccpocket')) {
        return;
      }
      const latest = readConfig(context.extensionUri);
      if (event.affectsConfiguration('ccpocket.flutterBuildPath')) {
        void vscode.window.showInformationMessage(
          'CC Pocket: flutterBuildPath changed — reopen the panel to pick up the new build location.',
        );
      }
      panel.webview.html = buildHtml(panel.webview, context.extensionUri, latest.mobileWebRoot, latest);
      // Also push the new bridge URL eagerly for any Flutter code still
      // listening on the postMessage channel.
      postBridgeUrl(panel.webview, latest);
    });
    context.subscriptions.push(configSub);

    panel.onDidDispose(
      () => {
        configSub.dispose();
        currentPanel = undefined;
      },
      undefined,
      context.subscriptions,
    );

    currentPanel = panel;
  });

  context.subscriptions.push(disposable);
}

export function deactivate(): void {
  currentPanel?.dispose();
  currentPanel = undefined;
}
