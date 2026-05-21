// @ts-check
/*
 * Shared state + VSCode bridge helpers for the CC Pocket webview.
 *
 * Vanilla ES module — no bundler, no npm deps. Each consumer imports the
 * pieces it needs directly. Persisted UI bits (mode, sidebar collapsed,
 * draft text, chip ordering) flow through `getState` / `setState` here so
 * we never write inconsistent shapes to vscode.getState().
 */

/** @typedef {import('../src/messages.js').WebviewToExtension} WebviewToExtension */
/** @typedef {import('../src/messages.js').ExtensionToWebview} ExtensionToWebview */
/** @typedef {import('../src/messages.js').ChatMessage} ChatMessage */
/** @typedef {import('../src/messages.js').PendingApproval} PendingApproval */
/** @typedef {import('../src/messages.js').ConnectionState} ConnectionState */
/** @typedef {import('../src/messages.js').BridgeSession} BridgeSession */
/** @typedef {import('../src/messages.js').SessionStatus} SessionStatus */
/** @typedef {import('../src/messages.js').PermissionMode} PermissionMode */
/** @typedef {import('../src/messages.js').AttachmentRef} AttachmentRef */

/**
 * Acquire the host-injected VSCode webview API. Falls back to a console
 * stub when the file is opened directly in a browser for development.
 *
 * @returns {{ postMessage: (msg: WebviewToExtension) => void, getState: () => unknown, setState: (s: unknown) => void }}
 */
function getVsCodeApi() {
  // @ts-ignore — acquireVsCodeApi is injected by the host runtime.
  if (typeof acquireVsCodeApi === 'function') {
    // @ts-ignore
    return acquireVsCodeApi();
  }
  /** @type {{ [k: string]: unknown }} */
  let stash = {};
  return {
    postMessage(msg) {
      // eslint-disable-next-line no-console
      console.log('[ccpocket dev] postMessage', msg);
    },
    getState() {
      return stash;
    },
    setState(s) {
      stash = /** @type {{ [k: string]: unknown }} */ (s ?? {});
    },
  };
}

export const vscode = getVsCodeApi();

/** @param {WebviewToExtension} msg */
export function send(msg) {
  vscode.postMessage(msg);
}

/**
 * Persisted UI bits.
 *
 * @typedef {Object} Persisted
 * @property {boolean} sidebarCollapsed
 * @property {PermissionMode} permissionMode
 * @property {string} draft
 * @property {AttachmentRef[]} attachments
 */

/** @type {Persisted} */
const defaultPersisted = {
  sidebarCollapsed: false,
  permissionMode: 'acceptEdits',
  draft: '',
  attachments: [],
};

/** @returns {Persisted} */
export function loadPersisted() {
  const raw = vscode.getState();
  if (!raw || typeof raw !== 'object') return { ...defaultPersisted };
  const r = /** @type {{ [k: string]: unknown }} */ (raw);
  /** @type {PermissionMode[]} */
  const modes = ['default', 'plan', 'acceptEdits', 'bypassPermissions'];
  const mode = modes.includes(/** @type {PermissionMode} */ (r.permissionMode))
    ? /** @type {PermissionMode} */ (r.permissionMode)
    : defaultPersisted.permissionMode;
  return {
    sidebarCollapsed: r.sidebarCollapsed === true,
    permissionMode: mode,
    draft: typeof r.draft === 'string' ? r.draft : '',
    attachments: Array.isArray(r.attachments)
      ? /** @type {AttachmentRef[]} */ (
          r.attachments.filter(
            (a) => a && typeof a === 'object' && typeof (/** @type {{ path?: unknown }} */ (a)).path === 'string',
          )
        )
      : [],
  };
}

/** @param {Persisted} p */
export function savePersisted(p) {
  vscode.setState(p);
}

/** Live module-scope state for the running webview. */
export const state = {
  /** @type {string | null} */ activeSessionId: null,
  /** @type {string | null} */ activeProjectPath: null,
  /** @type {string | null} */ defaultProjectPath: null,
  /** @type {string} */ bridgeUrl: '',
  /** @type {boolean} */ hasToken: false,
  /** @type {string[]} */ projects: [],
  /** @type {BridgeSession[]} */ sessions: [],
  /** @type {BridgeSession[]} */ recent: [],
  /** @type {Map<string, HTMLDivElement>} */ messageEls: new Map(),
  /** @type {Map<string, string>} */ messageText: new Map(),
  /** @type {SessionStatus | null} */ status: null,
  /** @type {ConnectionState | null} */ connection: null,
  /** @type {Set<string>} */ activeBannerMessages: new Set(),
  /** @type {Persisted} */ persisted: loadPersisted(),
};

/** Save the current persisted snapshot. */
export function persist() {
  savePersisted(state.persisted);
}

/** Strict element lookup. */
export function $(/** @type {string} */ id) {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} not found`);
  return el;
}

/**
 * Shorten an absolute path to `…/parent/leaf` for compact display.
 * @param {string} p
 */
export function shortenPath(p) {
  if (!p) return '';
  const parts = p.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 2) return p;
  return '…/' + parts.slice(-2).join('/');
}

/** @param {string} p */
export function basename(p) {
  if (!p) return '';
  const parts = p.split(/[\\/]+/).filter(Boolean);
  return parts[parts.length - 1] || p;
}

/** @param {string} s @param {number} n */
export function truncate(s, n) {
  return s.length <= n ? s : s.slice(0, n - 1) + '…';
}

/**
 * Relative-time like "5m ago" / "2h ago" / "3d ago".
 * @param {string | number | Date | undefined} when
 */
export function relativeTime(when) {
  if (!when) return '';
  const t = typeof when === 'string' || typeof when === 'number'
    ? new Date(when).getTime()
    : when.getTime();
  if (Number.isNaN(t)) return '';
  const diff = Math.max(0, Date.now() - t);
  const m = Math.floor(diff / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d ago`;
  return new Date(t).toLocaleDateString();
}

/** Best-effort one-liner summary of a tool input object. */
export function summarizeToolInput(/** @type {unknown} */ input) {
  if (input === null || input === undefined) return '';
  if (typeof input === 'string') return input;
  try {
    const s = JSON.stringify(input);
    return s.length > 240 ? s.slice(0, 237) + '…' : s;
  } catch {
    return String(input);
  }
}

/** JSON.stringify with pretty indent and a safety guard. */
export function safePrettyJson(/** @type {unknown} */ value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

// ---------- Toast ----------------------------------------------------------

let toastTimer = /** @type {number | null} */ (null);

/** @param {string} message */
export function showToast(message) {
  const toast = /** @type {HTMLDivElement} */ ($('toast'));
  toast.textContent = message;
  toast.hidden = false;
  if (toastTimer !== null) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    toast.hidden = true;
    toastTimer = null;
  }, 4000);
}
