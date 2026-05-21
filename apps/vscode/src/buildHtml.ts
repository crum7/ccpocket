import * as fs from 'node:fs';
import * as vscode from 'vscode';

/**
 * Compose the Content Security Policy for the sidebar webview.
 *
 * The bridge WebSocket connection lives in the **extension host** process,
 * not the webview, so the webview never opens any network sockets of its own
 * — it talks to the host exclusively via `postMessage`. That is why
 * `connect-src` is restricted to `webview.cspSource` and does NOT include
 * `ws://*` or `http://*`.
 */
function buildCsp(webview: vscode.Webview): string {
  return [
    `default-src 'none'`,
    `img-src ${webview.cspSource} data: blob:`,
    `font-src ${webview.cspSource} data:`,
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src ${webview.cspSource}`,
    `connect-src ${webview.cspSource}`,
  ].join('; ');
}

/**
 * Rewrite a single href/src attribute value to a webview-safe URI.
 *
 * Absolute URLs (with a scheme), protocol-relative URLs, anchor links, and
 * root-relative paths are left untouched — only plain relative paths are
 * rewritten through `webview.asWebviewUri`.
 */
function rewriteAttr(
  attrValue: string,
  webview: vscode.Webview,
  mediaRoot: vscode.Uri,
): string {
  if (!attrValue) return attrValue;
  if (/^[a-z][a-z0-9+\-.]*:/i.test(attrValue)) return attrValue;
  if (attrValue.startsWith('//')) return attrValue;
  if (attrValue.startsWith('#')) return attrValue;
  if (attrValue.startsWith('/')) return attrValue;

  const cleaned = attrValue.replace(/^\.\//, '');
  const segments = cleaned.split('/').filter((s) => s.length > 0);
  if (segments.length === 0) return attrValue;
  const assetUri = vscode.Uri.joinPath(mediaRoot, ...segments);
  return webview.asWebviewUri(assetUri).toString();
}

/**
 * Rewrite `href=` / `src=` attributes on `<link>`, `<script>`, and `<img>`
 * tags so they resolve through `webview.asWebviewUri`. We deliberately do
 * not touch `<a href>` because anchor navigation is not allowed in webviews
 * and those URLs may be intentionally external.
 */
function rewriteAssetUrls(
  html: string,
  webview: vscode.Webview,
  mediaRoot: vscode.Uri,
): string {
  html = html.replace(
    /(<link\b[^>]*\bhref\s*=\s*)(["'])([^"']*)\2/gi,
    (_m, prefix: string, quote: string, value: string) =>
      `${prefix}${quote}${rewriteAttr(value, webview, mediaRoot)}${quote}`,
  );
  html = html.replace(
    /(<script\b[^>]*\bsrc\s*=\s*)(["'])([^"']*)\2/gi,
    (_m, prefix: string, quote: string, value: string) =>
      `${prefix}${quote}${rewriteAttr(value, webview, mediaRoot)}${quote}`,
  );
  html = html.replace(
    /(<img\b[^>]*\bsrc\s*=\s*)(["'])([^"']*)\2/gi,
    (_m, prefix: string, quote: string, value: string) =>
      `${prefix}${quote}${rewriteAttr(value, webview, mediaRoot)}${quote}`,
  );
  return html;
}

function escapeHtml(input: string): string {
  return input.replace(/[&<>]/g, (c) =>
    c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;',
  );
}

/**
 * Produce the HTML to set on `webview.html` for the sidebar view.
 *
 * The on-disk `apps/vscode/media/index.html` (built by the UI agent) is
 * loaded verbatim except that we:
 *   1. Inject a CSP `<meta>` tag scoped to the webview origin.
 *   2. Inject a `<base href>` pointing at the webview-mapped `media/` folder.
 *   3. Rewrite relative `href=`/`src=` attributes via `asWebviewUri`.
 *
 * The UI agent's `index.html` deliberately omits CSP and `<base>` so we are
 * the single source of truth for both.
 */
export function buildHtml(
  webview: vscode.Webview,
  extensionUri: vscode.Uri,
): string {
  const mediaRoot = vscode.Uri.joinPath(extensionUri, 'media');
  const indexPath = vscode.Uri.joinPath(mediaRoot, 'index.html');

  let raw: string;
  try {
    raw = fs.readFileSync(indexPath.fsPath, 'utf8');
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    const csp = buildCsp(webview);
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
      padding: 1.5rem;
      line-height: 1.5;
    }
    pre { white-space: pre-wrap; }
  </style>
</head>
<body>
  <h2>CC Pocket</h2>
  <p>Failed to load <code>media/index.html</code>:</p>
  <pre>${escapeHtml(reason)}</pre>
</body>
</html>`;
  }

  const csp = buildCsp(webview);
  // Trailing slash matters: `<base href="x/">` makes `foo.js` resolve to `x/foo.js`.
  const baseHref = webview.asWebviewUri(mediaRoot).toString().replace(/\/?$/, '/');

  let html = raw;

  // (1) CSP meta — replace any existing tag, otherwise insert just inside <head>.
  const cspMeta = `<meta http-equiv="Content-Security-Policy" content="${csp}" />`;
  if (/<meta[^>]+http-equiv\s*=\s*["']Content-Security-Policy["'][^>]*>/i.test(html)) {
    html = html.replace(
      /<meta[^>]+http-equiv\s*=\s*["']Content-Security-Policy["'][^>]*>/i,
      cspMeta,
    );
  } else if (/<head\b[^>]*>/i.test(html)) {
    html = html.replace(/<head\b([^>]*)>/i, `<head$1>\n  ${cspMeta}`);
  } else {
    html = `${cspMeta}\n${html}`;
  }

  // (2) <base href> — same insertion rules.
  const baseTag = `<base href="${baseHref}">`;
  if (/<base\s+href\s*=/i.test(html)) {
    html = html.replace(/<base\s+href\s*=\s*["'][^"']*["']\s*\/?>/i, baseTag);
  } else if (/<head\b[^>]*>/i.test(html)) {
    html = html.replace(/<head\b([^>]*)>/i, `<head$1>\n  ${baseTag}`);
  }

  // (3) Asset URL rewriting — <base> alone covers most cases, but explicit
  // `asWebviewUri` rewriting is the canonical, recommended approach and
  // avoids the cases where a browser ignores <base> for module specifiers.
  html = rewriteAssetUrls(html, webview, mediaRoot);

  return html;
}
