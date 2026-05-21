# @ccpocket/vscode

VSCode extension that hosts the CC Pocket Flutter web client inside a webview
panel, talking to the local CC Pocket bridge over WebSocket.

## Status

Scaffold only. The panel currently renders a placeholder page; once
`apps/mobile/build/web/index.html` exists, the extension will load that build
automatically (see `src/buildHtml.ts`).

## Build

```bash
cd apps/vscode
npm install
npm run build       # bundles src/extension.ts -> dist/extension.js via esbuild
npm run typecheck   # tsc --noEmit
```

## Run / Debug

1. Open `apps/vscode` in a separate VSCode window.
2. Press `F5` (Run Extension) to launch an Extension Development Host.
3. In the dev host, run **Command Palette → "CC Pocket: Open Panel"**.

## Loading the real Flutter build

```bash
cd apps/mobile
flutter build web
```

The next time you open the panel it will load `apps/mobile/build/web/index.html`
with asset URLs rewritten through `webview.asWebviewUri` and the CSP injected.

## Notes

- `engines.vscode`: `^1.90.0`
- Bundler: esbuild (`npm run build`)
- The webview CSP allows `ws://localhost:*` / `http://localhost:*` so the
  client can reach the bridge running locally. See the comment block in
  `src/buildHtml.ts` for the rationale on each CSP directive.
