# claude-shim

A fake `claude` CLI that the Anthropic Claude Code VSCode extension can be
pointed at via `claudeCode.claudeProcessWrapper`. The shim translates between
the extension's stream-json protocol (stdin/stdout) and the CC Pocket Bridge's
WebSocket protocol so sessions actually run on the remote machine while you
keep Anthropic's official VSCode UI.

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

Working MVP — chat round-trips end-to-end through the extension UI.
Streaming, tool approvals (auto-approve), `auth status` interception,
remote project-path override, and an on-the-fly bypass switch all in
place. See [Known limitations](#known-limitations) for the rough edges.

## Install

```bash
cd apps/shim-cli
go build -o claude-shim ./cmd/claude-shim
mkdir -p ~/bin && cp claude-shim ~/bin/claude-shim
```

The binary has no third-party dependencies (the WebSocket client is a
stdlib-only RFC 6455 implementation under `internal/wsclient/`), so the build
is fully reproducible offline.

Cross-compile for darwin-arm64 from any host:

```bash
GOOS=darwin GOARCH=arm64 go build -o claude-shim-darwin-arm64 ./cmd/claude-shim
```

## Wire it into VSCode

Open the user `settings.json` (`Cmd+Shift+P` → "Preferences: Open User
Settings (JSON)") and add:

```json
{
  "claudeCode.claudeProcessWrapper": "/Users/you/bin/claude-shim",
  "claudeCode.environmentVariables": [
    { "name": "CCPOCKET_BRIDGE_URL", "value": "ws://<bridge-host>:8765" },
    { "name": "CCPOCKET_PROJECT_PATH_OVERRIDE", "value": "<bridge-side path>" },
    { "name": "CCPOCKET_SHIM_LOG", "value": "info" }
  ],
  "claudeCode.disableLoginPrompt": true
}
```

Reload the window. The next time the extension starts a session, it will
spawn `claude-shim` instead of the real `claude` CLI, and the session will
materialize inside the CC Pocket Bridge.

### Why `CCPOCKET_PROJECT_PATH_OVERRIDE`

VSCode passes the local workspace path via `--add-dir`. When the Bridge runs
on a different machine (typical case: Bridge on a Windows desktop, editor on
a Mac), the local path won't be in the Bridge's `BRIDGE_ALLOWED_DIRS` and
every session is rejected with `"Project path not allowed"`. The override
makes the shim ignore `--add-dir` and send a fixed Bridge-side path instead
(e.g. `C:\Users\rikut\Desktop\claude-personal`). Files are read/written on
the **Bridge host**, not on the editor host.

## Quick on/off toggle

You don't have to edit `settings.json` every time you want to switch back to
the real Anthropic `claude` binary. Two equivalent triggers — whichever is
set wins:

| Trigger                                         | Where to set                                  | Needs reload? |
| ----------------------------------------------- | --------------------------------------------- | ------------- |
| `CCPOCKET_SHIM_DISABLE=1`                       | `claudeCode.environmentVariables` in settings | yes           |
| `~/.ccpocket-shim-disabled` exists              | `touch` / `rm` from a terminal                | **no**        |

The sentinel file is checked at every shim spawn, so:

```bash
# bypass shim → use the real claude binary (Anthropic API)
touch ~/.ccpocket-shim-disabled

# back to shim mode → route through CC Pocket Bridge
rm ~/.ccpocket-shim-disabled
```

In-flight conversations keep using whatever mode they started in; the next
"+ New Chat" picks up the new state.

Optional shell aliases:

```bash
alias bridge-off='touch ~/.ccpocket-shim-disabled && echo "shim OFF (real claude)"'
alias bridge-on='rm -f ~/.ccpocket-shim-disabled && echo "shim ON (Bridge route)"'
```

## Environment variables

| Variable                          | Default                | Purpose                                                                                                  |
| --------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------- |
| `CCPOCKET_BRIDGE_URL`             | `ws://localhost:8765`  | Bridge WebSocket endpoint.                                                                               |
| `CCPOCKET_BRIDGE_TOKEN`           | _(unset)_              | Optional auth token; appended as `?token=…` when set.                                                    |
| `CCPOCKET_PROJECT_PATH_OVERRIDE`  | _(unset)_              | Replace `--add-dir` with this fixed path. Required when the Bridge runs on a different host or OS.       |
| `CCPOCKET_SHIM_LOG`               | `info`                 | Log level: `debug`, `info`, `warn`, `error`. All output goes to **stderr**.                              |
| `CCPOCKET_SHIM_DISABLE`           | _(unset)_              | Set to `1` to bypass the shim and exec the real claude binary directly. See [Quick on/off toggle](#quick-onoff-toggle). |

Logs go to **stderr** exclusively — stdout is reserved for the stream-json
protocol the extension parses. The extension also forwards stderr to its
output channel as `[info] From claude: …`, so you can grep there during
debugging.

## What the shim recognizes

The extension passes many flags; the shim acts on only this minimal subset:

- `--session-id <id>` — session identifier advertised on stdout.
- `--resume <id>` — treated as "continue most recent session" (sets Bridge
  `continue: true`; the foreign id is NOT forwarded — see fix history).
- `--continue` — forwarded as `continue: true` on Bridge `start`.
- `--permission-mode <mode>` — forwarded verbatim.
- `--add-dir <path>` — first occurrence becomes the Bridge `projectPath`,
  unless overridden by `CCPOCKET_PROJECT_PATH_OVERRIDE`.
- `--model <name>` — forwarded on `start`.

All other flags (e.g. `--mcp-config`, `--max-turns`, `--allowedTools`) are
logged at WARN and ignored.

### One-shot subcommands

The extension occasionally spawns the shim with positional subcommands that
expect a single JSON document on stdout (not the streaming protocol). The
shim intercepts these and short-circuits without dialing the Bridge:

- `claude auth status [--json]` — returns a stub `loggedIn: true` payload so
  the extension's auth gate passes.

## Lifecycle (per spawn)

1. Parse args. If bypass switch is set → `exec` the real claude binary.
2. If a one-shot subcommand matches → write its stub JSON and exit.
3. Otherwise, open a WebSocket to `CCPOCKET_BRIDGE_URL`.
4. Read stdin envelopes:
   - `control_request {subtype:"initialize"}` → immediately reply with
     `control_response success` (the extension's 60 s init timeout depends
     on this).
   - Other `control_request` subtypes → reply with `success` and an empty
     response payload.
   - `user` → on the first one, send Bridge `start`; buffer the prompt and
     flush it after `session_created` arrives.
5. Translate Bridge events to stream-json envelopes on stdout:

   | Bridge                | stdout                                                                                                |
   | --------------------- | ----------------------------------------------------------------------------------------------------- |
   | `session_created`     | session id updated (no stdout emit; flushes buffered first input)                                     |
   | `stream_delta`        | `stream_event` SSE sequence: `message_start` → `content_block_start` → `content_block_delta`(s)       |
   | `assistant`           | Closes the SSE sequence (`content_block_stop` → `message_delta` → `message_stop`), then emits the canonical `assistant` envelope |
   | `tool_result`         | `user` envelope with `tool_result` content                                                            |
   | `permission_request`  | Auto-`approve` back to Bridge (MVP); logged                                                            |
   | `result/success`      | `result/success` with full `usage` shape → exit 0                                                     |
   | `result/error`, `error` | `result/error` → exit 1                                                                             |

6. SIGINT / SIGTERM → close socket → emit `result/error "interrupted"` → exit.

## Known limitations

- **Permission prompts are auto-approved.** A future phase should surface the
  Bridge `permission_request` as a `tool_use` to the extension and pipe the
  extension's tool result back as `approve` / `reject`.
- **MCP config is ignored** (`--mcp-config`).
- **Files live on the Bridge host.** With `CCPOCKET_PROJECT_PATH_OVERRIDE`,
  Claude reads/writes the override path's filesystem — not the local
  workspace. If you want Claude to operate on local files, run the Bridge on
  the same machine you edit on.
- **No reconnect.** If the WebSocket drops mid-session the shim emits a
  terminal error and exits; the extension spawns a fresh process for the
  next turn.
- **No images.** The extension's image attachments and base64 paste aren't
  forwarded to Bridge yet.
- **`--resume <id>` doesn't truly resume.** The extension's session id lives
  in its own namespace; the shim translates this to `continue: true` and the
  Bridge picks the most recent session for that project. A persistent id
  mapping is a phase-2 todo.
- **No subprotocols / compression.** The bundled WebSocket client implements
  the minimum needed for Bridge.

## Smoke test

```bash
./scripts/smoke.sh           # builds the shim and pipes a hello message in
```

(requires a running Bridge at `CCPOCKET_BRIDGE_URL`; defaults to
`ws://localhost:8765`)

## Debugging

When something looks wrong, the fastest path is the extension's output
channel (`Output` panel → select **Claude Code** in the dropdown). Every
`[info] From claude: …` line is the shim's stderr — set
`CCPOCKET_SHIM_LOG=debug` in `claudeCode.environmentVariables` and you get
a full trace of every envelope flowing in both directions.

Common log lines and what they mean:

| Log line                                              | Meaning                                                |
| ----------------------------------------------------- | ------------------------------------------------------ |
| `bridge: connected`                                   | WebSocket handshake to the Bridge succeeded.           |
| `bridge: session id <local> -> <bridge>`              | Bridge assigned its canonical sessionId on start.      |
| `bridge: flushing buffered first input`               | First user prompt is being sent post-`session_created`. |
| `stdin: control_request request_id=… subtype=initialize` | Extension is doing its init handshake.              |
| `stdin loop: context canceled`                        | Extension closed our stdin (normal at end of turn).    |
| `bridge error: <msg> (<code>)`                        | Bridge returned a terminal error.                      |
| `shim bypass active — exec <path>`                    | Bypass switch tripped; falling back to real claude.    |
