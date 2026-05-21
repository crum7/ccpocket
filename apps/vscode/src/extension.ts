import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { BridgeClient, type BridgeClientEvent } from './bridgeClient.js';
import { buildHtml } from './buildHtml.js';
import type {
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

const SIDEBAR_VIEW_ID = 'ccpocket.placeholder';
const VIEWS_CONTAINER_ID = 'ccpocket';

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

/**
 * Sidebar provider. Owns the webview lifecycle but NOT the BridgeClient — the
 * client is created once by `activate()` and persists across view dispose/
 * re-resolve cycles so that a sidebar collapse doesn't drop the connection.
 */
class CCPocketViewProvider implements vscode.WebviewViewProvider {
  /** The current live webview, if the view is visible. `undefined` when hidden. */
  private view: vscode.WebviewView | undefined;

  constructor(
    private readonly extensionUri: vscode.Uri,
    private readonly onWebviewMessage: (msg: WebviewToExtension) => void,
  ) {}

  resolveWebviewView(view: vscode.WebviewView): void {
    this.view = view;
    view.webview.options = {
      enableScripts: true,
      localResourceRoots: [vscode.Uri.joinPath(this.extensionUri, 'media')],
    };
    view.webview.html = buildHtml(view.webview, this.extensionUri);

    view.webview.onDidReceiveMessage((raw: unknown) => {
      if (!raw || typeof raw !== 'object' || !('type' in raw)) return;
      this.onWebviewMessage(raw as WebviewToExtension);
    });

    view.onDidDispose(() => {
      if (this.view === view) {
        this.view = undefined;
      }
    });
  }

  /** True if the view is resolved and (probably) visible. */
  isLive(): boolean {
    return this.view !== undefined;
  }

  post(message: ExtensionToWebview): void {
    void this.view?.webview.postMessage(message);
  }
}

/**
 * Resolve a (possibly relative) path to an absolute filesystem path using the
 * workspace folders, preferring the folder containing the active editor.
 */
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
  // Best-effort fallback so the user gets a clear "not found" error instead
  // of silent dismissal.
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
    // Webview passes 1-based lines; vscode.Position is 0-based.
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

/**
 * Convert a `BridgeSession.firstPrompt` (or arbitrary unknown) to a chat-
 * message text string. The bridge sometimes ships richer payloads we can't
 * fully render here; we fall back to `JSON.stringify` for those.
 */
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

/**
 * Map a `history` message item to a `ChatMessage`. We accept the bridge's
 * loose shape and do a best-effort projection.
 */
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

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel('CC Pocket');
  context.subscriptions.push(output);
  const log = (msg: string): void => {
    output.appendLine(`[${new Date().toISOString()}] ${msg}`);
  };

  // ---- Single BridgeClient instance, owned by activate() ------------------
  const { bridgeUrl, bridgeToken } = readSettings();
  const bridgeClient = new BridgeClient({
    url: bridgeUrl,
    token: tokenOrNull(bridgeToken),
    log,
  });
  context.subscriptions.push(bridgeClient);

  // ---- Active session state machine ---------------------------------------
  let activeSessionId: string | null = null;
  let activeProjectPath: string | null = null;
  let activeStatus: SessionStatus = 'idle';

  // ---- Coalesced session-list snapshot ------------------------------------
  // The bridge emits three separate messages — `session_list`,
  // `recent_sessions`, and `project_history` — and the webview wants them
  // glued into a single `session-list` event. We hold the latest of each,
  // then fire as soon as ALL THREE have been observed once. After that point
  // every subsequent arrival triggers another aggregated emission so the UI
  // stays current.
  let lastSessions: BridgeSession[] | undefined;
  let lastRecent: BridgeSession[] | undefined;
  let lastProjects: string[] | undefined;
  let lastSessionListEvent: Extract<ExtensionToWebview, { type: 'session-list' }> | null = null;

  // ---- Connection state cache so we can re-send to a fresh webview --------
  let lastConnectionState: ConnectionState = { state: 'idle' };

  // ---- Pending get_history requests, keyed by sessionId -------------------
  // When the webview asks to switch sessions we send `get_history` and want
  // to convert the next matching `history` reply into `chat-replace` and
  // then update activeSessionId.
  const pendingSwitches = new Set<string>();

  // ---- Sidebar view --------------------------------------------------------
  const provider = new CCPocketViewProvider(context.extensionUri, handleWebviewMessage);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(SIDEBAR_VIEW_ID, provider, {
      webviewOptions: { retainContextWhenHidden: true },
    }),
  );

  // ---- Command: focus the sidebar -----------------------------------------
  context.subscriptions.push(
    vscode.commands.registerCommand('ccpocket.open', () => {
      void vscode.commands.executeCommand(
        `workbench.view.extension.${VIEWS_CONTAINER_ID}`,
      );
    }),
  );

  // ---- React to setting changes -------------------------------------------
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (!event.affectsConfiguration('ccpocket')) return;
      const next = readSettings();
      bridgeClient.updateOptions({
        url: next.bridgeUrl,
        token: tokenOrNull(next.bridgeToken),
      });
      // Push fresh config to the webview so it can update UI affordances
      // (e.g. "configured token" indicator) without needing a reload.
      provider.post({
        type: 'config',
        bridgeUrl: next.bridgeUrl,
        hasToken: tokenOrNull(next.bridgeToken) !== null,
        allowedDirs: [],
        defaultProjectPath: defaultProjectPath(),
      });
    }),
  );

  // ---- Bridge → webview translation ---------------------------------------
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
          provider.post({ type: 'connection-state', state: next });
          break;
        }
        case 'error': {
          // Treat hard transport errors as a connection-error state surface.
          lastConnectionState = { state: 'error', message: event.error.message };
          provider.post({ type: 'connection-state', state: lastConnectionState });
          provider.post({ type: 'error', message: event.error.message });
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

  // ---- Webview → extension message router ---------------------------------
  function handleWebviewMessage(msg: WebviewToExtension): void {
    switch (msg.type) {
      case 'ready': {
        const { bridgeUrl: u, bridgeToken: t } = readSettings();
        provider.post({
          type: 'config',
          bridgeUrl: u,
          hasToken: tokenOrNull(t) !== null,
          allowedDirs: [],
          defaultProjectPath: defaultProjectPath(),
        });
        provider.post({ type: 'connection-state', state: lastConnectionState });
        if (lastSessionListEvent) provider.post(lastSessionListEvent);
        if (
          bridgeClient.state === 'idle' ||
          bridgeClient.state === 'disconnected'
        ) {
          bridgeClient.connect();
        }
        break;
      }

      case 'user-input': {
        // Optimistic local echo — the webview shows the user message
        // immediately without waiting for a bridge round-trip.
        const echoId =
          (activeSessionId ?? 'pending') + '-user-' + Date.now().toString(36);
        provider.post({
          type: 'chat-append',
          message: { id: echoId, role: 'user', text: msg.text },
        });

        try {
          if (activeSessionId === null && activeProjectPath !== null) {
            const req: BridgeRequest = {
              type: 'start',
              projectPath: activeProjectPath,
              continue: false,
            };
            bridgeClient.send(req);
            // First user prompt is buffered; once `session_created` arrives
            // we will be able to send subsequent `input` events. The bridge
            // currently expects the first prompt to go via `input` after
            // session creation, so we relay the text immediately after start
            // and let the bridge buffer/queue as designed.
            bridgeClient.send({ type: 'input', text: msg.text });
          } else if (activeSessionId !== null) {
            bridgeClient.send({
              type: 'input',
              text: msg.text,
              sessionId: activeSessionId,
            });
          } else {
            provider.post({
              type: 'error',
              message:
                'No active session and no project path is set. Select a project or session first.',
            });
          }
        } catch (err) {
          provider.post({
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'start-session': {
        activeProjectPath = msg.projectPath;
        activeSessionId = null;
        activeStatus = 'idle';
        provider.post({
          type: 'session-active',
          sessionId: null,
          projectPath: activeProjectPath,
          status: activeStatus,
        });
        try {
          bridgeClient.send({
            type: 'start',
            projectPath: msg.projectPath,
            permissionMode: msg.permissionMode,
          });
        } catch (err) {
          provider.post({
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'switch-session': {
        pendingSwitches.add(msg.sessionId);
        try {
          bridgeClient.send({ type: 'get_history', sessionId: msg.sessionId });
        } catch (err) {
          pendingSwitches.delete(msg.sessionId);
          provider.post({
            type: 'error',
            message: err instanceof Error ? err.message : String(err),
          });
        }
        break;
      }

      case 'stop-session': {
        if (activeSessionId !== null) {
          try {
            bridgeClient.send({ type: 'stop_session', sessionId: activeSessionId });
          } catch (err) {
            provider.post({
              type: 'error',
              message: err instanceof Error ? err.message : String(err),
            });
          }
        }
        break;
      }

      case 'approve': {
        if (activeSessionId !== null) {
          try {
            bridgeClient.send({
              type: 'approve',
              id: msg.id,
              sessionId: activeSessionId,
            });
            provider.post({
              type: 'approval-resolved',
              sessionId: activeSessionId,
              id: msg.id,
            });
          } catch (err) {
            provider.post({
              type: 'error',
              message: err instanceof Error ? err.message : String(err),
            });
          }
        }
        break;
      }

      case 'reject': {
        if (activeSessionId !== null) {
          try {
            bridgeClient.send({
              type: 'reject',
              id: msg.id,
              message: msg.message,
              sessionId: activeSessionId,
            });
            provider.post({
              type: 'approval-resolved',
              sessionId: activeSessionId,
              id: msg.id,
            });
          } catch (err) {
            provider.post({
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
            sessionId: activeSessionId ?? undefined,
          });
        } catch (err) {
          provider.post({
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
    }
  }

  // ---- Bridge message router ----------------------------------------------
  function handleBridgeMessage(message: BridgeMessage): void {
    switch (message.type) {
      case 'session_created': {
        const sid = (message as Extract<BridgeMessage, { type: 'session_created' }>).sessionId;
        if (typeof sid === 'string') {
          activeSessionId = sid;
          activeStatus = 'idle';
          provider.post({
            type: 'session-active',
            sessionId: activeSessionId,
            projectPath: activeProjectPath,
            status: activeStatus,
          });
        }
        break;
      }

      case 'status': {
        const m = message as Extract<BridgeMessage, { type: 'status' }>;
        if (m.sessionId === activeSessionId || activeSessionId === null) {
          activeStatus = m.status;
          provider.post({
            type: 'session-active',
            sessionId: activeSessionId,
            projectPath: activeProjectPath,
            status: activeStatus,
          });
        }
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
        provider.post({ type: 'chat-append', message: chat });
        break;
      }

      case 'stream_delta': {
        const m = message as Extract<BridgeMessage, { type: 'stream_delta' }>;
        // The webview is responsible for grouping deltas into the in-progress
        // assistant message; we use sessionId as the implicit messageId so
        // multiple concurrent sessions don't collide.
        provider.post({
          type: 'stream-delta',
          messageId: m.sessionId,
          delta: m.delta,
        });
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
        provider.post({ type: 'approval-request', approval });
        break;
      }

      case 'error': {
        const m = message as Extract<BridgeMessage, { type: 'error' }>;
        provider.post({ type: 'error', message: m.message });
        break;
      }

      case 'result': {
        const m = message as Extract<BridgeMessage, { type: 'result' }>;
        provider.post({
          type: 'result',
          sessionId: m.sessionId,
          cost: m.cost,
          duration: m.duration,
        });
        break;
      }

      case 'history': {
        const m = message as Extract<BridgeMessage, { type: 'history' }>;
        if (pendingSwitches.has(m.sessionId)) {
          pendingSwitches.delete(m.sessionId);
          activeSessionId = m.sessionId;
          // We don't know the project path for a switched-to session unless
          // it appears in the session_list; leave activeProjectPath as-is.
          activeStatus = 'idle';
          const chats: ChatMessage[] = [];
          m.messages.forEach((item, idx) => {
            const c = historyItemToChat(item, m.sessionId, idx);
            if (c) chats.push(c);
          });
          provider.post({ type: 'chat-replace', messages: chats });
          provider.post({
            type: 'session-active',
            sessionId: activeSessionId,
            projectPath: activeProjectPath,
            status: activeStatus,
          });
        }
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
        // System events, tool_result, and anything else: nothing to do here.
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
    provider.post(out);
  }
}

export function deactivate(): void {
  // BridgeClient is disposed via context.subscriptions; nothing extra here.
}
