# `apps/vscode/test/` — Playwright webview harness

Standalone smoke test + screenshot generator for the native CC Pocket VSCode
webview. Runs the real `apps/vscode/media/*` assets in headless Chromium with a
stubbed `acquireVsCodeApi()` so we can drive the UI from synthetic
`ExtensionToWebview` messages — no VSCode needed.

Used for two things:

1. **UI/UX review.** A downstream agent reads the generated screenshots +
   `summary.json` to critique layout, density, and theming.
2. **CI smoke.** Any uncaught error during boot or scenario setup fails the
   run.

## Running

```bash
cd apps/vscode/test
npm install          # installs playwright + downloads chromium
npm run test:webview # runs every scenario, writes ./webview/out/
```

The harness needs `python3` available on PATH (used as the static file
server). Any Python ≥ 3.7 works.

## Outputs

After a successful run you'll have:

- `webview/out/<scenario>.png` — one full-page screenshot per scenario
- `webview/out/summary.json` — machine-readable results

`summary.json` shape:

```json
{
  "generatedAt": "2026-05-21T11:30:00Z",
  "baseUrl": "http://127.0.0.1:54321",
  "scenarios": [
    {
      "name": "connected-empty",
      "passed": true,
      "skipped": false,
      "reason": null,
      "consoleErrors": [],
      "pageErrors": [],
      "screenshot": "connected-empty.png"
    }
  ],
  "totals": { "total": 10, "passed": 8, "skipped": 2, "failed": 0 }
}
```

## Exit codes

- `0` — every scenario produced a screenshot with no uncaught page errors
- `1` — one or more scenarios failed
- `2` — `apps/vscode/media/index.html` is missing (harness can't run)

## How it works

`webview/harness.html` is a thin wrapper that:

- mirrors the element ids from `media/index.html`
- defines `--vscode-*` CSS fallbacks so the dark theme isn't blown away in
  Chromium
- defines `window.acquireVsCodeApi()` *before* loading `media/main.js`
- exposes:
  - `window.__pwMessages` — outbound `postMessage` traffic
  - `window.__deliver(message)` — push a synthetic `ExtensionToWebview` message
  - `window.__pwErrors` — uncaught window-level errors

`webview/run.mjs` spawns `python3 -m http.server` on a free port rooted at
`apps/vscode/`, navigates Playwright to `/test/webview/harness.html`, and runs
each scenario.

## Adding a scenario

Add an entry to `webview/scenarios.mjs`. Each scenario is:

```js
{
  name: 'unique-kebab-name',
  description: 'one-line summary for the summary.json',
  setup: async (page) => {
    await page.evaluate((m) => window.__deliver(m), { type: 'config', ... });
    // …more `__deliver` calls, or Playwright locator clicks…
  },
}
```

If your scenario depends on UI that doesn't exist yet (e.g. a + menu, a mode
selector, a sidebar), throw an error whose message starts with `SKIP:` and the
runner will mark it skipped rather than failed.

## Known gaps (as of this writing)

The native UI currently doesn't ship:

- `data-testid` attributes on any element
- a composer "+" attachment menu
- a permission-mode selector
- a sidebar (and therefore no collapse toggle)

Scenarios `plus-menu-open`, `mode-selector-open`, and `sidebar-collapsed` skip
themselves while these are missing. Once the UI lands, swap the `clickFirst`
fallback selectors for `data-testid` references.
