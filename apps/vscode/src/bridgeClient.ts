// Typed WebSocket client for the CC Pocket Bridge.
//
// Wraps Node 22's native global `WebSocket` and exposes a `vscode.EventEmitter`
// based API for the extension host. The client manages connection lifecycle,
// exponential-backoff reconnect, JSON parsing, and option updates.
//
// Server side: see packages/bridge/src/websocket.ts. The protocol uses a single
// WebSocket endpoint at the root path; an optional `?token=<key>` query
// authenticates clients when `BRIDGE_API_KEY` is set on the server.

import * as vscode from 'vscode';
import type { BridgeMessage, BridgeRequest } from './messages.js';

/** Public state of the client. */
export type BridgeClientState = 'idle' | 'connecting' | 'connected' | 'disconnected';

/** Events emitted by {@link BridgeClient.onEvent}. */
export type BridgeClientEvent =
  | { type: 'state'; state: 'connecting' | 'connected' | 'disconnected'; reason?: string }
  | { type: 'message'; message: BridgeMessage }
  | { type: 'error'; error: Error };

/** Construction-time options for {@link BridgeClient}. */
export interface BridgeClientOptions {
  /** WebSocket URL, e.g. `ws://localhost:8765`. The token, if any, is appended as `?token=`. */
  url: string;
  /** Optional API key matching the server's `BRIDGE_API_KEY`. */
  token?: string | null;
  /** Optional debug logger (e.g. `console.log` or a `vscode.OutputChannel.appendLine`). */
  log?: (msg: string) => void;
}

const INITIAL_RECONNECT_DELAY_MS = 1_000;
const MAX_RECONNECT_DELAY_MS = 30_000;
const MAX_RECONNECT_ATTEMPTS = 10;

/** Narrow an untrusted JSON payload to a {@link BridgeMessage}. */
function asBridgeMessage(raw: unknown): BridgeMessage | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const t = (raw as { type?: unknown }).type;
  if (typeof t !== 'string') return null;
  return raw as BridgeMessage;
}

/**
 * Stringify message data into UTF-8 text without assuming a particular wire
 * representation. Node's WebSocket may deliver text frames as `string` and
 * binary frames as `ArrayBuffer` / `Blob`; we coerce binary to UTF-8.
 */
async function toText(data: unknown): Promise<string> {
  if (typeof data === 'string') return data;
  if (data instanceof ArrayBuffer) return new TextDecoder('utf-8').decode(data);
  if (ArrayBuffer.isView(data)) {
    const view = data as ArrayBufferView;
    return new TextDecoder('utf-8').decode(
      view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength) as ArrayBuffer,
    );
  }
  // Blob is available in Node 22's web globals.
  if (
    typeof Blob !== 'undefined' &&
    data instanceof Blob
  ) {
    return await data.text();
  }
  // Last resort: coerce via String(). Should not happen for spec-compliant frames.
  return String(data);
}

/** Build the final WebSocket URL, appending `?token=` when one is provided. */
function buildUrl(url: string, token?: string | null): string {
  if (!token) return url;
  // Preserve any pre-existing query string.
  const separator = url.includes('?') ? '&' : '?';
  return `${url}${separator}token=${encodeURIComponent(token)}`;
}

/**
 * Manages a single WebSocket connection to the CC Pocket Bridge.
 *
 * Lifecycle: callers invoke {@link connect} to start; the client emits
 * `state` events as the socket transitions. {@link send} requires a connected
 * state. {@link dispose} permanently shuts the client down.
 */
export class BridgeClient implements vscode.Disposable {
  private opts: BridgeClientOptions;
  private socket: WebSocket | null = null;
  /** Public state. Mirrors the most recent emitted `state` event. */
  private _state: BridgeClientState = 'idle';
  /** True after {@link connect} until {@link disconnect} or {@link dispose}. */
  private wantConnected = false;
  /** Consecutive failed connection attempts. Resets on successful open. */
  private reconnectAttempts = 0;
  /** Pending reconnect timer. */
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  /** True once `dispose()` has been called; blocks any further activity. */
  private disposed = false;

  private readonly emitter = new vscode.EventEmitter<BridgeClientEvent>();
  /** Subscribe to client events. */
  public readonly onEvent: vscode.Event<BridgeClientEvent> = this.emitter.event;

  constructor(opts: BridgeClientOptions) {
    this.opts = { ...opts };
  }

  /** Current connection state. */
  get state(): BridgeClientState {
    return this._state;
  }

  /**
   * Open a connection, or no-op if already connecting/connected. Resets the
   * reconnect-attempt counter so a previously "gave up" client can retry.
   */
  connect(): void {
    if (this.disposed) return;
    this.wantConnected = true;
    this.reconnectAttempts = 0;
    if (this._state === 'connecting' || this._state === 'connected') return;
    this.openSocket();
  }

  /** Gracefully close the connection and cancel any pending reconnect. */
  disconnect(): void {
    this.wantConnected = false;
    this.clearReconnectTimer();
    this.closeSocket('client disconnect');
    // Don't emit an extra 'disconnected' here — the socket's `close` handler
    // (or the synchronous `setState` below if no socket existed) takes care of it.
    if (this._state !== 'disconnected' && this._state !== 'idle') {
      this.setState('disconnected', 'client disconnect');
    }
  }

  /**
   * Send a typed request to the bridge. Throws if the socket is not connected;
   * callers should gate sends on the most recent `state` event.
   */
  send(req: BridgeRequest): void {
    if (this.disposed) throw new Error('BridgeClient: disposed');
    if (this._state !== 'connected' || !this.socket) {
      throw new Error('BridgeClient: not connected');
    }
    const payload = JSON.stringify(req);
    this.socket.send(payload);
  }

  /**
   * Replace any subset of options. If `url` or `token` changes while the
   * client is connecting/connected, the socket is torn down and reopened with
   * the new parameters; other options take effect on the next send/log.
   */
  updateOptions(opts: Partial<BridgeClientOptions>): void {
    if (this.disposed) return;
    const next: BridgeClientOptions = { ...this.opts, ...opts };
    const urlChanged = next.url !== this.opts.url;
    const tokenChanged = (next.token ?? null) !== (this.opts.token ?? null);
    this.opts = next;
    if (!urlChanged && !tokenChanged) return;

    if (this._state === 'connecting' || this._state === 'connected') {
      this.log(`updateOptions: url/token changed, reconnecting`);
      this.clearReconnectTimer();
      this.closeSocket('options changed');
      // Re-arm: keep wantConnected as-is and open immediately with new params.
      this.reconnectAttempts = 0;
      // Defer to next microtask so the close event flushes first.
      queueMicrotask(() => {
        if (this.disposed || !this.wantConnected) return;
        this.openSocket();
      });
    }
  }

  /** Tear down the client. After this, all methods are no-ops or throw. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.wantConnected = false;
    this.clearReconnectTimer();
    this.closeSocket('disposed');
    this.emitter.dispose();
  }

  // ===== Internals ==========================================================

  private log(msg: string): void {
    this.opts.log?.(`[BridgeClient] ${msg}`);
  }

  private setState(
    state: 'connecting' | 'connected' | 'disconnected',
    reason?: string,
  ): void {
    this._state = state;
    const event: BridgeClientEvent =
      reason !== undefined
        ? { type: 'state', state, reason }
        : { type: 'state', state };
    this.emitter.fire(event);
  }

  private openSocket(): void {
    if (this.disposed) return;
    const url = buildUrl(this.opts.url, this.opts.token ?? null);
    this.log(`connecting to ${this.opts.url}`);
    this.setState('connecting');

    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      this.log(`construction failed: ${error.message}`);
      this.emitter.fire({ type: 'error', error });
      this.handleClosed(error.message);
      return;
    }
    this.socket = ws;

    ws.addEventListener('open', () => {
      if (this.socket !== ws) return;
      this.log('open');
      this.reconnectAttempts = 0;
      this.setState('connected');
    });

    ws.addEventListener('message', (ev) => {
      if (this.socket !== ws) return;
      const data = (ev as { data: unknown }).data;
      void this.handleIncoming(data);
    });

    ws.addEventListener('error', () => {
      if (this.socket !== ws) return;
      // Native WebSocket `error` events do not carry message detail; create a
      // generic Error so downstream consumers can log/inspect it.
      const error = new Error('BridgeClient: WebSocket error');
      this.log('error event');
      this.emitter.fire({ type: 'error', error });
    });

    ws.addEventListener('close', (ev) => {
      if (this.socket !== ws) return;
      const code = (ev as { code?: number }).code;
      const rawReason = (ev as { reason?: string }).reason;
      const reason = rawReason && rawReason.length > 0
        ? rawReason
        : typeof code === 'number'
          ? `code ${code}`
          : 'closed';
      this.log(`closed: ${reason}`);
      this.socket = null;
      this.handleClosed(reason);
    });
  }

  private async handleIncoming(data: unknown): Promise<void> {
    let text: string;
    try {
      text = await toText(data);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      this.emitter.fire({ type: 'error', error });
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      this.log(`invalid JSON: ${error.message}`);
      this.emitter.fire({ type: 'error', error });
      return;
    }
    const message = asBridgeMessage(parsed);
    if (!message) {
      this.emitter.fire({
        type: 'error',
        error: new Error('BridgeClient: message missing string `type` field'),
      });
      return;
    }
    this.emitter.fire({ type: 'message', message });
  }

  private handleClosed(reason: string): void {
    if (this.disposed) return;
    this.setState('disconnected', reason);

    if (!this.wantConnected) return;

    this.reconnectAttempts += 1;
    if (this.reconnectAttempts > MAX_RECONNECT_ATTEMPTS) {
      this.log(`gave up after ${MAX_RECONNECT_ATTEMPTS} attempts`);
      this.setState('disconnected', `gave up after ${MAX_RECONNECT_ATTEMPTS} attempts`);
      this.wantConnected = false;
      return;
    }

    const delay = Math.min(
      MAX_RECONNECT_DELAY_MS,
      INITIAL_RECONNECT_DELAY_MS * 2 ** (this.reconnectAttempts - 1),
    );
    this.log(`scheduling reconnect #${this.reconnectAttempts} in ${delay}ms`);
    this.scheduleReconnect(delay);
  }

  private scheduleReconnect(delay: number): void {
    this.clearReconnectTimer();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.disposed || !this.wantConnected) return;
      this.openSocket();
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private closeSocket(reason: string): void {
    const ws = this.socket;
    if (!ws) return;
    this.socket = null;
    try {
      // 1000 = normal closure.
      ws.close(1000, reason);
    } catch {
      // Ignore — already closed or closing.
    }
  }
}
