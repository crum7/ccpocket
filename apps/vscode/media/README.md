# `media/` — native CC Pocket chat webview

Vanilla ES-module UI shipped inside the VSCode extension webview. No bundler,
no npm deps, no React/Flutter.

- `index.html` — markup skeleton. The extension injects `<base>` + CSP at
  runtime, so this file deliberately omits the CSP meta tag.
- `styles.css` — VSCode-theme-native styling. All colors / fonts come from
  `--vscode-*` CSS variables.
- `main.js` — message dispatch, markdown subset renderer, approval cards,
  composer with Cmd/Ctrl+Enter send. Typed via JSDoc `@typedef` imports from
  `../src/messages.ts` so editors get autocomplete without a build step.

The message contract is defined in `../src/messages.ts`
(`ExtensionToWebview` / `WebviewToExtension`). All inbound messages are
dispatched by `handleMessage` in `main.js`.

## Markdown subset

`renderMarkdown` (see `main.js`) supports:

- paragraphs (split on blank lines)
- fenced code blocks (` ``` … ``` `)
- inline `` `code` ``
- `[label](target)` links — file-shaped targets become click-to-open
- bare path tokens (`foo/bar.ts`, `foo/bar.ts:42`) — also click-to-open

Plain text is escaped via `createTextNode`; we never assign untrusted strings
to `innerHTML`.
