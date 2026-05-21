// @ts-check
/*
 * Chat rendering: messages, streaming, tool-call cards, approval cards,
 * connection topbar, error banners, result footer.
 */

/** @typedef {import('../src/messages.js').ChatMessage} ChatMessage */
/** @typedef {import('../src/messages.js').PendingApproval} PendingApproval */
/** @typedef {import('../src/messages.js').ConnectionState} ConnectionState */

import { $, state, send, summarizeToolInput, safePrettyJson } from './state.js';
import { renderMarkdown } from './markdown.js';

const els = {
  messages: /** @type {HTMLDivElement} */ ($('messages')),
  banners: /** @type {HTMLDivElement} */ ($('banners')),
  statusDot: /** @type {HTMLSpanElement} */ ($('status-dot')),
  statusLabel: /** @type {HTMLSpanElement} */ ($('status-label')),
  bridgeUrl: /** @type {HTMLSpanElement} */ ($('bridge-url')),
  reconnectBtn: /** @type {HTMLButtonElement} */ ($('reconnect-btn')),
  stopBtn: /** @type {HTMLButtonElement} */ ($('stop-btn')),
  activeMini: /** @type {HTMLSpanElement} */ ($('active-mini')),
};

// ---------- Scroll helpers --------------------------------------------------

function isNearBottom() {
  const el = els.messages;
  const threshold = 80;
  return el.scrollHeight - el.scrollTop - el.clientHeight < threshold;
}

function scrollToBottom() {
  els.messages.scrollTop = els.messages.scrollHeight;
}

// ---------- Message rendering ----------------------------------------------

/**
 * Build the DOM scaffold for a ChatMessage. For tool messages we render a
 * collapsible card with header/status pill and a structured body for input
 * and (optional) output.
 *
 * @param {ChatMessage} msg
 */
function buildMessageEl(msg) {
  const wrap = document.createElement('div');
  wrap.className = `message message-${msg.role}`;
  wrap.dataset.id = msg.id;

  if (msg.role === 'tool') {
    wrap.classList.add('tool-card');
    if (msg.toolStatus) {
      wrap.dataset.toolStatus = msg.toolStatus;
    }

    // Header: chevron + name + status pill.
    const head = document.createElement('button');
    head.type = 'button';
    head.className = 'tool-head';
    head.setAttribute('aria-expanded', 'true');

    const chevron = document.createElement('span');
    chevron.className = 'tool-chevron';
    chevron.textContent = '▾';
    head.appendChild(chevron);

    const name = document.createElement('span');
    name.className = 'tool-name';
    name.textContent = msg.toolName || 'tool';
    head.appendChild(name);

    const status = document.createElement('span');
    status.className = `tool-status status-${msg.toolStatus || 'pending'}`;
    status.textContent = msg.toolStatus || 'pending';
    head.appendChild(status);

    wrap.appendChild(head);

    const body = document.createElement('div');
    body.className = 'tool-body';

    // We expect msg.text to optionally be a JSON-stringified input. We
    // attempt to pretty-print; if it's not JSON, fall back to the raw text.
    const inputWrap = document.createElement('div');
    inputWrap.className = 'tool-input';
    const inputLabel = document.createElement('div');
    inputLabel.className = 'tool-section-label';
    inputLabel.textContent = 'Input';
    const inputPre = document.createElement('pre');
    inputPre.className = 'tool-pre';
    const inputCode = document.createElement('code');
    inputCode.textContent = tryPrettyJson(msg.text);
    inputPre.appendChild(inputCode);
    inputWrap.appendChild(inputLabel);
    inputWrap.appendChild(inputPre);
    body.appendChild(inputWrap);

    wrap.appendChild(body);

    // Collapsible behavior.
    head.addEventListener('click', () => {
      const expanded = head.getAttribute('aria-expanded') === 'true';
      head.setAttribute('aria-expanded', expanded ? 'false' : 'true');
      body.hidden = expanded;
      chevron.textContent = expanded ? '▸' : '▾';
    });

    return wrap;
  }

  // user / assistant: avatar + bubble.
  const role = document.createElement('div');
  role.className = 'message-role';
  role.textContent = msg.role === 'assistant' ? 'Claude' : 'You';
  wrap.appendChild(role);

  const body = document.createElement('div');
  body.className = 'message-body';
  renderMarkdown(body, msg.text);
  wrap.appendChild(body);

  return wrap;
}

/** @param {string} text */
function tryPrettyJson(text) {
  if (!text) return '';
  const trimmed = text.trim();
  if (
    (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
    (trimmed.startsWith('[') && trimmed.endsWith(']'))
  ) {
    try {
      return safePrettyJson(JSON.parse(trimmed));
    } catch {
      /* fall through */
    }
  }
  return text;
}

/**
 * Append (or replace) a chat message.
 * @param {ChatMessage} msg
 */
export function appendMessage(msg) {
  const existing = state.messageEls.get(msg.id);
  const nearBottom = isNearBottom();
  const el = buildMessageEl(msg);
  if (existing && existing.parentNode === els.messages) {
    els.messages.replaceChild(el, existing);
  } else {
    els.messages.appendChild(el);
  }
  state.messageEls.set(msg.id, /** @type {HTMLDivElement} */ (el));
  state.messageText.set(msg.id, msg.text);
  if (nearBottom) scrollToBottom();
}

/** @param {ChatMessage[]} messages */
export function replaceMessages(messages) {
  while (els.messages.firstChild) els.messages.removeChild(els.messages.firstChild);
  state.messageEls.clear();
  state.messageText.clear();
  for (const m of messages) {
    const el = buildMessageEl(m);
    els.messages.appendChild(el);
    state.messageEls.set(m.id, /** @type {HTMLDivElement} */ (el));
    state.messageText.set(m.id, m.text);
  }
  scrollToBottom();
}

/**
 * Apply a streaming delta to an existing assistant message body.
 *
 * @param {string} messageId
 * @param {string} delta
 */
export function applyStreamDelta(messageId, delta) {
  let el = state.messageEls.get(messageId);
  if (!el) {
    // The host streams against the session id; if no element exists yet,
    // create a placeholder assistant message so the user sees output flow.
    appendMessage({ id: messageId, role: 'assistant', text: '' });
    el = state.messageEls.get(messageId);
    if (!el) return;
  }
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
 * Render or refresh an approval card for the given pending approval. If no
 * tool message exists yet, build one as a placeholder.
 *
 * @param {PendingApproval} approval
 */
export function showApproval(approval) {
  let el = state.messageEls.get(approval.id);
  if (!el) {
    appendMessage({
      id: approval.id,
      role: 'tool',
      text: summarizeToolInput(approval.input),
      toolName: approval.tool,
      toolStatus: 'pending',
    });
    el = state.messageEls.get(approval.id);
    if (!el) return;
  }
  el.classList.add('tool-needs-approval');

  // Replace the body's contents with a structured approval view.
  let body = el.querySelector('.tool-body');
  if (!body) {
    body = document.createElement('div');
    body.className = 'tool-body';
    el.appendChild(body);
  }
  while (body.firstChild) body.removeChild(body.firstChild);

  const inputLabel = document.createElement('div');
  inputLabel.className = 'tool-section-label';
  inputLabel.textContent = 'Input';
  const inputPre = document.createElement('pre');
  inputPre.className = 'tool-pre';
  const inputCode = document.createElement('code');
  inputCode.textContent = safePrettyJson(approval.input);
  inputPre.appendChild(inputCode);
  body.appendChild(inputLabel);
  body.appendChild(inputPre);

  const ask = document.createElement('div');
  ask.className = 'approval-ask';
  ask.textContent = `Allow ${approval.tool}?`;
  body.appendChild(ask);

  const row = document.createElement('div');
  row.className = 'approval-row';
  const approveBtn = document.createElement('button');
  approveBtn.type = 'button';
  approveBtn.className = 'primary-btn';
  approveBtn.textContent = 'Approve';
  const rejectBtn = document.createElement('button');
  rejectBtn.type = 'button';
  rejectBtn.className = 'secondary-btn';
  rejectBtn.textContent = 'Reject';
  approveBtn.addEventListener('click', () => {
    send({ type: 'approve', id: approval.id });
    approveBtn.disabled = true;
    rejectBtn.disabled = true;
  });
  rejectBtn.addEventListener('click', () => {
    send({ type: 'reject', id: approval.id });
    approveBtn.disabled = true;
    rejectBtn.disabled = true;
  });
  row.appendChild(approveBtn);
  row.appendChild(rejectBtn);
  body.appendChild(row);

  if (isNearBottom()) scrollToBottom();
}

/**
 * Resolve an approval (after approve/reject was sent or by host echo).
 * @param {string} id
 */
export function resolveApproval(id) {
  const el = state.messageEls.get(id);
  if (!el) return;
  el.classList.remove('tool-needs-approval');
  const row = el.querySelector('.approval-row');
  if (row) row.remove();
  const ask = el.querySelector('.approval-ask');
  if (ask) ask.remove();
  const status = el.querySelector('.tool-status');
  if (status) {
    status.className = 'tool-status status-completed';
    status.textContent = 'resolved';
  }
}

// ---------- Result footer --------------------------------------------------

/**
 * Append (or refresh) the "Done · cost · duration" footer on the most-recent
 * assistant message.
 *
 * @param {{ cost?: number, duration?: number }} info
 */
export function appendResultFooter(info) {
  /** @type {Element | null} */
  let lastAssistant = null;
  els.messages.querySelectorAll('.message-assistant').forEach((el) => {
    lastAssistant = el;
  });
  if (!lastAssistant) return;
  const prior = /** @type {Element} */ (lastAssistant).querySelector('.result-footer');
  if (prior) prior.remove();
  const parts = ['Done'];
  if (typeof info.cost === 'number') parts.push(`$${info.cost.toFixed(4)}`);
  if (typeof info.duration === 'number') parts.push(`${(info.duration / 1000).toFixed(1)}s`);
  const footer = document.createElement('div');
  footer.className = 'result-footer';
  footer.textContent = parts.join(' · ');
  /** @type {Element} */ (lastAssistant).appendChild(footer);
}

// ---------- Banners --------------------------------------------------------

/** @param {string} message */
export function pushBanner(message) {
  const banner = document.createElement('div');
  banner.className = 'banner banner-error';
  const text = document.createElement('span');
  text.className = 'banner-text';
  text.textContent = message;
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'banner-close';
  close.setAttribute('aria-label', 'Dismiss');
  close.textContent = '×';
  close.addEventListener('click', () => banner.remove());
  banner.appendChild(text);
  banner.appendChild(close);
  els.banners.appendChild(banner);
}

export function clearBanners() {
  while (els.banners.firstChild) els.banners.removeChild(els.banners.firstChild);
}

// ---------- Connection + topbar -------------------------------------------

/** @param {ConnectionState} cs */
export function setConnection(cs) {
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

/** @param {string} url @param {boolean} hasToken */
export function setBridgeUrl(url, hasToken) {
  els.bridgeUrl.textContent = url ? (hasToken ? `${url} · 🔒` : url) : '';
  els.bridgeUrl.title = url;
}

/**
 * Update the topbar's compact session indicator (project + stop button).
 * @param {string | null} project @param {string | null} sessionId
 */
export function setActiveMini(project, sessionId) {
  if (!project && !sessionId) {
    els.activeMini.textContent = '';
    els.stopBtn.hidden = true;
    return;
  }
  const sess = sessionId ? ` · #${sessionId.slice(0, 8)}` : '';
  els.activeMini.textContent = project ? `${shorten(project)}${sess}` : sess;
  els.activeMini.title = project || '';
  els.stopBtn.hidden = !sessionId;
}

/** @param {string} p */
function shorten(p) {
  const parts = p.split(/[\\/]+/).filter(Boolean);
  if (parts.length <= 2) return p;
  return '…/' + parts.slice(-2).join('/');
}

// Bind topbar buttons.
els.reconnectBtn.addEventListener('click', () => send({ type: 'reconnect' }));
els.stopBtn.addEventListener('click', () => send({ type: 'stop-session' }));
