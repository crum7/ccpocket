// Shared message contracts for the CC Pocket VSCode extension.
//
// Two protocols live here:
//   1. Bridge ←→ extension host   — what the WebSocket carries.
//   2. Webview ←→ extension host  — what postMessage carries.
//
// Bridge protocol mirrors packages/bridge/src/websocket.ts. Only the message
// types we use in the MVP are typed explicitly; uncommon payload fields are
// kept as `unknown` so a stricter Bridge update doesn't break the build.

// ===== Bridge ←→ extension host ============================================

/** Lightweight summary of a session, as the bridge surfaces it. */
export interface BridgeSession {
  sessionId: string;
  projectPath?: string;
  provider?: 'claude' | 'codex' | string;
  firstPrompt?: string;
  lastModified?: string;
  // Bridge sends additional fields; callers should treat unknown keys as opaque.
  [key: string]: unknown;
}

/** Permission modes supported by the bridge when starting a session. */
export type PermissionMode = 'default' | 'plan' | 'acceptEdits' | 'bypassPermissions';

/** Runtime status of a session. */
export type SessionStatus = 'idle' | 'running' | 'waiting_approval';

/** Messages sent FROM the extension TO the bridge. */
export type BridgeRequest =
  | { type: 'start'; projectPath: string; sessionId?: string; continue?: boolean; permissionMode?: PermissionMode }
  | { type: 'input'; text: string; sessionId?: string }
  | { type: 'approve'; id: string; sessionId?: string }
  | { type: 'reject'; id: string; message?: string; sessionId?: string }
  | { type: 'answer'; toolUseId: string; result: string; sessionId?: string }
  | { type: 'list_sessions' }
  | { type: 'list_recent_sessions'; limit?: number; offset?: number }
  | { type: 'list_project_history' }
  | { type: 'stop_session'; sessionId: string }
  | { type: 'get_history'; sessionId: string };

/** Messages received FROM the bridge BY the extension. */
export type BridgeMessage =
  | { type: 'system'; subtype?: string; sessionId?: string; [k: string]: unknown }
  | { type: 'session_list'; sessions: BridgeSession[]; allowedDirs?: string[]; claudeModels?: string[] }
  | { type: 'session_created'; sessionId: string; [k: string]: unknown }
  | { type: 'project_history'; projects: string[] }
  | { type: 'recent_sessions'; sessions: BridgeSession[] }
  | { type: 'assistant'; sessionId: string; text?: string; content?: unknown[]; [k: string]: unknown }
  | { type: 'tool_result'; sessionId: string; toolUseId: string; content?: unknown; [k: string]: unknown }
  | { type: 'result'; sessionId: string; cost?: number; duration?: number; [k: string]: unknown }
  | { type: 'error'; sessionId?: string; message: string; errorCode?: string; [k: string]: unknown }
  | { type: 'status'; sessionId: string; status: SessionStatus }
  | { type: 'history'; sessionId: string; messages: unknown[] }
  | { type: 'permission_request'; sessionId: string; id: string; tool: string; input: unknown }
  | { type: 'stream_delta'; sessionId: string; delta: string }
  | { type: string; [k: string]: unknown };

// ===== Webview ←→ extension host ===========================================

export type ConnectionState =
  | { state: 'idle' }
  | { state: 'connecting' }
  | { state: 'connected' }
  | { state: 'disconnected'; reason?: string }
  | { state: 'error'; message: string };

/** Logical message shown in the chat history. */
export interface ChatMessage {
  /** Stable id for de-dup / streaming updates. */
  id: string;
  role: 'user' | 'assistant' | 'tool';
  /** Plain text body (markdown allowed). */
  text: string;
  /** Optional tool metadata when role === 'tool'. */
  toolName?: string;
  toolStatus?: 'pending' | 'approved' | 'rejected' | 'completed' | 'failed';
}

/** A pending tool-use the webview should render an Approve/Reject card for. */
export interface PendingApproval {
  sessionId: string;
  id: string;
  tool: string;
  input: unknown;
}

/** Messages from extension host → webview. */
export type ExtensionToWebview =
  | { type: 'config'; bridgeUrl: string; hasToken: boolean; allowedDirs: string[]; defaultProjectPath: string | null }
  | { type: 'connection-state'; state: ConnectionState }
  | { type: 'session-list'; sessions: BridgeSession[]; recent: BridgeSession[]; projects: string[] }
  | { type: 'session-active'; sessionId: string | null; projectPath: string | null; status: SessionStatus }
  | { type: 'chat-append'; message: ChatMessage }
  | { type: 'chat-replace'; messages: ChatMessage[] }
  | { type: 'stream-delta'; messageId: string; delta: string }
  | { type: 'approval-request'; approval: PendingApproval }
  | { type: 'approval-resolved'; sessionId: string; id: string }
  | { type: 'result'; sessionId: string; cost?: number; duration?: number }
  | { type: 'error'; message: string };

/** Messages from webview → extension host. */
export type WebviewToExtension =
  | { type: 'ready' }
  | { type: 'user-input'; text: string }
  | { type: 'start-session'; projectPath: string; permissionMode?: PermissionMode }
  | { type: 'switch-session'; sessionId: string }
  | { type: 'stop-session' }
  | { type: 'approve'; id: string }
  | { type: 'reject'; id: string; message?: string }
  | { type: 'answer'; toolUseId: string; result: string }
  | { type: 'open-file'; path: string; line?: number }
  | { type: 'reconnect' };

// Legacy types kept for back-compat with the Flutter-webview implementation —
// safe to delete once the native UI is the only consumer.
export type HostToWebview = { type: 'bridge-url'; bridgeUrl: string; token: string | null };
export type WebviewToHost =
  | { type: 'get-bridge-url' }
  | { type: 'open-file'; path: string; line?: number };
