// @ts-check
/*
 * CC Pocket — native VSCode webview chat UI.
 *
 * Single-file vanilla ES module. No bundler, no npm deps. Everything renders
 * via DOM construction; we never touch innerHTML with model-controlled text
 * (the markdown subset below builds nodes one at a time).
 */

/** @typedef {import('../src/messages.js').ChatMessage} ChatMessage */
/** @typedef {import('../src/messages.js').PendingApproval} PendingApproval */
/** @typedef {import('../src/messages.js').ConnectionState} ConnectionState */
/** @typedef {import('../src/messages.js').BridgeSession} BridgeSession */
/** @typedef {import('../src/messages.js').ExtensionToWebview} ExtensionToWebview */
/** @typedef {import('../src/messages.js').WebviewToExtension} WebviewToExtension */
/** @typedef {import('../src/messages.js').SessionStatus} SessionStatus */

// ---------- VSCode bridge ---------------------------------------------------

/**
 * Returns the postMessage-only API exposed by the host. Defined globally by
 * the VSCode webview runtime; we keep the JSDoc type narrow because we only
 * call postMessage.
 *
 * @returns {{ postMessage: (msg: WebviewToExtension) => void }}
 */
function getVsCodeApi() {
  // @ts-ignore — acquireVsCodeApi is injected by the host runtime.
  if (typeof acquireVsCodeApi === 'function') {
    // @ts-ignore
    return acquireVsCodeApi();
  }
  // Fallback for opening the file directly in a browser (development eyeball).
  return {
    postMessage(msg) {
      // eslint-disable-next-line no-console
      console.log('[ccpocket dev] postMessage', msg);
    },
  };
}

const vscode = getVsCodeApi();

/** @param {WebviewToExtension} msg */
function send(msg) {
  vscode.postMessage(msg);
}

// ---------- DOM refs --------------------------------------------------------

/** Strict element lookup — throws if a required element is missing. */
function $(id) {
  const el = document.getElementById(id);
  if (!el) throw new Error(`#${id} not found`);
  return el;
}

const els = {
  toast: /** @type {HTMLDivElement} */ ($('toast')),
  statusDot: /** @type {HTMLSpanElement} */ ($('status-dot')),
  statusLabel: /** @type {HTMLSpanElement} */ ($('status-label')),
  reconnectBtn: /** @type {HTMLButtonElement} */ ($('reconnect-btn')),
  projectSelect: /** @type {HTMLSelectElement} */ ($('project-select')),
  sessionSelect: /** @type {HTMLSelectElement} */ ($('session-select')),
  sessionPickerRow: /** @type {HTMLDivElement} */ ($('session-picker-row')),
  stopBtn: /** @type {HTMLButtonElement} */ ($('stop-btn')),
  metaRow: /** @type {HTMLDivElement} */ ($('meta-row')),
  metaProject: /** @type {HTMLSpanElement} */ ($('meta-project')),
  metaSession: /** @type {HTMLSpanElement} */ ($('meta-session')),
  messages: /** @type {HTMLDivElement} */ ($('messages')),
  input: /** @type {HTMLTextAreaElement} */ ($('input')),
  sendBtn: /** @type {HTMLButtonElement} */ ($('send-btn')),
  hint: /** @type {HTMLSpanElement} */ ($('hint')),
};

// ---------- State -----------------------------------------------------------

const state = {
  /** @type {string | null} */ activeSessionId: null,
  /** @type {string | null} */ activeProjectPath: null,
  /** @type {string | null} */ defaultProjectPath: null,
  /** @type {string[]} */ projects: [],
  /** @type {BridgeSession[]} */ sessions: [],
  /** @type {BridgeSession[]} */ recent: [],
  /** @type {Map<string, HTMLDivElement>} */ messageEls: new Map(),
  /** @type {Map<string, string>} */ messageText: new Map(),
  /** @type {SessionStatus | null} */ status: null,
  /** @type {ConnectionState | null} */ connection: null,
  /** @type {number | null} */ toastTimer: null,
};

// ---------- Markdown subset -------------------------------------------------
//
// Supported syntax:
//   - paragraphs (split by blank lines)
//   - fenced code blocks (``` … ```)
//   - inline code (`x`)
//   - markdown links: [label](target) — target is also passed through filename
//     detection so `path.ts:42` style line refs work.
//   - bare file path tokens matching FILE_RE — rendered as click-to-open links.
//
// Everything else is plain text. We never write to innerHTML with model
// content; only structural tags are constructed via createElement, and all
// untrusted text passes through createTextNode.

const FILE_RE = /[\w./\-]+\.(?:ts|tsx|js|jsx|dart|py|swift|md)(?::\d+)?/g;
// Greedy inline-code splitter — also catches `[label](target)` links.
const INLINE_RE = /(`[^`\n]+`|\[[^\]]+\]\([^)\s]+\))/g;
const LINK_RE = /^\[([^\]]+)\]\(([^)\s]+)\)$/;
const CODE_FENCE_RE = /^```/;

/**
 * Parse a markdown link target into {path, line} if it looks like a file ref.
 * Returns null otherwise (caller treats as a plain anchor).
 *
 * @param {string} target
 * @returns {{ path: string, line?: number } | null}
 */
function parseFileTarget(target) {
  if (/^https?:\/\//i.test(target)) return null;
  const m = target.match(/^([\w./\-]+\.(?:ts|tsx|js|jsx|dart|py|swift|md))(?::(\d+))?$/);
  if (!m) return null;
  return { path: m[1], line: m[2] ? Number(m[2]) : undefined };
}

/**
 * Build a click-to-open <a> for a file path. The link sends `open-file` to the
 * host on click and prevents default navigation (CSP would block it anyway).
 *
 * @param {string} label
 * @param {string} path
 * @param {number | undefined} line
 */
function makeFileLink(label, path, line) {
  const a = document.createElement('a');
  a.textContent = label;
  a.href = '#';
  a.dataset.path = path;
  if (line !== undefined) a.dataset.line = String(line);
  a.addEventListener('click', (ev) => {
    ev.preventDefault();
    /** @type {WebviewToExtension} */
    const msg = line !== undefined
      ? { type: 'open-file', path, line }
      : { type: 'open-file', path };
    send(msg);
  });
  return a;
}

/**
 * Append a plain text segment to `parent`, replacing any bare path-like tokens
 * with click-to-open links. Used for non-code inline text.
 *
 * @param {Node} parent
 * @param {string} text
 */
function appendTextWithFileLinks(parent, text) {
  if (!text) return;
  FILE_RE.lastIndex = 0;
  let last = 0;
  let m;
  while ((m = FILE_RE.exec(text)) !== null) {
    if (m.index > last) {
      parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    }
    const token = m[0];
    const colonIdx = token.lastIndexOf(':');
    let path = token;
    let line;
    if (colonIdx > 0 && /^\d+$/.test(token.slice(colonIdx + 1))) {
      path = token.slice(0, colonIdx);
      line = Number(token.slice(colonIdx + 1));
    }
    parent.appendChild(makeFileLink(token, path, line));
    last = m.index + token.length;
  }
  if (last < text.length) {
    parent.appendChild(document.createTextNode(text.slice(last)));
  }
}

/**
 * Render inline content of a paragraph: handles `code` and [link](target),
 * and runs path-link detection over the remaining text.
 *
 * @param {HTMLElement} parent
 * @param {string} text
 */
function renderInline(parent, text) {
  const parts = text.split(INLINE_RE);
  for (const part of parts) {
    if (!part) continue;
    if (part.startsWith('`') && part.endsWith('`') && part.length >= 2) {
      const code = document.createElement('code');
      code.textContent = part.slice(1, -1);
      parent.appendChild(code);
      continue;
    }
    const linkMatch = part.match(LINK_RE);
    if (linkMatch) {
      const label = linkMatch[1];
      const target = linkMatch[2];
      const file = parseFileTarget(target);
      if (file) {
        parent.appendChild(makeFileLink(label, file.path, file.line));
      } else {
        // Non-file links: render as text (CSP blocks navigation anyway).
        // We still surface the label so users see the intent.
        parent.appendChild(document.createTextNode(label));
      }
      continue;
    }
    appendTextWithFileLinks(parent, part);
  }
}

/**
 * Render a markdown subset into the given container, replacing its contents.
 *
 * @param {HTMLElement} container
 * @param {string} text
 */
function renderMarkdown(container, text) {
  // Clear without using innerHTML.
  while (container.firstChild) container.removeChild(container.firstChild);

  const lines = text.split('\n');
  let i = 0;
  /** @type {string[]} */
  let paragraph = [];

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    const p = document.createElement('p');
    renderInline(p, paragraph.join(' '));
    container.appendChild(p);
    paragraph = [];
  };

  while (i < lines.length) {
    const line = lines[i];
    if (CODE_FENCE_RE.test(line)) {
      flushParagraph();
      const buf = [];
      i++;
      while (i < lines.length && !CODE_FENCE_RE.test(lines[i])) {
        buf.push(lines[i]);
        i++;
      }
      // Skip the closing fence if present.
      if (i < lines.length) i++;
      const pre = document.createElement('pre');
      const code = document.createElement('code');
      code.textContent = buf.join('\n');
      pre.appendChild(code);
      container.appendChild(pre);
      continue;
    }
    if (line.trim() === '') {
      flushParagraph();
    } else {
      paragraph.push(line);
    }
    i++;
  }
  flushParagraph();
}

// ---------- Message rendering ----------------------------------------------

/**
 * Create the DOM scaffold for a ChatMessage and return its container element.
 * The element is registered in state.messageEls so streaming + replacement can
 * locate it later by id.
 *
 * @param {ChatMessage} msg
 */
function buildMessageEl(msg) {
  const wrap = document.createElement('div');
  wrap.className = `message message-${msg.role}`;
  wrap.dataset.id = msg.id;
  if (msg.role === 'tool' && msg.toolStatus) {
    wrap.dataset.toolStatus = msg.toolStatus;
  }

  const role = document.createElement('div');
  role.className = 'message-role';
  if (msg.role === 'tool') {
    role.appendChild(document.createTextNode('tool'));
    if (msg.toolName) {
      const name = document.createElement('span');
      name.className = 'tool-name';
      name.textContent = ' · ' + msg.toolName;
      role.appendChild(name);
    }
    if (msg.toolStatus && msg.toolStatus !== 'pending') {
      const status = document.createElement('span');
      status.className = `tool-status status-${msg.toolStatus}`;
      status.textContent = msg.toolStatus;
      role.appendChild(status);
    }
  } else {
    role.textContent = msg.role;
  }
  wrap.appendChild(role);

  const body = document.createElement('div');
  body.className = 'message-body';
  renderMarkdown(body, msg.text);
  wrap.appendChild(body);

  return wrap;
}

/**
 * Append a chat message to the list, replacing any existing element with the
 * same id (so a `chat-append` for an already-rendered id behaves like an
 * update).
 *
 * @param {ChatMessage} msg
 */
function appendMessage(msg) {
  const existing = state.messageEls.get(msg.id);
  const nearBottom = isNearBottom();
  const el = buildMessageEl(msg);
  if (existing && existing.parentNode === els.messages) {
    els.messages.replaceChild(el, existing);
  } else {
    els.messages.appendChild(el);
  }
  state.messageEls.set(msg.id, el);
  state.messageText.set(msg.id, msg.text);
  if (nearBottom) scrollToBottom();
}

/** Replace the entire message list (used on session switch). */
function replaceMessages(messages) {
  while (els.messages.firstChild) els.messages.removeChild(els.messages.firstChild);
  state.messageEls.clear();
  state.messageText.clear();
  for (const m of messages) {
    const el = buildMessageEl(m);
    els.messages.appendChild(el);
    state.messageEls.set(m.id, el);
    state.messageText.set(m.id, m.text);
  }
  scrollToBottom();
}

/**
 * Apply a streaming delta to the body of an existing message. We mutate the
 * cached text and re-render the body in place — markdown deltas don't lend
 * themselves to per-chunk DOM patches.
 *
 * @param {string} messageId
 * @param {string} delta
 */
function applyStreamDelta(messageId, delta) {
  const el = state.messageEls.get(messageId);
  if (!el) return;
  const body = el.querySelector('.message-body');
  if (!body) return;
  const next = (state.messageText.get(messageId) || '') + delta;
  state.messageText.set(messageId, next);
  const nearBottom = isNearBottom();
  renderMarkdown(/** @type {HTMLElement} */ (body), next);
  if (nearBottom) scrollToBottom();
}

// ---------- Approval cards -------------------------------------------------

/**
 * Attach (or refresh) the Approve / Reject row on the matching tool message.
 * If no tool message has been appended yet, we render a placeholder so the
 * user can still respond.
 *
 * @param {PendingApproval} approval
 */
function showApproval(approval) {
  let el = state.messageEls.get(approval.id);
  if (!el) {
    /** @type {ChatMessage} */
    const placeholder = {
      id: approval.id,
      role: 'tool',
      text: summarizeToolInput(approval.input),
      toolName: approval.tool,
      toolStatus: 'pending',
    };
    appendMessage(placeholder);
    el = /** @type {HTMLDivElement} */ (state.messageEls.get(approval.id));
  }
  // Remove any pre-existing approval row to avoid duplicates.
  const old = el.querySelector('.approval-row');
  if (old) old.remove();

  const row = document.createElement('div');
  row.className = 'approval-row';
  const approveBtn = document.createElement('button');
  approveBtn.type = 'button';
  approveBtn.className = 'primary-btn';
  approveBtn.textContent = 'Approve';
  approveBtn.addEventListener('click', () => {
    send({ type: 'approve', id: approval.id });
    approveBtn.disabled = true;
    rejectBtn.disabled = true;
  });
  const rejectBtn = document.createElement('button');
  rejectBtn.type = 'button';
  rejectBtn.className = 'danger-btn';
  rejectBtn.textContent = 'Reject';
  rejectBtn.addEventListener('click', () => {
    send({ type: 'reject', id: approval.id });
    approveBtn.disabled = true;
    rejectBtn.disabled = true;
  });
  row.appendChild(approveBtn);
  row.appendChild(rejectBtn);
  el.appendChild(row);
  if (isNearBottom()) scrollToBottom();
}

/**
 * Resolve an approval — remove the buttons and mark the tool card status.
 *
 * @param {string} id
 */
function resolveApproval(id) {
  const el = state.messageEls.get(id);
  if (!el) return;
  const row = el.querySelector('.approval-row');
  if (row) row.remove();
  const role = el.querySelector('.message-role');
  if (role && !role.querySelector('.tool-status')) {
    const status = document.createElement('span');
    status.className = 'tool-status status-completed';
    status.textContent = 'resolved';
    role.appendChild(status);
  }
}

/**
 * Best-effort one-liner summary of a tool input object. We only need this to
 * give the user *some* context when the bridge surfaces an approval before
 * the matching tool message has been appended.
 *
 * @param {unknown} input
 */
function summarizeToolInput(input) {
  if (input === null || input === undefined) return '';
  if (typeof input === 'string') return input;
  try {
    const s = JSON.stringify(input);
    return s.length > 240 ? s.slice(0, 237) + '…' : s;
  } catch {
    return String(input);
  }
}

// ---------- Connection / status --------------------------------------------

/** @param {ConnectionState} cs */
function setConnection(cs) {
  state.connection = cs;
  const dot = els.statusDot;
  dot.classList.remove(
    'status-idle',
    'status-connecting',
    'status-connected',
    'status-disconnected',
    'status-error',
  );
  let label = 'Idle';
  let cls = 'status-idle';
  let canReconnect = false;
  switch (cs.state) {
    case 'idle':
      label = 'Idle';
      cls = 'status-idle';
      break;
    case 'connecting':
      label = 'Connecting…';
      cls = 'status-connecting';
      break;
    case 'connected':
      label = 'Connected';
      cls = 'status-connected';
      break;
    case 'disconnected':
      label = cs.reason ? `Disconnected — ${cs.reason}` : 'Disconnected';
      cls = 'status-disconnected';
      canReconnect = true;
      break;
    case 'error':
      label = `Error — ${cs.message}`;
      cls = 'status-error';
      canReconnect = true;
      break;
  }
  dot.classList.add(cls);
  els.statusLabel.textContent = label;
  els.reconnectBtn.hidden = !canReconnect;
}

// ---------- Session header / pickers ---------------------------------------

function renderProjectOptions() {
  const select = els.projectSelect;
  // Clear without innerHTML.
  while (select.firstChild) select.removeChild(select.firstChild);

  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.textContent = state.projects.length === 0
    ? 'No projects available'
    : 'Pick a project to start…';
  placeholder.disabled = state.projects.length === 0;
  select.appendChild(placeholder);

  for (const p of state.projects) {
    const opt = document.createElement('option');
    opt.value = p;
    opt.textContent = shortenPath(p);
    opt.title = p;
    select.appendChild(opt);
  }

  // Preserve the active project if it's still in the list.
  if (state.activeProjectPath && state.projects.includes(state.activeProjectPath)) {
    select.value = state.activeProjectPath;
  } else if (state.defaultProjectPath && state.projects.includes(state.defaultProjectPath)) {
    select.value = state.defaultProjectPath;
  } else {
    select.value = '';
  }
}

function renderSessionOptions() {
  const select = els.sessionSelect;
  while (select.firstChild) select.removeChild(select.firstChild);

  const all = [...state.sessions];
  // Merge recent that aren't already in the active list.
  for (const r of state.recent) {
    if (!all.find((s) => s.sessionId === r.sessionId)) all.push(r);
  }

  if (all.length === 0) {
    els.sessionPickerRow.hidden = true;
    return;
  }

  els.sessionPickerRow.hidden = false;
  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.textContent = 'Switch session…';
  select.appendChild(placeholder);

  for (const s of all) {
    const opt = document.createElement('option');
    opt.value = s.sessionId;
    const label = s.firstPrompt || s.sessionId;
    opt.textContent = truncate(label, 64);
    opt.title = s.projectPath ? `${s.projectPath} · ${s.sessionId}` : s.sessionId;
    select.appendChild(opt);
  }

  if (state.activeSessionId) {
    select.value = state.activeSessionId;
  } else {
    select.value = '';
  }
}

function renderMetaRow() {
  if (!state.activeSessionId && !state.activeProjectPath) {
    els.metaRow.hidden = true;
    els.stopBtn.hidden = true;
    return;
  }
  els.metaRow.hidden = false;
  els.metaProject.textContent = state.activeProjectPath
    ? shortenPath(state.activeProjectPath)
    : '(no project)';
  els.metaProject.title = state.activeProjectPath || '';
  els.metaSession.textContent = state.activeSessionId
    ? `#${state.activeSessionId.slice(0, 8)}`
    : '';
  els.stopBtn.hidden = !state.activeSessionId;
}

// ---------- Utilities ------------------------------------------------------

function isNearBottom() {
  const el = els.messages;
  const threshold = 64;
  return el.scrollHeight - el.scrollTop - el.clientHeight < threshold;
}

function scrollToBottom() {
  els.messages.scrollTop = els.messages.scrollHeight;
}

/** @param {string} s @param {number} n */
function truncate(s, n) {
  return s.length <= n ? s : s.slice(0, n - 1) + '…';
}

/** Shorten an absolute path to `…/parent/leaf` for compact display. */
function shortenPath(p) {
  const parts = p.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 2) return p;
  return '…/' + parts.slice(-2).join('/');
}

/** @param {string} message */
function showToast(message) {
  els.toast.textContent = message;
  els.toast.hidden = false;
  if (state.toastTimer !== null) window.clearTimeout(state.toastTimer);
  state.toastTimer = window.setTimeout(() => {
    els.toast.hidden = true;
    state.toastTimer = null;
  }, 6000);
}

// ---------- Composer -------------------------------------------------------

function autoResizeInput() {
  const ta = els.input;
  ta.style.height = 'auto';
  ta.style.height = Math.min(ta.scrollHeight, 180) + 'px';
}

function submitInput() {
  const text = els.input.value.trim();
  if (!text) return;
  send({ type: 'user-input', text });
  els.input.value = '';
  autoResizeInput();
}

els.input.addEventListener('input', autoResizeInput);
els.input.addEventListener('keydown', (ev) => {
  // Cmd/Ctrl + Enter sends. Plain Enter inserts a newline.
  if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) {
    ev.preventDefault();
    submitInput();
  }
});
els.sendBtn.addEventListener('click', submitInput);

els.reconnectBtn.addEventListener('click', () => {
  send({ type: 'reconnect' });
});

els.stopBtn.addEventListener('click', () => {
  send({ type: 'stop-session' });
});

els.projectSelect.addEventListener('change', () => {
  const value = els.projectSelect.value;
  if (!value) return;
  send({ type: 'start-session', projectPath: value });
});

els.sessionSelect.addEventListener('change', () => {
  const value = els.sessionSelect.value;
  if (!value) return;
  send({ type: 'switch-session', sessionId: value });
});

// ---------- Inbound dispatch -----------------------------------------------

/** @param {MessageEvent<ExtensionToWebview>} event */
function handleMessage(event) {
  const msg = event.data;
  if (!msg || typeof msg !== 'object' || typeof msg.type !== 'string') return;
  switch (msg.type) {
    case 'config': {
      state.defaultProjectPath = msg.defaultProjectPath;
      state.projects = msg.allowedDirs || [];
      if (msg.defaultProjectPath && !state.activeProjectPath) {
        state.activeProjectPath = msg.defaultProjectPath;
      }
      els.hint.textContent = msg.bridgeUrl
        ? `Bridge: ${msg.bridgeUrl}${msg.hasToken ? ' · token' : ''}`
        : '';
      renderProjectOptions();
      break;
    }
    case 'connection-state':
      setConnection(msg.state);
      break;
    case 'session-list':
      state.sessions = msg.sessions || [];
      state.recent = msg.recent || [];
      state.projects = msg.projects && msg.projects.length > 0 ? msg.projects : state.projects;
      renderProjectOptions();
      renderSessionOptions();
      break;
    case 'session-active':
      state.activeSessionId = msg.sessionId;
      state.activeProjectPath = msg.projectPath;
      state.status = msg.status;
      renderProjectOptions();
      renderSessionOptions();
      renderMetaRow();
      break;
    case 'chat-append':
      appendMessage(msg.message);
      break;
    case 'chat-replace':
      replaceMessages(msg.messages || []);
      break;
    case 'stream-delta':
      applyStreamDelta(msg.messageId, msg.delta);
      break;
    case 'approval-request':
      showApproval(msg.approval);
      break;
    case 'approval-resolved':
      resolveApproval(msg.id);
      break;
    case 'result':
      appendResultFooter(msg);
      break;
    case 'error':
      showToast(msg.message);
      break;
    default:
      // Unknown — ignore. Older webview shouldn't break on new host messages.
      break;
  }
}

/**
 * Append a small "Done (cost: $X, duration: Ys)" footer to the most-recent
 * assistant message in the list (if any).
 *
 * @param {{ cost?: number, duration?: number }} info
 */
function appendResultFooter(info) {
  let lastAssistant = null;
  for (const el of els.messages.querySelectorAll('.message-assistant')) {
    lastAssistant = el;
  }
  if (!lastAssistant) return;
  // Remove any previous footer so re-emit doesn't stack them up.
  const prior = lastAssistant.querySelector('.result-footer');
  if (prior) prior.remove();
  const parts = ['Done'];
  if (typeof info.cost === 'number') parts.push(`cost: $${info.cost.toFixed(4)}`);
  if (typeof info.duration === 'number') parts.push(`duration: ${(info.duration / 1000).toFixed(1)}s`);
  const footer = document.createElement('div');
  footer.className = 'result-footer';
  footer.textContent = parts.join(' · ');
  lastAssistant.appendChild(footer);
}

window.addEventListener('message', handleMessage);

// ---------- Boot ----------------------------------------------------------

function boot() {
  setConnection({ state: 'idle' });
  renderProjectOptions();
  autoResizeInput();
  send({ type: 'ready' });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot, { once: true });
} else {
  boot();
}
