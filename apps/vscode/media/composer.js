// @ts-check
/*
 * Composer: textarea + "+" menu + mic + mode chip + file chips + send.
 *
 * Persists draft, attachment chips, and selected mode through `vscode.setState`.
 */

/** @typedef {import('../src/messages.js').AttachmentRef} AttachmentRef */
/** @typedef {import('../src/messages.js').PermissionMode} PermissionMode */
/** @typedef {import('../src/messages.js').WebviewToExtension} WebviewToExtension */

import { $, state, send, persist, basename, showToast } from './state.js';

const els = {
  composer: /** @type {HTMLElement} */ ($('composer')),
  input: /** @type {HTMLTextAreaElement} */ ($('input')),
  chips: /** @type {HTMLDivElement} */ ($('chips')),
  plusBtn: /** @type {HTMLButtonElement} */ ($('plus-btn')),
  plusMenu: /** @type {HTMLDivElement} */ ($('plus-menu')),
  micBtn: /** @type {HTMLButtonElement} */ ($('mic-btn')),
  modeBtn: /** @type {HTMLButtonElement} */ ($('mode-btn')),
  modeLabel: /** @type {HTMLSpanElement} */ ($('mode-label')),
  modeMenu: /** @type {HTMLDivElement} */ ($('mode-menu')),
  sendBtn: /** @type {HTMLButtonElement} */ ($('send-btn')),
};

/** Mode display data. Keep order matching the popover. */
/** @type {Array<{ mode: PermissionMode, label: string, sub: string }>} */
const MODES = [
  { mode: 'default', label: 'Ask before edits', sub: 'Confirm each tool call' },
  { mode: 'acceptEdits', label: 'Edit automatically', sub: 'Apply file edits without asking' },
  { mode: 'plan', label: 'Plan mode', sub: 'Plan before any changes' },
  { mode: 'bypassPermissions', label: 'Auto mode', sub: 'Bypass all permission prompts' },
];

// ---------- Mode chip ------------------------------------------------------

function renderMode() {
  const cur = state.persisted.permissionMode;
  const def = MODES.find((m) => m.mode === cur) ?? MODES[1];
  els.modeLabel.textContent = def.label;
  // Update check marks in the popover.
  els.modeMenu.querySelectorAll('.popover-item').forEach((el) => {
    const item = /** @type {HTMLElement} */ (el);
    const isCurrent = item.dataset.mode === cur;
    item.classList.toggle('is-active', isCurrent);
  });
  els.modeBtn.dataset.mode = cur;
}

/** @param {PermissionMode} mode */
function setMode(mode) {
  state.persisted.permissionMode = mode;
  persist();
  renderMode();
  closeMenus();
}

// ---------- Popovers --------------------------------------------------------

function closeMenus() {
  els.plusMenu.hidden = true;
  els.modeMenu.hidden = true;
  els.plusBtn.setAttribute('aria-expanded', 'false');
  els.modeBtn.setAttribute('aria-expanded', 'false');
}

/** @param {HTMLElement} menu @param {HTMLElement} anchor */
function toggleMenu(menu, anchor) {
  const opening = menu.hidden;
  closeMenus();
  if (opening) {
    menu.hidden = false;
    anchor.setAttribute('aria-expanded', 'true');
  }
}

els.plusBtn.addEventListener('click', (ev) => {
  ev.stopPropagation();
  toggleMenu(els.plusMenu, els.plusBtn);
});
els.modeBtn.addEventListener('click', (ev) => {
  ev.stopPropagation();
  toggleMenu(els.modeMenu, els.modeBtn);
});

// Close menus on outside click / Esc.
document.addEventListener('click', (ev) => {
  const t = /** @type {Node | null} */ (ev.target);
  if (!t) return;
  if (els.plusMenu.contains(t) || els.modeMenu.contains(t) || els.plusBtn.contains(t) || els.modeBtn.contains(t)) {
    return;
  }
  closeMenus();
});
document.addEventListener('keydown', (ev) => {
  if (ev.key === 'Escape') closeMenus();
});

// Wire popover items.
els.plusMenu.querySelectorAll('.popover-item').forEach((el) => {
  el.addEventListener('click', () => {
    const action = /** @type {HTMLElement} */ (el).dataset.action;
    if (!action) return;
    /** @type {WebviewToExtension | null} */
    let msg = null;
    if (action === 'pick-workspace-file') msg = { type: 'pick-workspace-file' };
    else if (action === 'pick-open-editor') msg = { type: 'pick-open-editor' };
    else if (action === 'pick-system-file') msg = { type: 'pick-system-file' };
    else if (action === 'add-active-selection') msg = { type: 'add-active-selection' };
    if (msg) send(msg);
    closeMenus();
  });
});

els.modeMenu.querySelectorAll('.popover-item').forEach((el) => {
  el.addEventListener('click', () => {
    const mode = /** @type {HTMLElement} */ (el).dataset.mode;
    if (!mode) return;
    setMode(/** @type {PermissionMode} */ (mode));
  });
});

// ---------- File chips -----------------------------------------------------

function renderChips() {
  const chips = state.persisted.attachments;
  while (els.chips.firstChild) els.chips.removeChild(els.chips.firstChild);
  if (chips.length === 0) {
    els.chips.hidden = true;
    return;
  }
  els.chips.hidden = false;
  for (const att of chips) {
    const chip = document.createElement('span');
    chip.className = 'chip';
    chip.dataset.path = att.path;

    const icon = document.createElement('span');
    icon.className = 'chip-icon';
    icon.textContent = '📄';
    chip.appendChild(icon);

    const label = document.createElement('span');
    label.className = 'chip-label';
    label.textContent = att.label || basename(att.path);
    label.title = att.path;
    chip.appendChild(label);

    if (typeof att.startLine === 'number') {
      const range = document.createElement('span');
      range.className = 'chip-range';
      range.textContent =
        typeof att.endLine === 'number' && att.endLine !== att.startLine
          ? `:${att.startLine}-${att.endLine}`
          : `:${att.startLine}`;
      chip.appendChild(range);
    }

    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'chip-close';
    close.setAttribute('aria-label', `Remove ${att.path}`);
    close.textContent = '×';
    close.addEventListener('click', () => {
      send({ type: 'remove-attachment', path: att.path });
      removeAttachment(att.path);
    });
    chip.appendChild(close);

    els.chips.appendChild(chip);
  }
}

/** @param {AttachmentRef} att */
export function addAttachment(att) {
  // De-dup by path+range.
  const idx = state.persisted.attachments.findIndex(
    (a) => a.path === att.path && a.startLine === att.startLine && a.endLine === att.endLine,
  );
  if (idx >= 0) {
    state.persisted.attachments[idx] = att;
  } else {
    state.persisted.attachments.push(att);
  }
  persist();
  renderChips();
  updateSendEnabled();
}

/** @param {string} path */
export function removeAttachment(path) {
  state.persisted.attachments = state.persisted.attachments.filter((a) => a.path !== path);
  persist();
  renderChips();
  updateSendEnabled();
}

export function clearAttachments() {
  if (state.persisted.attachments.length === 0) return;
  state.persisted.attachments = [];
  persist();
  renderChips();
  updateSendEnabled();
}

// ---------- Textarea auto-resize + draft persistence -----------------------

function autoResize() {
  const ta = els.input;
  ta.style.height = 'auto';
  // Roughly 10 lines: line-height ~ 18px * 10 + padding ≈ 200px.
  ta.style.height = Math.min(ta.scrollHeight, 200) + 'px';
}

function updateSendEnabled() {
  const hasText = els.input.value.trim().length > 0;
  const hasChips = state.persisted.attachments.length > 0;
  els.sendBtn.disabled = !(hasText || hasChips);
}

els.input.addEventListener('input', () => {
  autoResize();
  state.persisted.draft = els.input.value;
  persist();
  updateSendEnabled();
});

els.input.addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) {
    ev.preventDefault();
    submit();
  }
});

// ---------- Submit ---------------------------------------------------------

function submit() {
  const text = els.input.value.trim();
  const attachments = [...state.persisted.attachments];
  if (!text && attachments.length === 0) return;
  /** @type {WebviewToExtension} */
  const msg = {
    type: 'user-input',
    text,
    permissionMode: state.persisted.permissionMode,
    attachments: attachments.length > 0 ? attachments : undefined,
  };
  send(msg);
  els.input.value = '';
  state.persisted.draft = '';
  state.persisted.attachments = [];
  persist();
  renderChips();
  autoResize();
  updateSendEnabled();
}

els.sendBtn.addEventListener('click', submit);

// ---------- Mic / Web Speech API -------------------------------------------

/**
 * @typedef {Object} SpeechRecognitionLike
 * @property {boolean} continuous
 * @property {boolean} interimResults
 * @property {string} lang
 * @property {((ev: any) => void) | null} onresult
 * @property {((ev: any) => void) | null} onerror
 * @property {(() => void) | null} onend
 * @property {() => void} start
 * @property {() => void} stop
 */

/** @type {SpeechRecognitionLike | null} */
let recognition = null;
let isRecording = false;

function speechRecognitionAvailable() {
  // @ts-ignore — vendor-prefixed.
  return Boolean(window.SpeechRecognition || window.webkitSpeechRecognition);
}

async function startMic() {
  if (!speechRecognitionAvailable()) {
    showToast('Voice input unavailable in this webview.');
    return;
  }
  // Probe mic permission first (the webview's permission state can differ).
  try {
    if (navigator.mediaDevices && typeof navigator.mediaDevices.getUserMedia === 'function') {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
    }
  } catch (err) {
    showToast('Microphone permission denied.');
    return;
  }
  try {
    // @ts-ignore — vendor-prefixed constructors.
    const Ctor = window.SpeechRecognition || window.webkitSpeechRecognition;
    /** @type {SpeechRecognitionLike} */
    const rec = new Ctor();
    rec.continuous = false;
    rec.interimResults = false;
    rec.lang = navigator.language || 'en-US';
    rec.onresult = (ev) => {
      try {
        const results = /** @type {{ results: { 0: { transcript: string } }[] }} */ (ev).results;
        let transcript = '';
        for (const r of /** @type {Iterable<{ 0: { transcript: string } }>} */ (results)) {
          transcript += r[0].transcript;
        }
        if (transcript) {
          const cur = els.input.value;
          const sep = cur && !cur.endsWith(' ') ? ' ' : '';
          els.input.value = cur + sep + transcript;
          state.persisted.draft = els.input.value;
          persist();
          autoResize();
          updateSendEnabled();
        }
      } catch (e) {
        // swallow.
      }
    };
    rec.onerror = (ev) => {
      const err = ev && /** @type {{ error?: string }} */ (ev).error;
      showToast(`Voice input error${err ? ': ' + err : ''}`);
      stopMic();
    };
    rec.onend = () => {
      stopMic();
    };
    recognition = rec;
    rec.start();
    isRecording = true;
    els.micBtn.classList.add('is-recording');
    els.micBtn.title = 'Stop recording';
  } catch (err) {
    showToast('Could not start voice input.');
  }
}

function stopMic() {
  if (recognition) {
    try { recognition.stop(); } catch { /* ignore */ }
  }
  recognition = null;
  isRecording = false;
  els.micBtn.classList.remove('is-recording');
  els.micBtn.title = 'Voice input';
}

els.micBtn.addEventListener('click', () => {
  if (isRecording) stopMic();
  else void startMic();
});

// If speech recognition isn't available at all, mark the button visually.
if (!speechRecognitionAvailable()) {
  els.micBtn.classList.add('is-unavailable');
  els.micBtn.title = 'Voice input unavailable';
}

// ---------- Initial boot ---------------------------------------------------

export function bootComposer() {
  els.input.value = state.persisted.draft || '';
  autoResize();
  renderMode();
  renderChips();
  updateSendEnabled();
}
