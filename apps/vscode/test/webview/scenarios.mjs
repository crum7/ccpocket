// Scenarios for the Playwright webview harness.
//
// Each entry is { name, setup(page) } where `setup` posts a sequence of
// synthetic ExtensionToWebview events via `window.__deliver(...)` and/or
// drives the UI via Playwright locators.
//
// Selector strategy
// -----------------
// The native UI (apps/vscode/media/main.js as of feat/native-vscode-extension)
// does *not* yet expose `data-testid` attributes, and does not yet implement a
// "+ menu", a "mode selector", a sidebar, or a sidebar-collapse toggle. Where
// a scenario depends on UI that doesn't exist, the helper functions below
// detect-and-skip rather than hard-fail. The runner records skipped scenarios
// as { passed: true, skipped: true, reason: "..." } so the UI-review agent
// can see what's missing without the smoke test reddening CI.

/**
 * Click the first element matching any of `selectors`. Returns true if a
 * click happened, false if nothing matched within the per-selector timeout.
 * Uses short timeouts because we already know the page is settled.
 */
async function clickFirst(page, selectors, { timeout = 250 } = {}) {
  for (const sel of selectors) {
    const loc = page.locator(sel).first();
    try {
      if ((await loc.count()) > 0 && (await loc.isVisible())) {
        await loc.click({ timeout });
        return true;
      }
    } catch {
      // try next selector
    }
  }
  return false;
}

/** Deliver one ExtensionToWebview message into the page. */
async function deliver(page, message) {
  await page.evaluate((m) => window.__deliver(m), message);
}

/** Deliver many messages in order. */
async function deliverAll(page, messages) {
  for (const m of messages) await deliver(page, m);
}

const CONFIG_DEFAULT = {
  type: 'config',
  bridgeUrl: 'ws://localhost:8765',
  hasToken: true,
  allowedDirs: ['/Users/dev/myproj', '/Users/dev/another'],
  defaultProjectPath: '/Users/dev/myproj',
};

const CONNECTED = { type: 'connection-state', state: { state: 'connected' } };

export const scenarios = [
  // ---------------------------------------------------------------------
  {
    name: 'idle-no-config',
    description: 'First boot — no config delivered yet, status dot idle.',
    setup: async () => {
      // Nothing — we just let the page render its initial state.
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'connected-empty',
    description: 'Config delivered + connection-state connected, no messages.',
    setup: async (page) => {
      await deliverAll(page, [CONFIG_DEFAULT, CONNECTED]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'chat-with-streaming',
    description: 'User + streaming assistant reply built up via stream-delta.',
    setup: async (page) => {
      await deliverAll(page, [
        CONFIG_DEFAULT,
        CONNECTED,
        {
          type: 'session-active',
          sessionId: 'sess-1234abcd',
          projectPath: '/Users/dev/myproj',
          status: 'running',
        },
        {
          type: 'chat-append',
          message: {
            id: 'u1',
            role: 'user',
            text: 'How does `apps/vscode/src/messages.ts:1` define ExtensionToWebview?',
          },
        },
        {
          type: 'chat-append',
          message: { id: 'a1', role: 'assistant', text: '' },
        },
        { type: 'stream-delta', messageId: 'a1', delta: 'It defines ' },
        { type: 'stream-delta', messageId: 'a1', delta: 'a discriminated union with ' },
        { type: 'stream-delta', messageId: 'a1', delta: '`type` as the tag.\n\n' },
        {
          type: 'stream-delta',
          messageId: 'a1',
          delta: '```ts\nexport type ExtensionToWebview = { type: "config"; ... };\n```\n',
        },
        {
          type: 'result',
          sessionId: 'sess-1234abcd',
          cost: 0.0123,
          duration: 2400,
        },
      ]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'approval-pending',
    description: 'Approval card rendered with realistic tool input.',
    setup: async (page) => {
      await deliverAll(page, [
        CONFIG_DEFAULT,
        CONNECTED,
        {
          type: 'session-active',
          sessionId: 'sess-1234abcd',
          projectPath: '/Users/dev/myproj',
          status: 'waiting_approval',
        },
        {
          type: 'chat-append',
          message: { id: 'u-approve', role: 'user', text: 'List files in src/' },
        },
        {
          type: 'approval-request',
          approval: {
            sessionId: 'sess-1234abcd',
            id: 'tool-1',
            tool: 'Bash',
            input: { command: 'ls -la apps/vscode/src', description: 'List source files' },
          },
        },
      ]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'plus-menu-open',
    description: 'Click the + menu in the composer. UI not yet implemented — expected to skip.',
    setup: async (page) => {
      await deliverAll(page, [CONFIG_DEFAULT, CONNECTED]);
      const clicked = await clickFirst(page, [
        '[data-testid="composer-plus"]',
        'button[aria-label="Add attachment"]',
        'button[title="Add attachment"]',
        '.composer-plus',
      ]);
      if (!clicked) {
        // Signal to the runner that the dependent UI is missing.
        throw new Error('SKIP: no composer + button found (UI not yet implemented)');
      }
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'mode-selector-open',
    description: 'Open the permission-mode selector. UI not yet implemented — expected to skip.',
    setup: async (page) => {
      await deliverAll(page, [CONFIG_DEFAULT, CONNECTED]);
      const clicked = await clickFirst(page, [
        '[data-testid="mode-selector"]',
        'button[aria-label="Permission mode"]',
        '.mode-selector',
      ]);
      if (!clicked) {
        throw new Error('SKIP: no mode-selector control found (UI not yet implemented)');
      }
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'sidebar-with-recent',
    description: 'Session list with recent + project history populated.',
    setup: async (page) => {
      await deliverAll(page, [
        CONFIG_DEFAULT,
        CONNECTED,
        {
          type: 'session-list',
          sessions: [
            {
              sessionId: 's-active-001',
              projectPath: '/Users/dev/myproj',
              firstPrompt: 'Refactor the bridge client to share session state',
              lastModified: '2026-05-21T11:30:00Z',
            },
            {
              sessionId: 's-active-002',
              projectPath: '/Users/dev/myproj',
              firstPrompt: 'Add tests for the markdown subset renderer',
              lastModified: '2026-05-21T10:15:00Z',
            },
          ],
          recent: [
            {
              sessionId: 's-recent-001',
              projectPath: '/Users/dev/another',
              firstPrompt: 'Fix the iOS build script on Apple Silicon',
              lastModified: '2026-05-20T18:00:00Z',
            },
            {
              sessionId: 's-recent-002',
              projectPath: '/Users/dev/myproj',
              firstPrompt: 'Investigate why the websocket reconnects in a tight loop',
              lastModified: '2026-05-20T09:42:00Z',
            },
          ],
          projects: ['/Users/dev/myproj', '/Users/dev/another', '/Users/dev/third'],
        },
        {
          type: 'session-active',
          sessionId: 's-active-001',
          projectPath: '/Users/dev/myproj',
          status: 'idle',
        },
      ]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'error-banner',
    description: 'Toast banner rendered for an `error` message.',
    setup: async (page) => {
      await deliverAll(page, [
        CONFIG_DEFAULT,
        { type: 'connection-state', state: { state: 'error', message: 'Bridge unreachable' } },
        { type: 'error', message: 'Bridge unreachable — retrying in 3s' },
      ]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'sidebar-collapsed',
    description: 'Collapse the sidebar. UI not yet implemented — expected to skip.',
    setup: async (page) => {
      await deliverAll(page, [CONFIG_DEFAULT, CONNECTED]);
      const clicked = await clickFirst(page, [
        '[data-testid="sidebar-collapse"]',
        'button[aria-label="Collapse sidebar"]',
        '.sidebar-collapse',
      ]);
      if (!clicked) {
        throw new Error('SKIP: no sidebar-collapse control found (UI not yet implemented)');
      }
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'disconnected-with-reason',
    description: 'Disconnected state with a reason — reconnect button visible.',
    setup: async (page) => {
      await deliverAll(page, [
        CONFIG_DEFAULT,
        { type: 'connection-state', state: { state: 'disconnected', reason: 'timeout' } },
      ]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'drawer-open-narrow',
    description: 'Narrow viewport — click the sidebar toggle to open the off-canvas drawer over the chat.',
    setup: async (page) => {
      await page.setViewportSize({ width: 480, height: 800 });
      await deliverAll(page, [
        CONFIG_DEFAULT,
        CONNECTED,
        {
          type: 'session-list',
          sessions: [
            {
              sessionId: 's-active-001',
              projectPath: '/Users/dev/myproj',
              firstPrompt: 'Refactor the bridge client to share session state',
              lastModified: '2026-05-21T11:30:00Z',
            },
          ],
          recent: [
            {
              sessionId: 's-recent-001',
              projectPath: '/Users/dev/another',
              firstPrompt: 'Fix the iOS build script on Apple Silicon',
              lastModified: '2026-05-20T18:00:00Z',
            },
            {
              sessionId: 's-recent-002',
              projectPath: '/Users/dev/myproj',
              firstPrompt: 'Investigate why the websocket reconnects in a tight loop',
              lastModified: '2026-05-20T09:42:00Z',
            },
          ],
          projects: ['/Users/dev/myproj', '/Users/dev/another'],
        },
        {
          type: 'session-active',
          sessionId: 's-active-001',
          projectPath: '/Users/dev/myproj',
          status: 'idle',
        },
      ]);
      // Click the topbar toggle to open the drawer over the chat.
      const clicked = await clickFirst(page, [
        '#topbar-sidebar-toggle',
        '#sidebar-toggle',
      ]);
      if (!clicked) {
        throw new Error('SKIP: no sidebar toggle button found on narrow width');
      }
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'chat-with-streaming-wide',
    description: 'Wide viewport — same chat-with-streaming events. Confirms the layout / Stop button are correct without the narrow drawer logic.',
    setup: async (page) => {
      await page.setViewportSize({ width: 1280, height: 800 });
      await deliverAll(page, [
        CONFIG_DEFAULT,
        CONNECTED,
        {
          type: 'session-active',
          sessionId: 'sess-1234abcd',
          projectPath: '/Users/dev/myproj',
          status: 'running',
        },
        {
          type: 'chat-append',
          message: {
            id: 'u1',
            role: 'user',
            text: 'How does `apps/vscode/src/messages.ts:1` define ExtensionToWebview?',
          },
        },
        {
          type: 'chat-append',
          message: { id: 'a1', role: 'assistant', text: '' },
        },
        { type: 'stream-delta', messageId: 'a1', delta: 'It defines ' },
        { type: 'stream-delta', messageId: 'a1', delta: 'a discriminated union with ' },
        { type: 'stream-delta', messageId: 'a1', delta: '`type` as the tag.\n\n' },
        {
          type: 'stream-delta',
          messageId: 'a1',
          delta: '```ts\nexport type ExtensionToWebview = { type: "config"; ... };\n```\n',
        },
        {
          type: 'result',
          sessionId: 'sess-1234abcd',
          cost: 0.0123,
          duration: 2400,
        },
      ]);
    },
  },

  // ---------------------------------------------------------------------
  {
    name: 'long-history',
    description: 'Many messages — used to eyeball list scrolling and density.',
    setup: async (page) => {
      const msgs = [CONFIG_DEFAULT, CONNECTED];
      for (let i = 0; i < 12; i++) {
        msgs.push({
          type: 'chat-append',
          message: {
            id: `u-${i}`,
            role: 'user',
            text: `Question ${i + 1}: what does the file apps/vscode/src/extension.ts do?`,
          },
        });
        msgs.push({
          type: 'chat-append',
          message: {
            id: `a-${i}`,
            role: 'assistant',
            text:
              `Answer ${i + 1}. The file declares the extension activation hook and ` +
              `wires up the webview panel.\n\nIt also opens the websocket via ` +
              '`bridgeClient.ts:1` and forwards messages to the webview.',
          },
        });
      }
      await deliverAll(page, msgs);
    },
  },
];
