import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { BridgeClient, type BridgeClientEvent } from './bridgeClient.js';
import { buildHtml } from './buildHtml.js';
import type {
  AttachmentRef,
  BridgeMessage,
  BridgeRequest,
  BridgeSession,
  ChatMessage,
  ConnectionState,
  ExtensionToWebview,
  PendingApproval,
  SessionStatus,
  WebviewToExtension,
} from './messages.js';

const PANEL_VIEW_TYPE = 'ccpocket.panel';

interface Settings {
  bridgeUrl: string;
  bridgeToken: string;
}

function readSettings(): Settings {
  const cfg = vscode.workspace.getConfiguration('ccpocket');
  return {
    bridgeUrl: cfg.get<string>('bridgeUrl', 'ws://localhost:8765'),
    bridgeToken: cfg.get<string>('bridgeToken', ''),
  };
}

function tokenOrNull(token: string): string | null {
  return token && token.length > 0 ? token : null;
}

function defaultProjectPath(): string | null {
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? null;
}

// ---- Per-panel state ------------------------------------------------------

interface PanelState {
  id: string;
  panel: vscode.WebviewPanel;
  activeSessionId: string | null;
  activeProjectPath: string | null;
  activeStatus: SessionStatus;
  pendingSwitches: Set<string>;
}

/**
 * Registry of open chat panels. Each panel keeps its own active session, so
 * multiple tabs can hold independent conversations against the same bridge.
 */
class PanelRegistry {
  private panels = new Map<string, PanelState>();
  private nextId = 1;

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly onMessage: (panelId: string, msg: WebviewToExtension) => void,
  ) {}

  openNew(): PanelState {
    const id = `p${this.nextId++}`;
    const panel = vscode.window.createWebviewPanel(
      PANEL_VIEW_TYPE,
      'CC Pocket',
      vscode.ViewColumn.Active,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, 'media')],
      },
    );
    panel.webview.html = buildHtml(panel.webview, this.extensionUri);

    const state: PanelState = {
      id,
      panel,
      activeSessionId: null,
      activeProjectPath: null,
      activeStatus: 'idle',
      pendingSwitches: new Set(),
    };
    this.panels.set(id, state);

    panel.webview.onDidReceiveMessage((raw: unknown) => {
      if (!raw || typeof raw !== 'object' || !('type' in raw)) return;
      this.onMessage(id, raw as WebviewToExtension);
    });

    panel.onDidDispose(() => {
      this.panels.delete(id);
    });

    return state;
  }

  get(panelId: string): PanelState | undefined {
    return this.panels.get(panelId);
  }

  forEach(fn: (state: PanelState) => void): void {
    this.panels.forEach(fn);
  }

  postTo(panelId: string, msg: ExtensionToWebview): void {
    const state = this.panels.get(panelId);
    if (state) void state.panel.webview.postMessage(msg);
  }

  postToState(state: PanelState, msg: ExtensionToWebview): void {
    void state.panel.webview.postMessage(msg);
  }

  broadcast(msg: ExtensionToWebview): void {
    this.panels.forEach((state) => {
      void state.panel.webview.postMessage(msg);
    });
  }

  /** Find panels currently watching the given sessionId. */
  findBySession(sessionId: string): PanelState[] {
    const out: PanelState[] = [];
    this.panels.forEach((s) => {
      if (s.activeSessionId === sessionId) out.push(s);
    });
    return out;
  }

  isEmpty(): boolean {
    return this.panels.size === 0;
  }
}

// ---- File link handling ---------------------------------------------------

function resolveFilePath(rawPath: string): string | undefined {
  if (path.isAbsolute(rawPath)) return rawPath;

  const folders = vscode.workspace.workspaceFolders ?? [];
  if (folders.length === 0) return undefined;

  const activeUri = vscode.window.activeTextEditor?.document.uri;
  const ordered = [...folders].sort((a, b) => {
    if (!activeUri) return 0;
    const aMatch = activeUri.fsPath.startsWith(a.uri.fsPath) ? -1 : 0;
    const bMatch = activeUri.fsPath.startsWith(b.uri.fsPath) ? -1 : 0;
    return aMatch - bMatch;
  });

  for (const folder of ordered) {
    const candidate = path.join(folder.uri.fsPath, rawPath);
    if (fs.existsSync(candidate)) return candidate;
  }
  return path.join(ordered[0].uri.fsPath, rawPath);
}

async function openFileInEditor(p: { path: string; line?: number }): Promise<void> {
  const resolved = resolveFilePath(p.path);
  if (!resolved) {
    void vscode.window.showWarningMessage(
      `CC Pocket: cannot open "${p.path}" — no workspace folder.`,
    );
    return;
  }
  try {
    const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(resolved));
    const line = typeof p.line === 'number' && p.line > 0 ? p.line - 1 : 0;
    const position = new vscode.Position(line, 0);
    await vscode.window.showTextDocument(doc, {
      selection: new vscode.Range(position, position),
      preserveFocus: false,
    });
  } catch (err) {
    void vscode.window.showWarningMessage(
      `CC Pocket: failed to open "${p.path}": ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
}

// ---- Bridge content helpers ----------------------------------------------

function bridgeContentToText(value: unknown): string {
  if (typeof value === 'string') return value;
  if (value === null || value === undefined) return '';
  if (Array.isArray(value)) {
    return value
      .map((chunk) => {
        if (typeof chunk === 'string') return chunk;
        if (chunk && typeof chunk === 'object' && 'text' in chunk) {
          const t = (chunk as { text?: unknown }).text;
          if (typeof t === 'string') return t;
        }
        return '';
      })
      .filter((s) => s.length > 0)
      .join('');
  }
  if (typeof value === 'object' && value !== null && 'text' in value) {
    const t = (value as { text?: unknown }).text;
    if (typeof t === 'string') return t;
  }
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function historyItemToChat(item: unknown, sessionId: string, index: number): ChatMessage | null {
  if (!item || typeof item !== 'object') return null;
  const m = item as { type?: unknown; role?: unknown; text?: unknown; content?: unknown; id?: unknown };
  const role: ChatMessage['role'] =
    m.role === 'assistant' || m.type === 'assistant'
      ? 'assistant'
      : m.role === 'tool' || m.type === 'tool_result'
        ? 'tool'
        : 'user';
  const text = bridgeContentToText(m.text ?? m.content);
  if (!text && role !== 'tool') return null;
  const id = typeof m.id === 'string' ? m.id : `${sessionId}-history-${index}`;
  return { id, role, text };
}

// ---- Attachment / prompt helpers -----------------------------------------

/**
 * Fold attachments into the user's typed prompt as a small `<context>` block
 * listing path references. File contents are intentionally NOT inlined — the
 * bridge's Claude Code / Codex session has a Read tool and will read on demand.
 *
 * Falls back to the raw text untouched when there are no attachments.
 */
function buildPromptWithAttachments(text: string, attachments?: AttachmentRef[]): string {
  if (!attachments || attachments.length === 0) return text;
  const lines: string[] = ['<context>'];
  for (const a of attachments) {
    if (typeof a.path !== 'string' || a.path.length === 0) continue;
    const hasRange =
      typeof a.startLine === 'number' &&
      typeof a.endLine === 'number' &&
      a.startLine > 0 &&
      a.endLine >= a.startLine;
    if (hasRange) {
      lines.push(`- ${a.path}:${a.startLine}-${a.endLine} (selection)`);
    } else {
      lines.push(`- ${a.path}`);
    }
  }
  lines.push('</context>');
  lines.push('');
  lines.push(text);
  return lines.join('\n');
}

// ---- Extension entry point -----------------------------------------------

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel('CC Pocket');
  context.subscriptions.push(output);
  const log = (msg: string): void => {
    output.appendLine(`[${new Date().toISOString()}] ${msg}`);
  };

  // One BridgeClient serves all panels.
  const { bridgeUrl, bridgeToken } = readSettings();
  const bridgeClient = new BridgeClient({
    url: bridgeUrl,
    token: tokenOrNull(bridgeToken),
    log,
  });
  context.subscriptions.push(bridgeClient);

  // Coalesced session-list snapshot — broadcast to all panels.
  let lastSessions: BridgeSession[] | undefined;
  let lastRecent: BridgeSession[] | undefined;
  let lastProjects: string[] | undefined;
  let lastSessionListEvent: Extract<ExtensionToWebview, { type: 'session-list' }> | null = null;

  // Last connection state — broadcast to all panels and replayed to new ones.
  let lastConnectionState: ConnectionState = { state: 'idle' };

  // FIFO queue of panels that have sent `start` and are awaiting `session_created`.
  const pendingStartQueue: string[] = [];

  const registry = new PanelRegistry(context.extensionUri, handleWebviewMessage);

  // ---- Command: open a NEW panel each time --------------------------------
  context.subscriptions.push(
    vscode.commands.registerCommand('ccpocket.open', () => {
      registry.openNew();
    }),
  );

  // ---- Status bar shortcut ------------------------------------------------
  const statusBarItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100,
  );
  statusBarItem.text = '$(comment-discussion) CC Pocket';
  statusBarItem.tooltip = 'Open a new CC Pocket panel';
  statusBarItem.command = 'ccpocket.open';
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  // ---- React to setting changes -------------------------------------------
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (!event.affectsConfiguration('ccpocket')) return;
      const next = readSettings();
      bridgeClient.updateOptions({
        url: next.bridgeUrl,
        token: tokenOrNull(next.bridgeToken),
      });
      registry.broadcast({
        type: 'config',
        bridgeUrl: next.bridgeUrl,
        hasToken: tokenOrNull(next.bridgeToken) !== null,
        allowedDirs: [],
        defaultProjectPath: defaultProjectPath(),
      });
    }),
  );

  // ---- Bridge → webview routing -------------------------------------------
  context.subscriptions.push(
    bridgeClient.onEvent((event: BridgeClientEvent) => {
      switch (event.type) {
        case 'state': {
          const next: ConnectionState =
            event.state === 'connecting'
              ? { state: 'connecting' }
              : event.state === 'connected'
                ? { state: 'connected' }
                : { state: 'disconnected', reason: event.reason };
          lastConnectionState = next;
          registry.broadcast({ type: 'connection-state', state: next });
          break;
        }
        case 'error': {
          lastConnectionState = { state: 'error', message: event.error.message };
          registry.broadcast({ type: 'connection-state', state: lastConnectionState });
          registry.broadcast({ type: 'error', message: event.error.message });
          log(`bridge error: ${event.error.message}`);
          break;
        }
        case 'message': {
          handleBridgeMessage(event.message);
          break;
        }
      }
    }),
  );

  // ---- Webview → extension router (per panel) -----------------------------
  function handleWebviewMessage(panelId: string, msg: WebviewToExtension): void {
    const state = registry.get(panelId);
    if (!state) return;

    switch (msg.type) {
      case 'ready': {
        const { bridgeUrl: u, bridgeToken: t } = readSettings();
        registry.postToState(state, {
          type: 'config',
          bridgeUrl: u,
          hasToken: tokenOrNull(t) !== null,
          allowedDirs: [],
          defaultProjectPath: defaultProjectPath(),
        });
        registry.postToState(state, { type: 'connection-state', state: lastConnectionState });
        if (lastSessionListEvent) registry.postToState(state, lastSessionListEvent);
        if (
          bridgeClient.state === 'idle' ||
          bridgeClient.state === 'disconnected'
        ) {
          bridgeClient.connect();
        }
        break;
      }

      case 'user-input': {
        const promptText = buildPromptWithAttachments(msg.text, msg.attachments);
        // Optimistic local echo to the originating panel only. The webview owns
        // its own chip state; we echo the raw user-typed text, not the folded
        // <context> block.
        const echoId =
          (state.activeSessionId ?? state.id) + '-user-' + Date.now().toString(36);
        registry.postToState(state, {
          type: 'chat-append',
          message: { id: echoId, role: 'user', text: msg.text },
        });

        try {
          if (state.activeSessionId === null && state.activeProjectPath !== null) {
            // No active session yet — fold any per-send permissionMode into the
            // implicit `start` request.
            pendingStartQueue.push(state.id);
            const startReq: Extract<BridgeRequest, { type: 'start' }> = {
              type: 'start',
              projectPath: state.activeProjectPath,
              continue: false,
            };
            if (msg.permissionMode !== undefined) {
              startReq.permissionMode = msg.permissionMode;
            }
            bridgeClient.send(startReq);
            bridgeClient.send({ type: 'input', text: promptText });
          } else if (state.activeSessionId !== null) {
            if (msg.permissionMode !== undefined) {
              // Bridge `input` doesn't accept a per-send mode today — log and
              // keep the chip as a "default for next session" hint only.
              log(
                `[permission-mode] ignored per-send mode "${msg.permissionMode}" — ` +
                  `session ${state.activeSessionId} already active`,
              );
            }
            bridgeClient.send({
              type: 'input',
              text: promptText,
              sessionId: state.activeSessionId,
            });
          } else {
            registry.postToState(state, {
              type: 'error',
              message:
                'No active session and no project path is set. Select a project or session first.',
            });
          }
        } catch (err) {
          registry.postToState(state, {
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'start-session': {
        state.activeProjectPath = msg.projectPath;
        state.activeSessionId = null;
        state.activeStatus = 'idle';
        registry.postToState(state, {
          type: 'session-active',
          sessionId: null,
          projectPath: state.activeProjectPath,
          status: state.activeStatus,
        });
        try {
          pendingStartQueue.push(state.id);
          bridgeClient.send({
            type: 'start',
            projectPath: msg.projectPath,
            permissionMode: msg.permissionMode,
          });
        } catch (err) {
          registry.postToState(state, {
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'switch-session': {
        state.pendingSwitches.add(msg.sessionId);
        try {
          bridgeClient.send({ type: 'get_history', sessionId: msg.sessionId });
        } catch (err) {
          state.pendingSwitches.delete(msg.sessionId);
          registry.postToState(state, {
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'stop-session': {
        if (state.activeSessionId !== null) {
          try {
            bridgeClient.send({ type: 'stop_session', sessionId: state.activeSessionId });
          } catch (err) {
            registry.postToState(state, {
              type: 'error',
              message: err instanceof Error ? err.message : String(err),
            });
          }
        }
        break;
      }

      case 'approve': {
        if (state.activeSessionId !== null) {
          try {
            bridgeClient.send({
              type: 'approve',
              id: msg.id,
              sessionId: state.activeSessionId,
            });
            registry.postToState(state, {
              type: 'approval-resolved',
              sessionId: state.activeSessionId,
              id: msg.id,
            });
          } catch (err) {
            registry.postToState(state, {
              type: 'error',
              message: err instanceof Error ? err.message : String(err),
            });
          }
        }
        break;
      }

      case 'reject': {
        if (state.activeSessionId !== null) {
          try {
            bridgeClient.send({
              type: 'reject',
              id: msg.id,
              message: msg.message,
              sessionId: state.activeSessionId,
            });
            registry.postToState(state, {
              type: 'approval-resolved',
              sessionId: state.activeSessionId,
              id: msg.id,
            });
          } catch (err) {
            registry.postToState(state, {
              type: 'error',
              message: err instanceof Error ? err.message : String(err),
            });
          }
        }
        break;
      }

      case 'answer': {
        try {
          bridgeClient.send({
            type: 'answer',
            toolUseId: msg.toolUseId,
            result: msg.result,
            sessionId: state.activeSessionId ?? undefined,
          });
        } catch (err) {
          registry.postToState(state, {
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'open-file': {
        void openFileInEditor({ path: msg.path, line: msg.line });
        break;
      }

      case 'reconnect': {
        bridgeClient.disconnect();
        bridgeClient.connect();
        break;
      }

      case 'pick-workspace-file': {
        void pickWorkspaceFile(state);
        break;
      }

      case 'pick-open-editor': {
        void pickOpenEditor(state);
        break;
      }

      case 'pick-system-file': {
        void pickSystemFile(state);
        break;
      }

      case 'add-active-selection': {
        addActiveSelection(state);
        break;
      }

      case 'remove-attachment': {
        // Webview owns the chip list; nothing to track server-side for now.
        log(`[picker] remove-attachment ${msg.path}`);
        break;
      }
    }
  }

  // ---- File picker implementations ---------------------------------------

  function postFileAttached(state: PanelState, attachment: AttachmentRef): void {
    registry.postToState(state, { type: 'file-attached', attachment });
  }

  async function pickWorkspaceFile(state: PanelState): Promise<void> {
    const folders = vscode.workspace.workspaceFolders ?? [];
    if (folders.length === 0) {
      registry.postToState(state, { type: 'error', message: 'No workspace folder is open.' });
      return;
    }
    let uris: vscode.Uri[];
    try {
      uris = await vscode.workspace.findFiles('**/*', '**/node_modules/**', 500);
    } catch (err) {
      registry.postToState(state, {
        type: 'error',
        message: err instanceof Error ? err.message : String(err),
      });
      return;
    }
    if (uris.length === 0) {
      registry.postToState(state, { type: 'error', message: 'No files found in workspace.' });
      return;
    }
    const items: Array<vscode.QuickPickItem & { fsPath: string }> = uris.map((u) => ({
      label: vscode.workspace.asRelativePath(u, false),
      description: '',
      detail: '',
      fsPath: u.fsPath,
    }));
    const picked = await vscode.window.showQuickPick(items, {
      placeHolder: 'Select a workspace file to attach',
      matchOnDescription: false,
      matchOnDetail: false,
    });
    if (!picked) return;
    log(`[picker] pick-workspace-file → ${picked.fsPath}`);
    postFileAttached(state, { path: picked.fsPath });
  }

  async function pickOpenEditor(state: PanelState): Promise<void> {
    const tabs = vscode.window.tabGroups.all.flatMap((g) => g.tabs);
    const items: Array<vscode.QuickPickItem & { fsPath: string }> = [];
    const seen = new Set<string>();
    for (const tab of tabs) {
      const input: unknown = tab.input;
      if (
        input &&
        typeof input === 'object' &&
        'uri' in input &&
        (input as { uri?: unknown }).uri instanceof vscode.Uri
      ) {
        const uri = (input as { uri: vscode.Uri }).uri;
        if (uri.scheme !== 'file') continue;
        const fsPath = uri.fsPath;
        if (seen.has(fsPath)) continue;
        seen.add(fsPath);
        items.push({
          label: path.basename(fsPath),
          description: vscode.workspace.asRelativePath(uri, false),
          detail: '',
          fsPath,
        });
      }
    }
    if (items.length === 0) {
      registry.postToState(state, { type: 'error', message: 'No open editors with files.' });
      return;
    }
    const picked = await vscode.window.showQuickPick(items, {
      placeHolder: 'Select an open editor to attach',
      matchOnDescription: false,
      matchOnDetail: false,
    });
    if (!picked) return;
    log(`[picker] pick-open-editor → ${picked.fsPath}`);
    postFileAttached(state, { path: picked.fsPath });
  }

  async function pickSystemFile(state: PanelState): Promise<void> {
    const uris = await vscode.window.showOpenDialog({
      canSelectMany: true,
      canSelectFiles: true,
      canSelectFolders: false,
    });
    if (!uris || uris.length === 0) return;
    for (const uri of uris) {
      log(`[picker] pick-system-file → ${uri.fsPath}`);
      postFileAttached(state, { path: uri.fsPath });
    }
  }

  function addActiveSelection(state: PanelState): void {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      registry.postToState(state, { type: 'error', message: 'No active editor.' });
      return;
    }
    const fsPath = editor.document.uri.fsPath;
    const sel = editor.selection;
    if (sel && !sel.isEmpty) {
      // VSCode positions are 0-based; the protocol uses 1-based line numbers.
      // For a selection that ends at the very start of a line, treat the
      // previous line as the last "real" line of the selection.
      const startLine = sel.start.line + 1;
      const rawEndLine = sel.end.line + 1;
      const endLine =
        sel.end.character === 0 && rawEndLine > startLine ? rawEndLine - 1 : rawEndLine;
      const base = path.basename(fsPath);
      const label = `${base}:${startLine}-${endLine}`;
      log(`[picker] add-active-selection → ${fsPath}:${startLine}-${endLine}`);
      postFileAttached(state, { path: fsPath, startLine, endLine, label });
      return;
    }
    log(`[picker] add-active-selection → ${fsPath} (whole file)`);
    postFileAttached(state, { path: fsPath });
  }

  // ---- Bridge message router (decides which panel(s) receive) -------------
  function handleBridgeMessage(message: BridgeMessage): void {
    switch (message.type) {
      case 'session_created': {
        const sid = (message as Extract<BridgeMessage, { type: 'session_created' }>).sessionId;
        if (typeof sid !== 'string') break;
        const panelId = pendingStartQueue.shift();
        if (!panelId) break;
        const state = registry.get(panelId);
        if (!state) break;
        state.activeSessionId = sid;
        state.activeStatus = 'idle';
        registry.postToState(state, {
          type: 'session-active',
          sessionId: sid,
          projectPath: state.activeProjectPath,
          status: state.activeStatus,
        });
        break;
      }

      case 'status': {
        const m = message as Extract<BridgeMessage, { type: 'status' }>;
        const targets = registry.findBySession(m.sessionId);
        targets.forEach((s) => {
          s.activeStatus = m.status;
          registry.postToState(s, {
            type: 'session-active',
            sessionId: s.activeSessionId,
            projectPath: s.activeProjectPath,
            status: s.activeStatus,
          });
        });
        break;
      }

      case 'assistant': {
        const m = message as Extract<BridgeMessage, { type: 'assistant' }>;
        const text = bridgeContentToText(m.text ?? m.content);
        if (!text) break;
        const id =
          typeof (m as { id?: unknown }).id === 'string'
            ? ((m as { id?: string }).id as string)
            : `${m.sessionId}-${Date.now()}`;
        const chat: ChatMessage = { id, role: 'assistant', text };
        registry.findBySession(m.sessionId).forEach((s) =>
          registry.postToState(s, { type: 'chat-append', message: chat }),
        );
        break;
      }

      case 'stream_delta': {
        const m = message as Extract<BridgeMessage, { type: 'stream_delta' }>;
        registry.findBySession(m.sessionId).forEach((s) =>
          registry.postToState(s, {
            type: 'stream-delta',
            messageId: m.sessionId,
            delta: m.delta,
          }),
        );
        break;
      }

      case 'permission_request': {
        const m = message as Extract<BridgeMessage, { type: 'permission_request' }>;
        const approval: PendingApproval = {
          sessionId: m.sessionId,
          id: m.id,
          tool: m.tool,
          input: m.input,
        };
        registry.findBySession(m.sessionId).forEach((s) =>
          registry.postToState(s, { type: 'approval-request', approval }),
        );
        break;
      }

      case 'error': {
        const m = message as Extract<BridgeMessage, { type: 'error' }>;
        if (typeof m.sessionId === 'string') {
          const targets = registry.findBySession(m.sessionId);
          if (targets.length > 0) {
            targets.forEach((s) => registry.postToState(s, { type: 'error', message: m.message }));
            break;
          }
        }
        registry.broadcast({ type: 'error', message: m.message });
        break;
      }

      case 'result': {
        const m = message as Extract<BridgeMessage, { type: 'result' }>;
        registry.findBySession(m.sessionId).forEach((s) =>
          registry.postToState(s, {
            type: 'result',
            sessionId: m.sessionId,
            cost: m.cost,
            duration: m.duration,
          }),
        );
        break;
      }

      case 'history': {
        const m = message as Extract<BridgeMessage, { type: 'history' }>;
        // Find any panel that asked to switch to this session.
        registry.forEach((s) => {
          if (s.pendingSwitches.has(m.sessionId)) {
            s.pendingSwitches.delete(m.sessionId);
            s.activeSessionId = m.sessionId;
            s.activeStatus = 'idle';
            const chats: ChatMessage[] = [];
            m.messages.forEach((item, idx) => {
              const c = historyItemToChat(item, m.sessionId, idx);
              if (c) chats.push(c);
            });
            registry.postToState(s, { type: 'chat-replace', messages: chats });
            registry.postToState(s, {
              type: 'session-active',
              sessionId: s.activeSessionId,
              projectPath: s.activeProjectPath,
              status: s.activeStatus,
            });
          }
        });
        break;
      }

      case 'session_list': {
        const m = message as Extract<BridgeMessage, { type: 'session_list' }>;
        lastSessions = m.sessions;
        maybeEmitSessionList();
        break;
      }

      case 'recent_sessions': {
        const m = message as Extract<BridgeMessage, { type: 'recent_sessions' }>;
        lastRecent = m.sessions;
        maybeEmitSessionList();
        break;
      }

      case 'project_history': {
        const m = message as Extract<BridgeMessage, { type: 'project_history' }>;
        lastProjects = m.projects;
        maybeEmitSessionList();
        break;
      }

      default:
        break;
    }
  }

  function maybeEmitSessionList(): void {
    if (lastSessions === undefined || lastRecent === undefined || lastProjects === undefined) {
      return;
    }
    const out: Extract<ExtensionToWebview, { type: 'session-list' }> = {
      type: 'session-list',
      sessions: lastSessions,
      recent: lastRecent,
      projects: lastProjects,
    };
    lastSessionListEvent = out;
    registry.broadcast(out);
  }
}

export function deactivate(): void {
  // BridgeClient is disposed via context.subscriptions.
}
