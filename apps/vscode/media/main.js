// @ts-check
/*
 * CC Pocket — native VSCode webview chat UI.
 *
 * Module orchestrator: wires inbound host messages to the chat/composer/
 * sessions modules, dispatches outbound messages, and boots the UI.
 *
 * Module split:
 *   - state.js     vscode bridge + persisted/session state, helpers, toast
 *   - markdown.js  markdown subset, syntax highlighting, diff rendering
 *   - chat.js      message rendering, approvals, streaming, banners, topbar
 *   - composer.js  textarea, +menu, mic, mode chip, chips, send
 *   - sessions.js  left rail (active/recent/projects), collapse
 *   - main.js      dispatch + boot (this file)
 */

/** @typedef {import('../src/messages.js').ExtensionToWebview} ExtensionToWebview */

import { state, send, showToast } from './state.js';
import {
  appendMessage,
  replaceMessages,
  applyStreamDelta,
  showApproval,
  resolveApproval,
  appendResultFooter,
  pushBanner,
  setConnection,
  setBridgeUrl,
  setActiveMini,
} from './chat.js';
import { bootComposer, addAttachment, removeAttachment } from './composer.js';
import { bootSidebar, renderSidebar } from './sessions.js';

// ---------- Inbound dispatch -----------------------------------------------

/** @param {MessageEvent<ExtensionToWebview>} event */
function handleMessage(event) {
  const msg = event.data;
  if (!msg || typeof msg !== 'object' || typeof msg.type !== 'string') return;
  switch (msg.type) {
    case 'config': {
      state.defaultProjectPath = msg.defaultProjectPath;
      state.projects = msg.allowedDirs || [];
      state.bridgeUrl = msg.bridgeUrl || '';
      state.hasToken = Boolean(msg.hasToken);
      if (msg.defaultProjectPath && !state.activeProjectPath) {
        state.activeProjectPath = msg.defaultProjectPath;
      }
      setBridgeUrl(state.bridgeUrl, state.hasToken);
      renderSidebar();
      break;
    }
    case 'connection-state':
      setConnection(msg.state);
      break;
    case 'session-list':
      state.sessions = msg.sessions || [];
      state.recent = msg.recent || [];
      if (msg.projects && msg.projects.length > 0) {
        state.projects = msg.projects;
      }
      renderSidebar();
      break;
    case 'session-active':
      state.activeSessionId = msg.sessionId;
      state.activeProjectPath = msg.projectPath;
      state.status = msg.status;
      setActiveMini(state.activeProjectPath, state.activeSessionId);
      renderSidebar();
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
    case 'file-attached':
      addAttachment(msg.attachment);
      break;
    case 'error':
      pushBanner(msg.message);
      // Also fire a transient toast so it's seen even when the banner stack
      // is scrolled off; the banner stays for explicit dismissal.
      showToast(msg.message);
      break;
    default:
      // Unknown — older webviews shouldn't break on new host messages.
      break;
  }
}

window.addEventListener('message', handleMessage);

// Re-export some helpers so external callers (debug console) can poke state
// without us tree-shaking them out.
// eslint-disable-next-line no-unused-expressions
[removeAttachment];

// ---------- Boot ----------------------------------------------------------

function boot() {
  setConnection({ state: 'idle' });
  setBridgeUrl('', false);
  bootSidebar();
  bootComposer();
  send({ type: 'ready' });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot, { once: true });
} else {
  boot();
}
