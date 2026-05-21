// @ts-check
/*
 * Session sidebar: active card + recent list + projects + new-session button
 * + collapse toggle. All untrusted text uses textContent.
 */

/** @typedef {import('../src/messages.js').BridgeSession} BridgeSession */
/** @typedef {import('../src/messages.js').WebviewToExtension} WebviewToExtension */

import { $, state, send, persist, shortenPath, basename, truncate, relativeTime } from './state.js';

const els = {
  app: /** @type {HTMLDivElement} */ ($('app')),
  sidebar: /** @type {HTMLElement} */ ($('sidebar')),
  toggleBtn: /** @type {HTMLButtonElement} */ ($('sidebar-toggle')),
  topbarToggleBtn: /** @type {HTMLButtonElement | null} */ (document.getElementById('topbar-sidebar-toggle')),
  backdrop: /** @type {HTMLDivElement | null} */ (document.getElementById('sidebar-backdrop')),
  newBtn: /** @type {HTMLButtonElement} */ ($('new-session-btn')),
  activeCard: /** @type {HTMLDivElement} */ ($('active-card')),
  recentList: /** @type {HTMLUListElement} */ ($('recent-list')),
  projectsList: /** @type {HTMLUListElement} */ ($('projects-list')),
};

// ---------- Collapsed-rail / drawer state ---------------------------------
//
// Wide widths (>640px): "sidebar-collapsed" toggles between the full 240px
// rail and a 38px icon-only rail. "sidebar-open" is meaningless.
//
// Narrow widths (<=640px): the sidebar is an off-canvas drawer. "sidebar-
// collapsed" is implicit (chat is full width by default); "sidebar-open"
// slides the drawer over the chat with a backdrop. The same toggle button
// drives both modes — we look at viewport width on click to decide.

const NARROW_BREAKPOINT = 640;

function isNarrow() {
  return window.matchMedia(`(max-width: ${NARROW_BREAKPOINT}px)`).matches;
}

function applyCollapsed() {
  const collapsed = state.persisted.sidebarCollapsed;
  els.app.classList.toggle('sidebar-collapsed', collapsed);
  els.toggleBtn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
}

function setDrawerOpen(open) {
  els.app.classList.toggle('sidebar-open', open);
  els.toggleBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
  if (els.topbarToggleBtn) {
    els.topbarToggleBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
  }
}

function toggleSidebar() {
  if (isNarrow()) {
    setDrawerOpen(!els.app.classList.contains('sidebar-open'));
    return;
  }
  state.persisted.sidebarCollapsed = !state.persisted.sidebarCollapsed;
  persist();
  applyCollapsed();
}

els.toggleBtn.addEventListener('click', toggleSidebar);
if (els.topbarToggleBtn) {
  els.topbarToggleBtn.addEventListener('click', toggleSidebar);
}
if (els.backdrop) {
  els.backdrop.addEventListener('click', () => setDrawerOpen(false));
}
// Close the drawer with Esc, and close it automatically when crossing the
// narrow breakpoint upward (so the wide layout doesn't get stuck open).
document.addEventListener('keydown', (ev) => {
  if (ev.key === 'Escape' && els.app.classList.contains('sidebar-open')) {
    setDrawerOpen(false);
  }
});
window.addEventListener('resize', () => {
  if (!isNarrow() && els.app.classList.contains('sidebar-open')) {
    setDrawerOpen(false);
  }
});

// ---------- New session ----------------------------------------------------

els.newBtn.addEventListener('click', () => {
  const fallback = state.activeProjectPath || state.defaultProjectPath || '';
  const projectPath = window.prompt('Project path for new session:', fallback);
  if (!projectPath) return;
  /** @type {WebviewToExtension} */
  const msg = {
    type: 'start-session',
    projectPath,
    permissionMode: state.persisted.permissionMode,
  };
  send(msg);
});

// ---------- Renderers ------------------------------------------------------

export function renderActiveCard() {
  const card = els.activeCard;
  while (card.firstChild) card.removeChild(card.firstChild);
  if (!state.activeSessionId && !state.activeProjectPath) {
    card.classList.add('empty');
    card.textContent = 'No active session.';
    return;
  }
  card.classList.remove('empty');

  const top = document.createElement('div');
  top.className = 'active-top';
  const projectEl = document.createElement('span');
  projectEl.className = 'active-project';
  projectEl.textContent = state.activeProjectPath
    ? shortenPath(state.activeProjectPath)
    : '(no project)';
  projectEl.title = state.activeProjectPath || '';
  top.appendChild(projectEl);

  const badge = document.createElement('span');
  const status = state.status || 'idle';
  badge.className = `status-badge status-${status}`;
  badge.textContent = status;
  top.appendChild(badge);
  card.appendChild(top);

  if (state.activeSessionId) {
    const sid = document.createElement('div');
    sid.className = 'active-sid';
    sid.textContent = `#${state.activeSessionId.slice(0, 12)}`;
    card.appendChild(sid);
    // Stop action lives in the topbar — keep this card visual-only so we
    // don't duplicate controls.
  }
}

export function renderRecent() {
  const list = els.recentList;
  while (list.firstChild) list.removeChild(list.firstChild);
  const recent = state.recent.slice(0, 30);
  if (recent.length === 0) {
    const li = document.createElement('li');
    li.className = 'sidebar-empty';
    li.textContent = 'No recent sessions yet.';
    list.appendChild(li);
    return;
  }
  for (const s of recent) {
    const li = document.createElement('li');
    li.className = 'session-item';
    if (s.sessionId === state.activeSessionId) li.classList.add('is-active');

    const head = document.createElement('div');
    head.className = 'session-item-head';

    const provider = document.createElement('span');
    const prov = (s.provider || 'claude').toString();
    provider.className = `provider-chip provider-${prov}`;
    provider.textContent = prov;
    head.appendChild(provider);

    const when = document.createElement('span');
    when.className = 'session-when';
    when.textContent = relativeTime(/** @type {string|undefined} */ (s.lastModified));
    head.appendChild(when);

    li.appendChild(head);

    const prompt = document.createElement('div');
    prompt.className = 'session-prompt';
    prompt.textContent = truncate((s.firstPrompt || s.sessionId || '').toString(), 80);
    prompt.title = (s.firstPrompt || '').toString();
    li.appendChild(prompt);

    if (s.projectPath) {
      const proj = document.createElement('div');
      proj.className = 'session-proj';
      proj.textContent = shortenPath(/** @type {string} */ (s.projectPath));
      proj.title = /** @type {string} */ (s.projectPath);
      li.appendChild(proj);
    }

    li.addEventListener('click', () => {
      send({ type: 'switch-session', sessionId: s.sessionId });
    });
    list.appendChild(li);
  }
}

export function renderProjects() {
  const list = els.projectsList;
  while (list.firstChild) list.removeChild(list.firstChild);
  const projects = state.projects;
  if (projects.length === 0) {
    const li = document.createElement('li');
    li.className = 'sidebar-empty';
    li.textContent = 'No projects allowed by the bridge.';
    list.appendChild(li);
    return;
  }
  for (const p of projects) {
    const li = document.createElement('li');
    li.className = 'project-item';
    if (p === state.activeProjectPath) li.classList.add('is-active');

    const name = document.createElement('div');
    name.className = 'project-name';
    name.textContent = basename(p);
    li.appendChild(name);

    const path = document.createElement('div');
    path.className = 'project-path';
    path.textContent = shortenPath(p);
    path.title = p;
    li.appendChild(path);

    li.addEventListener('click', () => {
      /** @type {WebviewToExtension} */
      const msg = {
        type: 'start-session',
        projectPath: p,
        permissionMode: state.persisted.permissionMode,
      };
      send(msg);
    });
    list.appendChild(li);
  }
}

export function renderSidebar() {
  renderActiveCard();
  renderRecent();
  renderProjects();
}

export function bootSidebar() {
  applyCollapsed();
  renderSidebar();
}
