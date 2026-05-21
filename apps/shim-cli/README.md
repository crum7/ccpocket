# claude-shim

A fake `claude` CLI that the Anthropic Claude Code VSCode extension can be
pointed at via `claudeCode.claudeProcessWrapper`. The shim translates between
the extension's stream-json protocol (stdin/stdout) and the CC Pocket Bridge's
WebSocket protocol so sessions actually run on the remote Mac while you keep
Anthropic's official VSCode UI.

```
  +-----------------+      stream-json (stdin/stdout)      +--------------+
  |  Anthropic      |  <-------------------------------->  |  claude-shim |
  |  Claude Code    |                                       |  (this bin)  |
  |  VSCode ext.    |                                       +------+-------+
  +-----------------+                                              |
                                                                   |  WebSocket
                                                                   v
                                                            +-------------+
                                                            | CC Pocket   |
                                                            | Bridge      |
                                                            +-------------+
```

## Status

MVP. Forwards text in both directions, auto-approves permission requests,
maps Bridge `result` / `error` to terminal SDK envelopes. See
[Known limitations](#known-limitations).

## Install

### From source (recommended for now)

```bash
cd apps/shim-cli
go build -o claude-shim ./cmd/claude-shim
# Drop the binary somewhere on PATH or reference it by absolute path:
cp claude-shim ~/bin/claude-shim
```

Or, once the module is published as a Go module:

```bash
go install github.com/K9i-0/ccpocket/apps/shim-cli/cmd/claude-shim@latest
```

The binary has no third-party dependencies (the WebSocket client is a
stdlib-only implementation under `internal/wsclient/`), so the build is
fully reproducible offline.

### Cross-compile for darwin-arm64

```bash
GOOS=darwin GOARCH=arm64 go build -o claude-shim-darwin-arm64 ./cmd/claude-shim
```

## Wire it into VSCode

Open the user `settings.json` (Cmd-Shift-P → "Preferences: Open User
Settings (JSON)") and add:

```json
{
  "claudeCode.claudeProcessWrapper": "/Users/you/bin/claude-shim"
}
```

Reload the window. The next time the extension starts a session, it will
spawn `claude-shim` instead of the real `claude` CLI, and the session will
materialize inside the CC Pocket Bridge running on your Mac.

## Environment variables

| Variable                 | Default                | Purpose                                                                |
| ------------------------ | ---------------------- | ---------------------------------------------------------------------- |
| `CCPOCKET_BRIDGE_URL`    | `ws://localhost:8765`  | Bridge WebSocket endpoint.                                             |
| `CCPOCKET_BRIDGE_TOKEN`  | _(unset)_              | Optional auth token; appended as `?token=…` when set.                  |
| `CCPOCKET_SHIM_LOG`      | `info`                 | Log level: `debug`, `info`, `warn`, `error`. All output goes to stderr. |

Logs are written exclusively to **stderr** — stdout is reserved for the
stream-json protocol the extension parses.

To set env vars for the VSCode-spawned process, use the
`claudeCode.environmentVariables` setting (if the extension supports it) or
launch VSCode from a shell where they're exported.

## What the shim recognizes

The extension passes many flags; the shim acts on only this minimal subset:

- `--session-id <id>` — session identifier advertised on stdout.
- `--resume <id>` — resumed Bridge session id.
- `--continue` — forwarded as `continue: true` on Bridge `start`.
- `--permission-mode <mode>` — forwarded verbatim.
- `--add-dir <path>` — first occurrence becomes the Bridge `projectPath`.
- `--model <name>` — forwarded on `start`.

All other flags (e.g. `--mcp-config`, `--max-turns`, `--allowedTools`) are
logged at WARN and ignored.

## Lifecycle

1. Shim starts → emits `{type:"system", subtype:"init", …}` on stdout.
2. Opens WebSocket to `CCPOCKET_BRIDGE_URL`.
3. Reads stdin envelopes; on the **first** `type:"user"` envelope, sends
   Bridge `start` with the resolved `projectPath` + `permissionMode`.
4. Subsequent user text becomes Bridge `input` messages.
5. Bridge events stream back and are translated:

   | Bridge                  | stdout                                                                     |
   | ----------------------- | -------------------------------------------------------------------------- |
   | `session_created`       | session_id updates (no stdout emit)                                        |
   | `assistant`             | `{type:"assistant", message:{…}}`                                          |
   | `stream_delta`          | `{type:"stream_event", event:{type:"content_block_delta", …}}`             |
   | `tool_result`           | `{type:"user", message:{role:"user", content:[{type:"tool_result", …}]}}` |
   | `permission_request`    | auto-`approve` back to Bridge (MVP); logged                                |
   | `result`                | `{type:"result", subtype:"success", …}` → exit 0                           |
   | `error`                 | `{type:"result", subtype:"error", …}` → exit 1                             |

6. SIGINT / SIGTERM → close socket → emit `result/error: "interrupted"` → exit.

## Known limitations

- **Permission prompts are auto-approved.** A future phase should surface the
  Bridge `permission_request` as a `tool_use` to the extension and forward the
  extension's tool result back as `approve` / `reject`.
- **MCP config is ignored** (`--mcp-config`).
- **Tool use forwarding to extension is one-way.** Bridge runs the tools itself
  (via the real Claude Agent SDK on the host Mac), so the extension sees the
  resulting assistant messages but not individual `tool_use` requests/results
  with full fidelity.
- **No reconnect.** If the WebSocket drops mid-session the shim emits a
  terminal error and exits; the extension will spawn a fresh process for the
  next turn.
- **No images.** The extension's image attachments and base64 paste aren't
  forwarded to Bridge yet.
- **No subprotocols / compression.** The bundled WebSocket client implements
  the minimum needed for Bridge.

## Smoke test

```bash
./scripts/smoke.sh           # builds the shim and pipes a hello message in
```

(requires a running Bridge at `CCPOCKET_BRIDGE_URL`; defaults to localhost:8765)
