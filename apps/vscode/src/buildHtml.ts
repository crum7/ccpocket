import * as crypto from 'node:crypto';
import * as fs from 'node:fs';
import * as vscode from 'vscode';

export interface BuildHtmlConfig {
  bridgeUrl: string;
  bridgeToken: string;
  flutterBuildPath: string;
}

/**
 * Content Security Policy applied to the webview.
 *
 * default-src 'none'
 *   — Deny by default; every resource type must be explicitly allowed.
 * img-src ${webview.cspSource} data: blob:
 *   — Flutter web emits images both as bundled assets (cspSource) and as
 *     data:/blob: URLs (e.g. CanvasKit-rendered or runtime-generated images).
 * style-src ${webview.cspSource} 'unsafe-inline'
 *   — Flutter injects inline styles during bootstrap; 'unsafe-inline' is
 *     unavoidable until Flutter web stops doing that.
 * script-src ${webview.cspSource} 'wasm-unsafe-eval' 'nonce-<nonce>'
 *   — main.dart.js and CanvasKit are served from the extension origin
 *     (cspSource). 'wasm-unsafe-eval' is required for CanvasKit's WASM module.
 *     The nonce permits our single inline config-injection <script>.
 * connect-src ws://localhost:* http://localhost:* ${webview.cspSource}
 *   — The webview talks to the local CC Pocket bridge over WebSocket and
 *     occasionally HTTP. cspSource is kept so Flutter's own fetch() calls for
 *     bundled assets still resolve.
 */
function buildCsp(webview: vscode.Webview, nonce?: string): string {
  const scriptSrc = nonce
    ? `script-src ${webview.cspSource} 'wasm-unsafe-eval' 'nonce-${nonce}'`
    : `script-src ${webview.cspSource} 'wasm-unsafe-eval'`;
  return [
    `default-src 'none'`,
    `img-src ${webview.cspSource} data: blob:`,
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    scriptSrc,
    `connect-src ws://localhost:* http://localhost:* ${webview.cspSource}`,
  ].join('; ');
}

function generateNonce(): string {
  return crypto.randomBytes(16).toString('base64');
}

function placeholderHtml(csp: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="${csp}" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>CC Pocket</title>
  <style>
    body {
      font-family: var(--vscode-font-family, -apple-system, system-ui, sans-serif);
      color: var(--vscode-foreground);
      background: var(--vscode-editor-background);
      padding: 2rem;
      line-height: 1.5;
    }
    code {
      background: var(--vscode-textCodeBlock-background, rgba(127,127,127,0.1));
      padding: 0.1em 0.4em;
      border-radius: 3px;
    }
    .hint { opacity: 0.7; font-size: 0.9em; margin-top: 1.5rem; }
  </style>
</head>
<body>
  <h1>CC Pocket</h1>
  <p>Flutter web build not yet present.</p>
  <p>Run <code>flutter build web</code> in <code>apps/mobile</code> to populate this panel.</p>
  <p class="hint">Once built, this panel will load <code>apps/mobile/build/web/index.html</code> automatically.</p>
</body>
</html>`;
}

/**
 * Returns the HTML to render inside the webview.
 *
 * If the Flutter web build exists, its index.html is loaded and asset URLs
 * are rewritten through `webview.asWebviewUri`. Otherwise a placeholder page
 * is returned.
 *
 * When the Flutter build is loaded, a small inline `<script>` is injected at
 * the top of `<head>` that sets `window.ccpocketConfig` so the Flutter side
 * can pick up the bridge URL / token without any prior message round-trip.
 * The inline script is gated by a per-call CSP nonce.
 */
export function buildHtml(
  webview: vscode.Webview,
  _extensionUri: vscode.Uri,
  mobileWebRoot: vscode.Uri,
  config: BuildHtmlConfig,
): string {
  const indexPath = vscode.Uri.joinPath(mobileWebRoot, 'index.html');

  let raw: string;
  try {
    raw = fs.readFileSync(indexPath.fsPath, 'utf8');
  } catch {
    // No Flutter build → render placeholder with the nonce-less CSP.
    return placeholderHtml(buildCsp(webview));
  }

  const nonce = generateNonce();
  const csp = buildCsp(webview, nonce);

  // Compute the webview base URI for the Flutter build directory. Flutter's
  // bootstrap script resolves assets relative to <base href>, so pointing it
  // at the webview-mapped URI is sufficient to fix up most asset paths.
  const baseHref = webview.asWebviewUri(mobileWebRoot).toString().replace(/\/?$/, '/');

  let html = raw;

  // Inject (or replace) the CSP meta tag.
  const cspMeta = `<meta http-equiv="Content-Security-Policy" content="${csp}" />`;
  if (/<meta[^>]+http-equiv=["']Content-Security-Policy["'][^>]*>/i.test(html)) {
    html = html.replace(
      /<meta[^>]+http-equiv=["']Content-Security-Policy["'][^>]*>/i,
      cspMeta,
    );
  } else {
    html = html.replace(/<head([^>]*)>/i, `<head$1>\n  ${cspMeta}`);
  }

  // Rewrite or inject <base href>.
  if (/<base\s+href=/i.test(html)) {
    html = html.replace(/<base\s+href=["'][^"']*["']\s*\/?>/i, `<base href="${baseHref}">`);
  } else {
    html = html.replace(/<head([^>]*)>/i, `<head$1>\n  <base href="${baseHref}">`);
  }

  // Inject window.ccpocketConfig immediately after <head> so it runs before
  // any Flutter bootstrap script tags. We JSON-encode the whole object so
  // embedded quotes / backslashes can't break out of the script literal.
  const configPayload = {
    bridgeUrl: config.bridgeUrl,
    token: config.bridgeToken && config.bridgeToken.length > 0 ? config.bridgeToken : null,
    source: 'vscode-extension',
  };
  // Escape `</` to prevent premature </script> termination inside the literal.
  const configJson = JSON.stringify(configPayload).replace(/</g, '\\u003c');
  const configScript = `<script nonce="${nonce}">window.ccpocketConfig = ${configJson};</script>`;
  html = html.replace(/<head([^>]*)>/i, `<head$1>\n  ${configScript}`);

  return html;
}
