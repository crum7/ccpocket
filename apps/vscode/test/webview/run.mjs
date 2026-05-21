#!/usr/bin/env node
// Playwright runner for the CC Pocket webview harness.
//
// What it does
// ------------
//   1. Spawns `python3 -m http.server` on a free port, serving the parent
//      `apps/vscode/` directory so harness.html can fetch the sibling
//      `media/*` assets over http (ES modules don't load reliably over
//      file:// in headless Chromium).
//   2. Launches headless Chromium via Playwright.
//   3. For each scenario in scenarios.mjs:
//        - navigates to /test/webview/harness.html
//        - runs setup(page)
//        - waits a short settle interval for animations
//        - takes a full-page screenshot into ./out/<name>.png
//        - records page errors + console errors
//        - "SKIP:" errors thrown by setup mark the scenario as skipped (not
//          failed) so missing UI pieces don't redden CI.
//   4. Writes summary.json next to the screenshots.
//   5. Exits 0 iff every non-skipped scenario produced a screenshot with 0
//      page errors; non-zero otherwise.
//
// Run with: `node apps/vscode/test/webview/run.mjs`

import { spawn } from 'node:child_process';
import { createServer, connect as netConnect } from 'node:net';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

import { scenarios } from './scenarios.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
// apps/vscode/test/webview/run.mjs -> apps/vscode/
const VSCODE_ROOT = path.resolve(__dirname, '..', '..');
const OUT_DIR = path.join(__dirname, 'out');
const SETTLE_MS = 500;

/** Find a free TCP port by binding to :0 and reading back. */
async function findFreePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      if (!addr || typeof addr === 'string') {
        srv.close();
        reject(new Error('failed to acquire port'));
        return;
      }
      const port = addr.port;
      srv.close(() => resolve(port));
    });
  });
}

/** Start `python3 -m http.server PORT` rooted at VSCODE_ROOT. Resolves when the
 *  socket starts accepting connections. */
async function startHttpServer(port) {
  const proc = spawn('python3', ['-m', 'http.server', String(port), '--bind', '127.0.0.1'], {
    cwd: VSCODE_ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  proc.stdout.on('data', () => {});
  proc.stderr.on('data', () => {});
  proc.on('error', (err) => {
    console.error('[http.server] failed to start:', err);
  });

  // Poll until the port answers a TCP connect.
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      await new Promise((resolve, reject) => {
        const test = netConnect(port, '127.0.0.1', () => {
          test.end();
          resolve();
        });
        test.on('error', reject);
      });
      return proc;
    } catch {
      await sleep(80);
    }
  }
  throw new Error(`http.server did not come up on :${port}`);
}

function killProc(proc) {
  if (!proc || proc.killed) return;
  try {
    proc.kill('SIGTERM');
  } catch {
    /* noop */
  }
}

async function loadPlaywright() {
  try {
    return await import('playwright');
  } catch (err) {
    console.error(
      'playwright is not installed. Run `npm install` in apps/vscode/test/ first.',
    );
    throw err;
  }
}

async function main() {
  // Fail fast if the upstream media/ assets are missing — the harness is
  // useless without them.
  const mediaIndex = path.join(VSCODE_ROOT, 'media', 'index.html');
  if (!existsSync(mediaIndex)) {
    console.error(
      `Required asset missing: ${mediaIndex}\n` +
        'This harness is meant to run on a branch that contains apps/vscode/media/*.',
    );
    process.exit(2);
  }

  await rm(OUT_DIR, { recursive: true, force: true });
  await mkdir(OUT_DIR, { recursive: true });

  const port = await findFreePort();
  const httpProc = await startHttpServer(port);
  const baseUrl = `http://127.0.0.1:${port}`;

  const { chromium } = await loadPlaywright();
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 480, height: 800 }, // narrow sidebar-ish width
    deviceScaleFactor: 2,
  });

  const results = [];

  try {
    for (const scenario of scenarios) {
      const page = await context.newPage();
      const consoleErrors = [];
      const pageErrors = [];

      page.on('console', (msg) => {
        if (msg.type() === 'error') consoleErrors.push(msg.text());
      });
      page.on('pageerror', (err) => {
        pageErrors.push(String(err && err.message ? err.message : err));
      });

      const screenshot = path.join(OUT_DIR, `${scenario.name}.png`);
      let passed = false;
      let skipped = false;
      let reason = null;

      try {
        await page.goto(`${baseUrl}/test/webview/harness.html`, {
          waitUntil: 'load',
        });
        // Wait for main.js to finish boot — it sends 'ready'.
        await page.waitForFunction(
          () => Array.isArray(window.__pwMessages) &&
            window.__pwMessages.some((m) => m && m.type === 'ready'),
          null,
          { timeout: 3000 },
        );

        await scenario.setup(page);
        await sleep(SETTLE_MS);
        await page.screenshot({ path: screenshot, fullPage: true });

        // Also pick up any errors the harness recorded internally (window
        // 'error' events Playwright doesn't always surface).
        const harnessErrors = await page.evaluate(() => window.__pwErrors || []);
        for (const e of harnessErrors) pageErrors.push(`(harness) ${e.message}`);

        passed = pageErrors.length === 0;
      } catch (err) {
        const msg = err && err.message ? err.message : String(err);
        if (msg.startsWith('SKIP:')) {
          skipped = true;
          passed = true; // skipped counts as not-failing for exit code
          reason = msg.slice('SKIP:'.length).trim();
          // Still take a screenshot of whatever state we managed to reach.
          try {
            await page.screenshot({ path: screenshot, fullPage: true });
          } catch {
            /* noop */
          }
        } else {
          reason = msg;
          try {
            await page.screenshot({ path: screenshot, fullPage: true });
          } catch {
            /* noop */
          }
        }
      } finally {
        await page.close().catch(() => {});
      }

      results.push({
        name: scenario.name,
        description: scenario.description || null,
        passed,
        skipped,
        reason,
        consoleErrors,
        pageErrors,
        screenshot: path.relative(OUT_DIR, screenshot),
      });

      const tag = skipped ? 'SKIP' : passed ? 'PASS' : 'FAIL';
      console.log(`[${tag}] ${scenario.name}${reason ? ` — ${reason}` : ''}`);
    }
  } finally {
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
    killProc(httpProc);
  }

  const summary = {
    generatedAt: new Date().toISOString(),
    baseUrl,
    scenarios: results,
    totals: {
      total: results.length,
      passed: results.filter((r) => r.passed && !r.skipped).length,
      skipped: results.filter((r) => r.skipped).length,
      failed: results.filter((r) => !r.passed).length,
    },
  };

  await writeFile(
    path.join(OUT_DIR, 'summary.json'),
    JSON.stringify(summary, null, 2) + '\n',
    'utf8',
  );
  console.log(`\nWrote ${path.join(OUT_DIR, 'summary.json')}`);
  console.log(
    `Totals: ${summary.totals.passed} passed, ${summary.totals.skipped} skipped, ${summary.totals.failed} failed.`,
  );

  if (summary.totals.failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
