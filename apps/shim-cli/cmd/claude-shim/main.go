// claude-shim is a fake `claude` CLI that the Anthropic Claude Code VSCode
// extension can be pointed at via the `claudeCode.claudeProcessWrapper`
// setting. The extension thinks it's spawning the real CLI; under the hood
// the shim relays stream-json envelopes to/from the CC Pocket Bridge over
// WebSocket so sessions actually execute on the remote Mac.
//
// Wire protocol (stdin/stdout): line-delimited JSON, one envelope per line.
// See internal/wire/sdk.go for the typed shapes.
//
// Wire protocol (Bridge): see packages/bridge/src/websocket.ts in the parent
// repo and internal/bridge/bridge.go in this tree.
package main

import (
	"context"
	cryptoRand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/bridge"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/logger"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/sdk"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/sessionstore"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/wire"
)

// atomicBool is a thin wrapper that's safe to copy by value via *.
type atomicBool struct{ v atomic.Bool }

func (a *atomicBool) Store(b bool) { a.v.Store(b) }
func (a *atomicBool) Load() bool   { return a.v.Load() }

// shimArgs captures the subset of CLI flags the shim recognizes.
// All other flags are logged and ignored — the extension passes many flags
// we don't yet act on, but we must not error out on them.
type shimArgs struct {
	SessionID      string
	Resume         string // session id to resume
	Continue       bool
	PermissionMode string
	AddDirs        []string
	Model          string
	Unknown        []string
}

// parseArgs is a hand-rolled flag parser that tolerates the extension's
// long-form syntax (`--flag value` and `--flag=value`). We deliberately don't
// use the stdlib `flag` package because it would error on unknown flags.
func parseArgs(args []string) shimArgs {
	out := shimArgs{}
	i := 0
	consume := func() (string, bool) {
		if i+1 >= len(args) {
			return "", false
		}
		i++
		return args[i], true
	}
	stringFlags := map[string]*string{
		"--session-id":      &out.SessionID,
		"--resume":          &out.Resume,
		"--permission-mode": &out.PermissionMode,
		"--model":           &out.Model,
	}
	for ; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--continue":
			out.Continue = true
		case a == "--add-dir":
			if v, ok := consume(); ok {
				out.AddDirs = append(out.AddDirs, v)
			}
		case strings.HasPrefix(a, "--add-dir="):
			out.AddDirs = append(out.AddDirs, strings.TrimPrefix(a, "--add-dir="))
		default:
			// Long --flag value or --flag=value forms.
			if dst, ok := stringFlags[a]; ok {
				if v, ok := consume(); ok {
					*dst = v
				}
				continue
			}
			matched := false
			for prefix, dst := range stringFlags {
				if strings.HasPrefix(a, prefix+"=") {
					*dst = strings.TrimPrefix(a, prefix+"=")
					matched = true
					break
				}
			}
			if !matched {
				out.Unknown = append(out.Unknown, a)
			}
		}
	}
	return out
}

// envOr returns the env var or a fallback if unset/empty.
func envOr(key, fallback string) string {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	return v
}

// handleOneShotSubcommand intercepts positional subcommands the Claude Code
// VSCode extension occasionally spawns out-of-band (e.g. `claude auth status
// --json`). These spawn invocations expect a single JSON document on stdout
// followed by EOF — falling through to the conversational lifecycle would
// emit a result envelope at exit time, which the extension's `JSON.parse`
// rejects with "Unexpected non-whitespace character after JSON".
//
// Returns true when an out-of-band command was matched and serviced; the
// caller MUST exit immediately afterwards.
func handleOneShotSubcommand(positional []string, log *logger.Logger) bool {
	// Skip leading short/long flags; only look at the bare-word verbs.
	verbs := make([]string, 0, len(positional))
	for _, tok := range positional {
		if strings.HasPrefix(tok, "-") {
			continue
		}
		verbs = append(verbs, tok)
	}
	if len(verbs) < 2 {
		return false
	}

	// The extension prefixes argv with the original `claude` binary path
	// when a claudeProcessWrapper is in effect (so the wrapper can defer
	// to it). Locate the actual subcommand by scanning for the verb pair
	// anywhere in the token stream — not just at index 0.
	hasPair := func(a, b string) bool {
		for i := 0; i+1 < len(verbs); i++ {
			if verbs[i] == a && verbs[i+1] == b {
				return true
			}
		}
		return false
	}

	switch {
	case hasPair("auth", "status"):
		// Pretend we're logged in via a CC Pocket Bridge route. The extension
		// only acts on .loggedIn; the rest is cosmetic.
		stdout := sdk.NewWriter(os.Stdout)
		_ = stdout.Write(map[string]any{
			"loggedIn":         true,
			"authMethod":       "ccpocket-bridge",
			"apiProvider":      "firstParty",
			"email":            "",
			"orgId":            "",
			"orgName":          "",
			"subscriptionType": "",
		})
		log.Debugf("oneshot: served `auth status` stub")
		return true
	}
	return false
}

// shimDisabled reports whether the shim should bypass itself and exec the
// real claude binary. Triggered by either CCPOCKET_SHIM_DISABLE=1 or the
// presence of ~/.ccpocket-shim-disabled.
func shimDisabled() bool {
	if v := os.Getenv("CCPOCKET_SHIM_DISABLE"); v != "" && v != "0" && v != "false" {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	if _, err := os.Stat(filepath.Join(home, ".ccpocket-shim-disabled")); err == nil {
		return true
	}
	return false
}

// findRealClaude scans argv for the original claude binary path that the
// extension prepends when a claudeProcessWrapper is configured. The marker
// we look for: a token that contains `claude-code-` AND ends in `/claude`
// (the typical bundled native-binary layout). Falls back to the first
// non-flag token if no obvious match is found.
func findRealClaude(args []string) string {
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		if strings.Contains(a, "claude-code-") && strings.HasSuffix(a, "/claude") {
			return a
		}
	}
	// Fallback: first non-flag token whose basename is exactly "claude".
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			continue
		}
		if filepath.Base(a) == "claude" {
			return a
		}
	}
	return ""
}

// stripRealClaudePathFromArgs returns args with the first occurrence of the
// real-claude path removed (so we don't pass the binary's own path to it
// again — the OS does that via syscall.Exec's argv[0]).
func stripRealClaudePathFromArgs(args []string, realBin string) []string {
	out := make([]string, 0, len(args))
	removed := false
	for _, a := range args {
		if !removed && a == realBin {
			removed = true
			continue
		}
		out = append(out, a)
	}
	return out
}

func main() {
	log := logger.New()

	// Bypass switch — short-circuits the shim and exec's the real `claude`
	// binary directly so the extension behaves as if no wrapper were
	// configured. Two equivalent triggers (whichever is set wins):
	//
	//   1. Env var `CCPOCKET_SHIM_DISABLE=1` (set in
	//      claudeCode.environmentVariables; requires window reload)
	//   2. Sentinel file `~/.ccpocket-shim-disabled` (checked at every
	//      shim spawn — toggle with `touch` / `rm`, no reload needed)
	//
	// The extension prefixes our argv with the original `claude` binary
	// path when a wrapper is in effect, so we can recover the real binary
	// from os.Args itself.
	if shimDisabled() {
		realBin := findRealClaude(os.Args[1:])
		if realBin == "" {
			log.Errorf("shim bypass requested but real claude binary path not found in argv")
			os.Exit(1)
		}
		passthroughArgs := stripRealClaudePathFromArgs(os.Args[1:], realBin)
		log.Infof("shim bypass active — exec %s", realBin)
		err := syscall.Exec(realBin, append([]string{realBin}, passthroughArgs...), os.Environ())
		// Exec only returns on failure.
		log.Errorf("exec failed: %v", err)
		os.Exit(1)
	}

	args := parseArgs(os.Args[1:])
	if len(args.Unknown) > 0 {
		log.Warnf("ignoring unknown flags: %s", strings.Join(args.Unknown, " "))
	}

	// Intercept one-shot subcommands the Claude Code VSCode extension spawns
	// out-of-band — these expect a single JSON object on stdout and EOF, NOT
	// the stream-json conversational protocol. If we proceed into the normal
	// lifecycle the extension's `JSON.parse(stdout)` chokes on subsequent
	// envelopes (e.g. our exit-time result/success) — see "claude auth status
	// parse failed: SyntaxError" in the extension log.
	//
	// Currently handled: `auth status [--json]`. Extend the list as new
	// invocations surface in extension logs.
	if handleOneShotSubcommand(args.Unknown, log) {
		return
	}

	// Resolve session id we'll advertise on stdout. The extension may have
	// passed one explicitly; otherwise we mint one immediately so it can be
	// referenced before the Bridge sends session_created.
	sessionID := args.SessionID
	if sessionID == "" && args.Resume != "" {
		sessionID = args.Resume
	}
	if sessionID == "" {
		sessionID = newSessionID()
	}

	// Resolve project path. Override order:
	//
	//   1. CCPOCKET_PROJECT_PATH_OVERRIDE env var — wins unconditionally.
	//      Use this when the Bridge runs on a different host (typically a
	//      different OS) and the local workspace path won't match anything
	//      the Bridge's BRIDGE_ALLOWED_DIRS permits. The override is passed
	//      to Bridge verbatim, so set it to a path that exists on the
	//      Bridge's filesystem (e.g. `C:\Users\rikut\Desktop\claude-personal`
	//      when the Bridge is on a Windows machine).
	//   2. First `--add-dir` flag — VERBATIM (no Abs normalization, since the
	//      value may be a cross-OS path).
	//   3. Local cwd — fall-through, run through Abs for sanity.
	projectPath := ""
	if override := os.Getenv("CCPOCKET_PROJECT_PATH_OVERRIDE"); override != "" {
		projectPath = override
		log.Infof("project path overridden via CCPOCKET_PROJECT_PATH_OVERRIDE: %s", override)
	} else if len(args.AddDirs) > 0 {
		projectPath = args.AddDirs[0]
	} else {
		cwd, err := os.Getwd()
		if err != nil {
			log.Errorf("cwd lookup failed: %v", err)
			cwd = "."
		}
		if abs, err := filepath.Abs(cwd); err == nil {
			cwd = abs
		}
		projectPath = cwd
	}

	permissionMode := args.PermissionMode
	if permissionMode == "" {
		permissionMode = "default"
	}

	stdout := sdk.NewWriter(os.Stdout)
	// stdinReader is initialized in init(); avoid double-construction.

	// IMPORTANT: do NOT emit system/init here. The real `claude` binary only
	// emits its `system/init` AFTER receiving the first user-input envelope on
	// stdin. Emitting it eagerly here used to confuse the VSCode extension's
	// init handshake — it expects a `control_response` to its `initialize`
	// control_request before any transcript events appear. The init envelope is
	// emitted lazily from handleUserInput() on the first turn instead.

	bridgeURL := envOr("CCPOCKET_BRIDGE_URL", "ws://localhost:8765")
	bridgeToken := os.Getenv("CCPOCKET_BRIDGE_TOKEN")

	client, err := bridge.Dial(bridgeURL, bridgeToken, log)
	if err != nil {
		emitError(stdout, sessionID, fmt.Sprintf("bridge dial failed: %v", err))
		os.Exit(1)
	}
	defer client.Close()

	// Signal handling — convert SIGINT/SIGTERM into a context cancellation.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Infof("received signal %s — shutting down", sig)
		cancel()
	}()

	// The extension stores whatever id we put into system/init and passes it
	// back via --resume on subsequent spawns. We use it as the key for the
	// ext-id → bridge-session-id store so each chat tab resolves to the
	// right Bridge conversation even when multiple chats are open in parallel.
	externalSessionID := sessionID
	store := sessionstore.Open(sessionstore.DefaultPath())

	st := &state{
		sessionID:         sessionID,
		externalSessionID: externalSessionID,
		store:             store,
		projectPath:       projectPath,
		permissionMode:    permissionMode,
		continueMode:      args.Continue,
		resumeID:          args.Resume,
		model:             args.Model,
		client:            client,
		log:               log,
		stdout:            stdout,
		startTime:         time.Now(),
		sessionListSeen:   make(chan struct{}),
		sessionListPing:   make(chan struct{}, 1),
	}

	// Three goroutines: stdin reader, bridge reader, signal/ctx watcher.
	var wg sync.WaitGroup
	wg.Add(2)
	exitCode := 0
	var exitMu sync.Mutex
	setExit := func(c int) {
		exitMu.Lock()
		if exitCode == 0 {
			exitCode = c
		}
		exitMu.Unlock()
	}

	go func() {
		defer wg.Done()
		if err := st.runStdinLoop(ctx); err != nil {
			log.Errorf("stdin loop: %v", err)
		}
		log.Debugf("stdin loop exited")
		cancel()
	}()

	go func() {
		defer wg.Done()
		if err := st.runBridgeLoop(ctx); err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, context.Canceled) {
				log.Errorf("bridge loop: %v", err)
				emitError(stdout, st.sessionID, fmt.Sprintf("bridge: %v", err))
				setExit(1)
			}
		}
		log.Debugf("bridge loop exited")
		cancel()
	}()

	wg.Wait()

	// If we exit cleanly with a Bridge "result/success" already emitted,
	// st.finished is true and we should NOT emit another result.
	if !st.finished.Load() {
		if exitCode != 0 {
			emitError(stdout, st.sessionID, "interrupted")
		} else {
			_ = stdout.Write(wire.Result{
				Type:             "result",
				Subtype:          "success",
				SessionID:        st.sessionID,
				TotalCostUSD:     0,
				DurationMS:       time.Since(st.startTime).Milliseconds(),
				IsError:          false,
				Usage:            defaultUsage(),
				ModelUsage:       map[string]any{},
				PermissionDenies: []any{},
			UUID:             newEventUUID(),
			})
		}
	} else if c := st.finishedExit.Load(); c != 0 {
		setExit(int(c))
	}
	os.Exit(exitCode)
}

// state is shared between the stdin and bridge goroutines.
type state struct {
	// sessionID is what we put in every envelope's `session_id` field.
	// It MUST stay stable for the lifetime of this shim spawn — the
	// extension's webview clears the chat transcript when it sees the
	// session_id change between envelopes, so flipping it mid-stream
	// causes the visible chat to reset and (in multi-chat scenarios)
	// makes one tab's response appear to bleed into another's empty
	// bubble. We bind it once to externalSessionID and never overwrite.
	sessionID string
	// externalSessionID is the id we advertise in `system/init` — the
	// extension stores it and passes it back via `--resume` on every
	// subsequent spawn for the same chat. Used as the key in `store`
	// to look up the real Bridge claude session UUID.
	externalSessionID string
	// bridgeSessionID is the Bridge's *internal* session record id (the
	// short hash like `0183acbb`) — what we pass to `bridge.Input` and
	// other Bridge requests. NEVER surfaces in stdout envelopes.
	bridgeSessionID string
	store           *sessionstore.Store
	projectPath       string
	permissionMode    string
	continueMode      bool
	resumeID          string
	model             string
	client            *bridge.Client
	log               *logger.Logger
	stdout            *sdk.Writer
	startTime         time.Time

	startedMu sync.Mutex
	started   bool
	// pendingFirstInput holds the first user prompt while we wait for the
	// Bridge's `session_created` reply (which carries the canonical sessionId).
	pendingFirstInput  string
	pendingFirstImages []bridge.Image

	initOnce sync.Once // gates the lazy system/init emission on first user input

	// sessionListSeen is closed once we receive the first session_list from
	// bridge. handleUserInput blocks briefly on this (with a timeout) before
	// looking up --resume in the store — bridge pushes session_list
	// automatically on connect with the full bridge_id -> claudeSessionId
	// map we need to resolve resumes correctly.
	sessionListSeen     chan struct{}
	sessionListSeenOnce sync.Once

	// sessionListLast caches the most recently received session_list message
	// raw bytes; sessionListPing fires (non-blocking, buffered 1) each time a
	// new one lands. The /sessions slash command uses these to make a fresh
	// request-and-wait without racing the broadcast indexer.
	sessionListLast atomic.Pointer[bridge.Message]
	sessionListPing chan struct{}

	// Streaming-turn state. The extension's stream parser requires the full
	// SSE sequence `message_start` → `content_block_start` → multiple
	// `content_block_delta` → `content_block_stop` → `message_delta` →
	// `message_stop`. We wrap Bridge `stream_delta` events with the
	// start/stop markers around each turn so the extension can consume them.
	streamingTurn    bool
	streamMessageID  string
	streamModel      string
	streamMu         sync.Mutex

	// claudeIdRequestOnce fires exactly one ListSessions request per turn,
	// scheduled at the first sign of claude actively responding (the first
	// stream_delta or assistant envelope). By the time claude is streaming,
	// the bridge has already captured its current claudeSessionId from
	// claude's system event; refreshing session_list now gives our store
	// the LATEST id well before the result envelope closes the turn.
	claudeIdRequestOnce sync.Once

	finished     atomicBool
	finishedExit atomic.Int32 // suggested exit code when finished is set
}

// runStdinLoop pumps lines off stdin, lazily issues a Bridge `start` on the
// first user input, then forwards subsequent inputs as `input` messages.
func (s *state) runStdinLoop(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line, err := s.readStdinLine(ctx)
		if err != nil {
			return err
		}
		if len(line) == 0 {
			continue
		}
		var env wire.StdinEnvelope
		if err := json.Unmarshal(line, &env); err != nil {
			s.log.Warnf("stdin: malformed envelope: %v", err)
			continue
		}
		s.log.Debugf("stdin <- %s", truncate(string(line), 400))

		switch env.Type {
		case "user":
			if err := s.handleUserInput(env); err != nil {
				s.log.Errorf("user input: %v", err)
			}
		case "control_request":
			// The extension blocks on `subtype:"initialize"` (and uses the
			// same channel for set_permission_mode, interrupt, get_settings,
			// can_use_tool, etc.). Failure to respond within 60 s causes the
			// extension to bail with "Subprocess initialization did not
			// complete". For MVP we acknowledge every control request with a
			// success+empty response so the extension can proceed.
			if err := s.handleControlRequest(env); err != nil {
				s.log.Errorf("control_request: %v", err)
			}
		case "control_response", "control_cancel_request", "keep_alive", "result":
			// Echoes / things we don't originate; ignore.
			s.log.Debugf("stdin: ignoring %q envelope", env.Type)
		default:
			s.log.Debugf("stdin: unhandled envelope type %q", env.Type)
		}
	}
}

// readStdinLine is a cancellable wrapper around sdk.Reader.Next.
//
// We can't `select` on a sync read directly; we route the read through a
// channel so ctx.Done() can unblock the caller. The goroutine itself stays
// blocked on stdin until the process exits.
func (s *state) readStdinLine(ctx context.Context) ([]byte, error) {
	type result struct {
		data []byte
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		d, e := stdinReader.Next()
		ch <- result{d, e}
	}()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case r := <-ch:
		return r.data, r.err
	}
}

// stdinReader is a process-wide singleton because there's only one stdin and
// reads must not be interleaved across goroutines.
var stdinReader *sdk.Reader

func init() {
	stdinReader = sdk.NewReader(os.Stdin)
}

// handleControlRequest acknowledges control_request envelopes the extension
// sends on stdin. The critical one is `subtype:"initialize"` — the extension
// blocks on `await (await this.request({subtype:"initialize",...})).response`
// for up to 60 s. For MVP we always respond with `subtype:"success"` and an
// empty inner response so the extension's `supportedCommands` / models /
// agents getters resolve to empty arrays without crashing.
func (s *state) handleControlRequest(env wire.StdinEnvelope) error {
	subtype := ""
	if len(env.Request) > 0 {
		var req wire.ControlRequest
		if err := json.Unmarshal(env.Request, &req); err == nil {
			subtype = req.Subtype
		}
	}
	s.log.Debugf("stdin: control_request request_id=%s subtype=%s", env.RequestID, subtype)

	resp := map[string]any{}
	// `initialize` is the handshake; the extension reads `.commands`, `.models`,
	// `.agents` off the response later via lazy getters. Empty arrays are
	// safe — the UI just shows no slash-commands / model picker entries until
	// we wire them up properly.
	if subtype == "initialize" {
		// Advertise shim-handled slash commands so the extension's autocomplete
		// picks them up. The extension reads `name`/`description` off each entry.
		resp["commands"] = []any{
			map[string]any{
				"name":        "sessions",
				"description": "List past CC Pocket Bridge sessions (handled in-shim)",
				"argumentHint": "",
			},
		}
		resp["models"] = []any{}
		resp["agents"] = []any{}
	}

	return s.stdout.Write(wire.ControlResponse{
		Type: "control_response",
		Response: wire.ControlResponseEnv{
			Subtype:   "success",
			RequestID: env.RequestID,
			Response:  resp,
		},
	})
}

func (s *state) handleUserInput(env wire.StdinEnvelope) error {
	if env.SessionID != "" && env.SessionID != s.sessionID {
		s.log.Debugf("stdin: session id changed %s -> %s", s.sessionID, env.SessionID)
		s.sessionID = env.SessionID
	}
	var msg wire.UserMessage
	if err := json.Unmarshal(env.Message, &msg); err != nil {
		return fmt.Errorf("decode user message: %w", err)
	}

	// Emit system/init lazily on first user input with the STABLE
	// externalSessionID — NOT the Bridge's internal session id. The
	// extension's webview clears the chat transcript whenever the
	// session_id changes between envelopes, so we must keep this value
	// constant for the lifetime of the spawn. Bridge's internal id is
	// tracked separately in `bridgeSessionID` for routing Input/Approve
	// requests.
	s.emitSystemInit()

	// Walk content blocks: collect text, image attachments, and tool_result
	// responses. Image blocks come through when the user pastes a screenshot
	// into the VSCode chat — the extension serializes them as Anthropic-SDK
	// image content ({type:"image", source:{type:"base64", media_type, data}}),
	// which we re-pack as bridge's images: [{base64, mimeType}] shape.
	var textParts []string
	var images []bridge.Image
	for _, c := range msg.Content {
		switch c.Type {
		case "text":
			if c.Text != "" {
				textParts = append(textParts, c.Text)
			}
		case "image":
			if c.Source != nil && c.Source.Data != "" {
				images = append(images, bridge.Image{
					Base64:   c.Source.Data,
					MimeType: c.Source.MediaType,
				})
			} else {
				s.log.Debugf("stdin: image content with empty source — dropping")
			}
		case "tool_result":
			s.log.Debugf("stdin: tool_result for %s (not yet forwarded)", c.ToolUseID)
			// MVP: tool_result forwarding is a phase-2 concern (we auto-approve
			// on the Bridge side, so the extension shouldn't normally produce
			// these). We log and drop them.
		}
	}
	combined := strings.Join(textParts, "\n")
	if combined == "" && len(images) == 0 {
		return nil
	}

	// Built-in slash commands handled entirely inside the shim — never forwarded
	// to the bridge. Lets the user query bridge state (past sessions, etc.)
	// from any chat tab without disturbing the active conversation.
	if cmd := matchSlashCommand(combined); cmd == "/sessions" {
		return s.handleSessionsCommand()
	}

	// First user input triggers Bridge `start`. The Bridge replies with
	// `session_created` carrying the canonical sessionId; only after that
	// arrives can subsequent `input` messages be routed correctly. We buffer
	// the very first prompt and let dispatchBridge flush it from the
	// `session_created` handler. Subsequent prompts in the same session can
	// be sent immediately since we already have a valid sessionId.
	s.startedMu.Lock()
	if !s.started {
		s.pendingFirstInput = combined
		s.pendingFirstImages = images
		// Resolve the Bridge sessionId we want to resume.
		//
		// Priority:
		//   1. sessionstore lookup of externalSessionID — the canonical
		//      mapping. Each chat tab gets its own externalSessionID via
		//      system/init, so this routes resumes precisely to the
		//      matching Bridge session and prevents multi-chat crossover.
		//   2. Continue=true fallback — only when we have *some* resume
		//      intent (--continue or --resume) but no stored mapping.
		//      Bridge will then pick the most recent session for the
		//      projectPath; this is the legacy behavior that confuses
		//      parallel chats but is acceptable on a brand-new install
		//      that hasn't built up a mapping yet.
		//   3. Otherwise: fresh session.
		// Resolve the Bridge sessionId we want to resume.
		//
		// The extension's --resume value is the *bridge* session id (because
		// we emit bridge_id in system/init). But Bridge.start.sessionId is
		// forwarded directly to `claude --resume` and that requires the
		// underlying *claude UUID*. We bridge the gap via the sessionstore,
		// which we populate from inbound `session_list` events (every entry
		// has both ids). Lookup table key = bridge_id, value = claudeSessionId.
		//
		// If no mapping is found, fall back to continue:true so Bridge picks
		// the most-recent session for the project. That's imprecise for
		// multi-chat but at least avoids the "not a UUID" error from claude.
		opts := bridge.StartOpts{
			ProjectPath:    s.projectPath,
			PermissionMode: s.permissionMode,
			Model:          s.model,
		}
		if s.resumeID != "" {
			// Race avoidance: bridge pushes session_list on connect with
			// the bridge_id -> claudeSessionId mapping we need. The user
			// envelope may arrive on stdin before that push lands. Block
			// briefly to give it a chance.
			select {
			case <-s.sessionListSeen:
			case <-time.After(1500 * time.Millisecond):
				s.log.Debugf("bridge: session_list not seen within 1500ms — proceeding with possibly stale store")
			}
			if s.store != nil {
				if m, ok := s.store.Get(s.resumeID); ok && m.BridgeSessionID != "" {
					opts.SessionID = m.BridgeSessionID
					s.log.Infof("bridge: resuming claude session %s (bridge id %s)", m.BridgeSessionID, s.resumeID)
				}
			}
			if opts.SessionID == "" {
				// NOTE: deliberately NO continue:true fallback. If we don't
				// have a mapping, the --resume value is from a chat we
				// can't safely resolve (typically a legacy chat whose
				// resume id pre-dates the bridge_id -> claudeSessionId
				// store). continue:true would resume "the most recent
				// session for this project" — which is ANY session and
				// causes cross-chat contamination ('chat A asked about
				// blue but Claude answers based on chat B's red context').
				// A fresh session loses the bridge-side conversation
				// memory for legacy chats, but at least keeps each chat
				// independent. Logged loudly so it's visible.
				s.log.Warnf("bridge: no claude UUID mapped for resume id %s — starting a FRESH session to avoid cross-chat contamination (legacy chat context lost)", s.resumeID)
			}
		} else if s.continueMode {
			opts.Continue = true
		}
		if err := s.client.Start(opts); err != nil {
			s.pendingFirstInput = ""
			s.pendingFirstImages = nil
			s.startedMu.Unlock()
			return fmt.Errorf("bridge start: %w", err)
		}
		s.started = true
		s.log.Infof("bridge: started session for %s (mode=%s) — buffering first input until session_created", s.projectPath, s.permissionMode)
		s.startedMu.Unlock()
		return nil
	}
	s.startedMu.Unlock()

	return s.client.Input(s.bridgeSessionID, combined, images...)
}

// runBridgeLoop reads Bridge messages and translates them into SDK envelopes
// on stdout. Terminates on `result`, `error`, or EOF.
func (s *state) runBridgeLoop(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		msg, err := s.client.ReadMessage()
		if err != nil {
			return err
		}
		if err := s.dispatchBridge(msg); err != nil {
			s.log.Warnf("dispatch: %v", err)
		}
		if s.finished.Load() {
			return nil
		}
	}
}

// requestClaudeSessionIdRefresh asks the bridge to (re-)broadcast its
// session_list exactly once per turn. The follow-up session_list arrives in
// the same dispatch loop a few ms later and indexSessionList persists
// (externalSessionID → claudeSessionId) to the store, so the NEXT spawn for
// this chat can hand the right --resume value to claude.
//
// Trigger sites: the first stream_delta and the first assistant envelope —
// either guarantees claude has emitted its system event, which is the point
// at which session.claudeSessionId becomes non-empty inside the bridge.
// Fire-and-forget on purpose: blocking the bridge dispatch goroutine on the
// reply would deadlock since the reply is dispatched by the same goroutine.
func (s *state) requestClaudeSessionIdRefresh() {
	s.claudeIdRequestOnce.Do(func() {
		if err := s.client.ListSessions(); err != nil {
			s.log.Debugf("turn-start list_sessions: %v", err)
		}
	})
}

// flushPendingFirstInput sends the buffered first prompt once the Bridge has
// confirmed a session_created (which carries the canonical sessionId we must
// now use). No-op when nothing is buffered.
func (s *state) flushPendingFirstInput() {
	s.startedMu.Lock()
	pending := s.pendingFirstInput
	pendingImages := s.pendingFirstImages
	s.pendingFirstInput = ""
	s.pendingFirstImages = nil
	s.startedMu.Unlock()
	if pending == "" && len(pendingImages) == 0 {
		return
	}
	s.log.Infof("bridge: flushing buffered first input to bridge session %s (%d chars, %d images)", s.bridgeSessionID, len(pending), len(pendingImages))
	if err := s.client.Input(s.bridgeSessionID, pending, pendingImages...); err != nil {
		s.log.Errorf("bridge input (first turn): %v", err)
	}
}

// ensureStreamingTurn emits the SSE prelude (`message_start` +
// `content_block_start`) the extension's stream parser requires before any
// `content_block_delta`. Idempotent — safe to call once per delta. The
// optional `model` hint is used for the `message_start` `message.model`
// field; when empty we use a generic "claude" fallback.
func (s *state) ensureStreamingTurn(model string) error {
	s.streamMu.Lock()
	defer s.streamMu.Unlock()
	if s.streamingTurn {
		return nil
	}
	id := generateMessageID()
	if model == "" {
		model = "claude"
	}
	if err := s.stdout.Write(wire.MessageStart(id, s.sessionID, model, newEventUUID())); err != nil {
		return err
	}
	if err := s.stdout.Write(wire.ContentBlockStart(s.sessionID, newEventUUID(), 0)); err != nil {
		return err
	}
	s.streamMessageID = id
	s.streamModel = model
	s.streamingTurn = true
	return nil
}

// endStreamingTurn emits the SSE epilogue (`content_block_stop` →
// `message_delta` → `message_stop`) to close out a streaming turn. Idempotent.
func (s *state) endStreamingTurn(stopReason string) error {
	s.streamMu.Lock()
	defer s.streamMu.Unlock()
	if !s.streamingTurn {
		return nil
	}
	if stopReason == "" {
		stopReason = "end_turn"
	}
	if err := s.stdout.Write(wire.ContentBlockStop(s.sessionID, newEventUUID(), 0)); err != nil {
		return err
	}
	if err := s.stdout.Write(wire.MessageDelta(s.sessionID, stopReason, newEventUUID())); err != nil {
		return err
	}
	if err := s.stdout.Write(wire.MessageStop(s.sessionID, newEventUUID())); err != nil {
		return err
	}
	s.streamingTurn = false
	return nil
}

// defaultUsage returns the full nested usage shape the real claude binary
// emits. The extension's renderer reaches into nested fields like
// `usage.cache_creation.foo` and calls `.something()` on them — missing
// fields blow up with "Cannot read properties of undefined". We populate
// every key real claude does (all zeroed) so renderer code paths are safe.
func defaultUsage() map[string]any {
	return map[string]any{
		"input_tokens":                0,
		"output_tokens":               0,
		"cache_creation_input_tokens": 0,
		"cache_read_input_tokens":     0,
		"server_tool_use": map[string]any{
			"web_search_requests": 0,
			"web_fetch_requests":  0,
		},
		"service_tier": nil,
		"cache_creation": map[string]any{
			"ephemeral_1h_input_tokens": 0,
			"ephemeral_5m_input_tokens": 0,
		},
		"inference_geo": nil,
		"iterations":    []any{},
		"speed":         "standard",
	}
}

// generateMessageID mints a random `msg_…` style id similar to what the
// Anthropic API emits. We just need something unique per streaming turn.
func generateMessageID() string {
	var b [12]byte
	_, _ = cryptoRand.Read(b[:])
	return "msg_" + hex.EncodeToString(b[:])
}

// newEventUUID mints a UUID-format string used for the top-level `uuid` field
// on each emitted envelope. The extension's webview keys per-message
// tracking off this value; emitting it (rather than leaving it empty) keeps
// stream events correctly bucketed when the user switches tabs mid-response.
func newEventUUID() string {
	var b [16]byte
	_, _ = cryptoRand.Read(b[:])
	// Set the variant + version bits to make it a valid UUIDv4.
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// emitSystemInit writes the deferred `system/init` envelope. Idempotent via
// initOnce. We delay this call until after the Bridge confirms
// `session_created` so the `session_id` field carries the Bridge's canonical
// id — the extension stores that id and passes it back verbatim via --resume
// on the next spawn, giving us a direct identity mapping (no UUID
// translation table needed).
func (s *state) emitSystemInit() {
	s.initOnce.Do(func() {
		if err := s.stdout.Write(wire.SystemInit{
			Type:        "system",
			Subtype:     "init",
			SessionID:   s.sessionID,
			Model:       s.model,
			CWD:         s.projectPath,
			Tools:       []string{},
			MCPServers:  []string{},
			APIKeySrc:   "none",
			Permissions: s.permissionMode,
			UUID:        newEventUUID(),
		}); err != nil {
			s.log.Errorf("write system/init: %v", err)
		}
	})
}

// dispatchBridge translates a single Bridge message into stdout envelopes.
func (s *state) dispatchBridge(m *bridge.Message) error {
	// Critical multi-chat filter: the bridge fans broadcastSessionMessage()
	// out to EVERY connected WebSocket client (see packages/bridge/src/
	// websocket.ts:3748 — `for (const client of this.wss.clients)`). With
	// multiple shim processes (one per VSCode chat tab) sharing the bridge,
	// each shim receives stream_delta / assistant / result / status events
	// for OTHER shims' sessions as well. Without filtering, chat A's stream
	// gets rendered into chat B's transcript — the exact cross-mixing the
	// user has been seeing.
	//
	// We drop any sessioned message whose sessionId doesn't match our
	// bridgeSessionID. Exceptions:
	//   - `system/session_created`: bridge sends this targeted (`this.send(ws,…)`
	//     in websocket.ts:849), so we only see OUR own. It also carries the
	//     bridgeSessionID we need to install — must be processed before the
	//     filter ever has a value to compare against.
	//   - `session_list`: broadcast, but legitimately global — we walk all
	//     entries to populate the store.
	if m.Type != "session_list" && !(m.Type == "system" && m.StringField("subtype") == "session_created") {
		if sid := m.StringField("sessionId"); sid != "" && s.bridgeSessionID != "" && sid != s.bridgeSessionID {
			s.log.Debugf("bridge: drop cross-session msg type=%s sid=%s (ours=%s)", m.Type, sid, s.bridgeSessionID)
			return nil
		}
	}

	switch m.Type {
	case "system":
		// session_created carries the Bridge's internal session id. We
		// track it in bridgeSessionID for downstream bridge.Input/Approve
		// calls but DO NOT touch s.sessionID — that field stays bound to
		// externalSessionID for the lifetime of the spawn so the
		// extension's webview doesn't reset the chat transcript.
		subtype := m.StringField("subtype")
		if subtype == "session_created" {
			if sid := m.StringField("sessionId"); sid != "" && sid != s.bridgeSessionID {
				s.log.Infof("bridge: bridge session id -> %s (external=%s)", sid, s.externalSessionID)
				s.bridgeSessionID = sid
			}
			s.flushPendingFirstInput()
			// Ask the bridge to re-broadcast session_list. The connect-time
			// session_list pre-dated our session; this nudges the bridge to
			// push an updated one once claudeSessionId is populated, which
			// we need for the (externalSessionID -> claudeSessionId) store
			// mapping that future resumes depend on.
			_ = s.client.ListSessions()
		}
		return nil

	case "session_list":
		// Bridge pushes session_list whenever a session changes. Each entry
		// includes its bridge id AND the underlying claude session UUID once
		// the claude SDK has emitted it. Cache the mapping so a future
		// spawn can resume the exact session by passing claudeSessionId as
		// start.sessionId (which bridge forwards to claude as --resume).
		s.indexSessionList(m)
		s.sessionListLast.Store(m)
		select {
		case s.sessionListPing <- struct{}{}:
		default:
		}
		s.sessionListSeenOnce.Do(func() { close(s.sessionListSeen) })
		return nil

	case "assistant":
		// Close any open streaming turn FIRST so the extension's parser
		// finalizes accumulated content_block_delta into a complete
		// content block before the canonical assistant envelope lands.
		// We DO still emit the assistant envelope after — it acts as the
		// authoritative "this is the persisted message" signal for the
		// extension; suppressing it caused the UI to drop the tail of
		// the response (deltas that arrived close to message_stop were
		// rendered live but not persisted).
		if err := s.endStreamingTurn("end_turn"); err != nil {
			s.log.Errorf("close streaming turn (before assistant): %v", err)
		}
		// Some turns produce only tool_use blocks (no stream_delta), so the
		// stream_delta-side trigger never fires. Repeat the request here as
		// a safety net; sync.Once dedupes if stream_delta already fired.
		s.requestClaudeSessionIdRefresh()
		return s.handleAssistant(m)

	case "stream_delta":
		text := m.StringField("text")
		if text == "" {
			return nil
		}
		// Claude is actively responding now → its system/init has been
		// captured by the bridge, so session.claudeSessionId is valid.
		// Fire-and-forget a ListSessions so the broadcast that comes back
		// updates our store mapping (externalSessionID → claudeSessionId)
		// before the turn ends. Once per turn to avoid spamming the bridge.
		s.requestClaudeSessionIdRefresh()
		if err := s.ensureStreamingTurn(""); err != nil {
			return err
		}
		return s.stdout.Write(wire.ContentBlockDelta(text, s.sessionID, newEventUUID(), 0))

	case "tool_result":
		return s.handleToolResult(m)

	case "permission_request":
		// MVP: auto-approve immediately and log.
		toolUseID := m.StringField("toolUseId")
		if toolUseID == "" {
			toolUseID = m.StringField("id")
		}
		s.log.Infof("permission_request auto-approved (toolUseId=%s, tool=%s)",
			toolUseID, m.StringField("toolName"))
		if toolUseID == "" {
			return nil
		}
		return s.client.Approve(s.bridgeSessionID, toolUseID)

	case "status":
		s.log.Debugf("bridge status=%s", m.StringField("status"))
		return nil

	case "result":
		s.finished.Store(true)
		cost := m.NumberField("cost")
		dur := int64(m.NumberField("duration"))
		subtype := m.StringField("subtype")
		if subtype == "" {
			subtype = "success"
		}
		isError := subtype != "success"
		// Make sure any open streaming turn is closed BEFORE the result
		// envelope — otherwise the extension never sees content_block_stop /
		// message_stop and treats the message as truncated.
		stopReason := "end_turn"
		if isError {
			stopReason = "error"
		}
		if err := s.endStreamingTurn(stopReason); err != nil {
			s.log.Errorf("close streaming turn: %v", err)
		}

		// The mid-turn `requestClaudeSessionIdRefresh()` (called from the
		// stream_delta / assistant handlers) already nudged the bridge for a
		// fresh session_list with the current turn's claudeSessionId. By the
		// time we land here the response broadcast has been processed by
		// dispatchBridge → indexSessionList → store. No blocking wait needed
		// — and indeed a wait on the same goroutine would deadlock since
		// it's the dispatch loop that would consume the session_list reply.
		out := wire.Result{
			Type:             "result",
			Subtype:          subtype,
			SessionID:        s.sessionID,
			TotalCostUSD:     cost,
			DurationMS:       dur,
			IsError:          isError,
			Usage:            defaultUsage(),
			ModelUsage:       map[string]any{},
			PermissionDenies: []any{},
			UUID:             newEventUUID(),
		}
		if isError {
			out.Result = m.StringField("error")
		}
		return s.stdout.Write(out)

	case "error":
		errMsg := m.StringField("message")
		errCode := m.StringField("errorCode")
		s.log.Errorf("bridge error: %s (%s)", errMsg, errCode)
		// Make sure a system/init has been emitted — otherwise an early
		// Bridge error (e.g. path_not_allowed) leaves the extension with
		// zero envelopes and the result envelope alone confuses its parser.
		s.emitSystemInit()
		// Close any open streaming turn before emitting the terminal result.
		if err := s.endStreamingTurn("error"); err != nil {
			s.log.Errorf("close streaming turn (on error): %v", err)
		}
		// Treat fatal-looking error codes as terminal; otherwise just forward
		// as a result/error and let the user retry.
		s.finished.Store(true)
		s.finishedExit.Store(1)
		return s.stdout.Write(wire.Result{
			Type:             "result",
			Subtype:          "error",
			SessionID:        s.sessionID,
			IsError:          true,
			Result:           errMsg,
			Usage:            defaultUsage(),
			ModelUsage:       map[string]any{},
			PermissionDenies: []any{},
			UUID:             newEventUUID(),
		})

	default:
		s.log.Debugf("bridge: unhandled message type %q", m.Type)
		return nil
	}
}

// indexSessionList walks the Bridge's session_list. Two things happen:
//
//   1. For every session entry that has a populated `claudeSessionId`, we
//      record (bridge_id → claudeSessionId) so legacy chats whose extension
//      resume id IS a Bridge id can still resolve to a real claude UUID.
//
//   2. When we encounter the entry for OUR OWN current spawn (matching by
//      bridge_id), we ALSO save (externalSessionID → claudeSessionId). That
//      is the mapping the next spawn for this chat will look up: the
//      extension will pass back our system/init's session_id (=
//      externalSessionID), and we need to translate it to claudeSessionId
//      for the next start.sessionId.
func (s *state) indexSessionList(m *bridge.Message) {
	if s.store == nil {
		return
	}
	raw, ok := m.Decoded["sessions"]
	if !ok {
		return
	}
	var sessions []struct {
		ID              string `json:"id"`
		ClaudeSessionID string `json:"claudeSessionId"`
		ProjectPath     string `json:"projectPath"`
	}
	if err := json.Unmarshal(raw, &sessions); err != nil {
		s.log.Debugf("session_list: decode failed: %v", err)
		return
	}
	for _, sess := range sessions {
		if sess.ID == "" || sess.ClaudeSessionID == "" {
			continue
		}
		if err := s.store.Put(sess.ID, sess.ClaudeSessionID, sess.ProjectPath); err != nil {
			s.log.Debugf("sessionstore.Put(%s -> %s) failed: %v", sess.ID, sess.ClaudeSessionID, err)
		}
		// Pair the resolved claudeSessionId with OUR externalSessionID so
		// the next spawn (which arrives with --resume <externalSessionID>)
		// can translate it.
		if sess.ID == s.bridgeSessionID && s.externalSessionID != "" && s.externalSessionID != sess.ID {
			if err := s.store.Put(s.externalSessionID, sess.ClaudeSessionID, sess.ProjectPath); err != nil {
				s.log.Debugf("sessionstore.Put(%s -> %s) failed: %v", s.externalSessionID, sess.ClaudeSessionID, err)
			} else {
				s.log.Debugf("sessionstore: %s -> %s (ours, external)", s.externalSessionID, sess.ClaudeSessionID)
			}
		}
	}
}

// matchSlashCommand returns the canonical command token (e.g. "/sessions")
// if input is a single-line slash command we handle in-shim, or "" otherwise.
// Tolerates leading/trailing whitespace and ignores anything after the first
// token so future commands can take arguments.
func matchSlashCommand(input string) string {
	trimmed := strings.TrimSpace(input)
	if !strings.HasPrefix(trimmed, "/") {
		return ""
	}
	// Multi-line input is treated as a normal prompt that happens to start
	// with a slash — don't intercept.
	if strings.Contains(trimmed, "\n") {
		return ""
	}
	first := trimmed
	if i := strings.IndexAny(trimmed, " \t"); i >= 0 {
		first = trimmed[:i]
	}
	switch first {
	case "/sessions":
		return "/sessions"
	}
	return ""
}

// handleSessionsCommand renders the bridge's session list as a synthetic
// assistant message and closes the turn — never forwarding the user's
// `/sessions` text to the bridge. The bridge is asked for a fresh list_sessions
// and we wait briefly for the broadcast to land; if it doesn't, we fall back
// to whatever cached entry we have. A turn-terminating result envelope is
// always emitted so the extension's UI state returns to idle.
func (s *state) handleSessionsCommand() error {
	s.emitSystemInit()

	// Drain any stale ping so we wait for a FRESH broadcast.
	select {
	case <-s.sessionListPing:
	default:
	}
	if err := s.client.ListSessions(); err != nil {
		s.log.Errorf("/sessions: list_sessions request failed: %v", err)
	}
	select {
	case <-s.sessionListPing:
	case <-time.After(1500 * time.Millisecond):
		s.log.Debugf("/sessions: no fresh session_list within 1500ms — using cached")
	}

	body := s.renderSessionsMarkdown(s.sessionListLast.Load())

	msgID := "msg_sessions_" + newEventUUID()
	if err := s.stdout.Write(wire.AssistantOut{
		Type: "assistant",
		Message: wire.AssistantInner{
			ID:    msgID,
			Role:  "assistant",
			Type:  "message",
			Model: s.model,
			Content: []wire.ContentBlock{{
				Type: "text",
				Text: body,
			}},
		},
		SessionID: s.sessionID,
		UUID:      newEventUUID(),
	}); err != nil {
		s.log.Errorf("/sessions: write assistant: %v", err)
	}
	return s.stdout.Write(wire.Result{
		Type:             "result",
		Subtype:          "success",
		SessionID:        s.sessionID,
		IsError:          false,
		Result:           body,
		Usage:            defaultUsage(),
		ModelUsage:       map[string]any{},
		PermissionDenies: []any{},
		UUID:             newEventUUID(),
	})
}

// renderSessionsMarkdown formats the bridge's session_list into a readable
// markdown summary. Sorted by lastActivityAt desc so the most active sessions
// appear first. Tells the user how to resume — we can't add a clickable
// action since the Claude Code extension's UI is closed.
func (s *state) renderSessionsMarkdown(m *bridge.Message) string {
	if m == nil {
		return "_(bridge から session_list がまだ届いていません。少し待ってからもう一度試してください)_"
	}
	raw, ok := m.Decoded["sessions"]
	if !ok {
		return "_(session_list の sessions フィールドが空でした)_"
	}
	var entries []struct {
		ID              string `json:"id"`
		ClaudeSessionID string `json:"claudeSessionId"`
		ProjectPath     string `json:"projectPath"`
		Name            string `json:"name"`
		Status          string `json:"status"`
		CreatedAt       string `json:"createdAt"`
		LastActivityAt  string `json:"lastActivityAt"`
		LastMessage     string `json:"lastMessage"`
		GitBranch       string `json:"gitBranch"`
		Provider        string `json:"provider"`
	}
	if err := json.Unmarshal(raw, &entries); err != nil {
		return fmt.Sprintf("_(session_list を decode できませんでした: %v)_", err)
	}
	if len(entries) == 0 {
		return "**過去のセッション: 0件**\n\nまだ bridge にセッションが登録されていません。"
	}
	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].LastActivityAt > entries[j].LastActivityAt
	})

	var b strings.Builder
	fmt.Fprintf(&b, "**過去のセッション一覧 — %d 件**\n\n", len(entries))
	for i, e := range entries {
		title := e.Name
		if title == "" {
			title = "(no name)"
		}
		fmt.Fprintf(&b, "**%d. %s** ", i+1, title)
		if e.Provider != "" {
			fmt.Fprintf(&b, "_(%s)_ ", e.Provider)
		}
		fmt.Fprintf(&b, "— `%s`\n", shortTime(e.LastActivityAt))
		fmt.Fprintf(&b, "- project: `%s`\n", e.ProjectPath)
		if e.GitBranch != "" {
			fmt.Fprintf(&b, "- branch: `%s`\n", e.GitBranch)
		}
		if e.Status != "" {
			fmt.Fprintf(&b, "- status: %s\n", e.Status)
		}
		if e.LastMessage != "" {
			fmt.Fprintf(&b, "- last: %s\n", truncate(strings.ReplaceAll(e.LastMessage, "\n", " "), 100))
		}
		if e.ClaudeSessionID != "" {
			fmt.Fprintf(&b, "- claudeSessionId: `%s`\n", e.ClaudeSessionID)
		} else {
			fmt.Fprintf(&b, "- bridgeId: `%s` _(claudeSessionId 未確定)_\n", e.ID)
		}
		b.WriteString("\n")
	}
	b.WriteString("---\n")
	b.WriteString("_resume するには別のチャットタブを開いて、最初の入力で目的の `claudeSessionId` を含むメッセージを送ってください。VSCode 拡張の UI 側で `--resume <id>` を発火する手段がないため、shim 側からの直接オープンは現状不可です。_\n")
	return b.String()
}

// shortTime trims an ISO-8601 timestamp to "YYYY-MM-DD HH:MM" for display.
// Returns the input unchanged if it doesn't match the expected prefix shape.
func shortTime(iso string) string {
	if len(iso) < 16 {
		return iso
	}
	return iso[:10] + " " + iso[11:16]
}

func (s *state) handleAssistant(m *bridge.Message) error {
	rawMsg, ok := m.Decoded["message"]
	if !ok {
		return nil
	}
	var inner struct {
		ID      string          `json:"id"`
		Role    string          `json:"role"`
		Type    string          `json:"type"`
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(rawMsg, &inner); err != nil {
		return fmt.Errorf("decode assistant message: %w", err)
	}

	// Content blocks can be {type:"text", text}, {type:"tool_use", id, name, input},
	// or {type:"thinking"}. We pass text + tool_use through verbatim and drop
	// thinking blocks (the extension renders them only when the SDK opts in).
	var blocks []map[string]any
	if err := json.Unmarshal(inner.Content, &blocks); err != nil {
		return fmt.Errorf("decode content blocks: %w", err)
	}
	cleaned := make([]wire.ContentBlock, 0, len(blocks))
	for _, b := range blocks {
		t, _ := b["type"].(string)
		switch t {
		case "text":
			text, _ := b["text"].(string)
			cleaned = append(cleaned, wire.ContentBlock{Type: "text", Text: text})
		case "tool_use":
			id, _ := b["id"].(string)
			name, _ := b["name"].(string)
			input, _ := b["input"].(map[string]any)
			cleaned = append(cleaned, wire.ContentBlock{
				Type: "tool_use", ID: id, Name: name, Input: input,
			})
		case "thinking":
			// Skipped — see comment above.
		}
	}
	if len(cleaned) == 0 {
		return nil
	}

	// When the assistant envelope follows a streamed turn, reuse the same
	// id (and our generated streamMessageID for `uuid`) as the message_start
	// SSE event. The extension keys live-rendered messages by id, so
	// matching ids cause it to update the existing bubble in place rather
	// than appending a second one. Without this the user sees every
	// response twice — once accumulated from deltas, once from this
	// envelope.
	s.streamMu.Lock()
	useID := inner.ID
	useUUID := m.StringField("messageUuid")
	if s.streamMessageID != "" {
		useID = s.streamMessageID
	}
	s.streamMu.Unlock()
	// Every emitted envelope MUST have a uuid (the webview keys per-event
	// tracking off it). Generate one if the bridge didn't supply one.
	if useUUID == "" {
		useUUID = newEventUUID()
	}

	out := wire.AssistantOut{
		Type: "assistant",
		Message: wire.AssistantInner{
			ID:      useID,
			Role:    "assistant",
			Type:    "message",
			Model:   inner.Model,
			Content: cleaned,
		},
		SessionID: s.sessionID,
		UUID:      useUUID,
	}
	return s.stdout.Write(out)
}

func (s *state) handleToolResult(m *bridge.Message) error {
	toolUseID := m.StringField("toolUseId")
	if toolUseID == "" {
		return nil
	}
	content := m.StringField("content")
	return s.stdout.Write(wire.UserOut{
		Type: "user",
		Message: wire.UserMessage{
			Role: "user",
			Content: []wire.UserContentItem{{
				Type:      "tool_result",
				ToolUseID: toolUseID,
				ToolResult: json.RawMessage(mustJSON(content)),
			}},
		},
		SessionID: s.sessionID,
	})
}

// emitError writes a terminal result/error envelope. Empty defaults are
// supplied for permission_denials / usage / modelUsage so the extension's
// renderer doesn't choke on .join() / property access of undefined arrays.
func emitError(w *sdk.Writer, sessionID, msg string) {
	_ = w.Write(wire.Result{
		Type:             "result",
		Subtype:          "error",
		SessionID:        sessionID,
		IsError:          true,
		Result:           msg,
		Usage:            defaultUsage(),
		ModelUsage:       map[string]any{},
		PermissionDenies: []any{},
			UUID:             newEventUUID(),
	})
}

// ----- small helpers -----------------------------------------------------

func mustJSON(v any) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		return []byte("null")
	}
	return data
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// newSessionID mints an RFC-4122-ish v4 identifier without external deps.
func newSessionID() string {
	var b [16]byte
	if _, err := readRandom(b[:]); err != nil {
		// Fallback to time-based id; collision risk is acceptable for the
		// shim's session-id slot.
		return fmt.Sprintf("shim-%d", time.Now().UnixNano())
	}
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	// %x of a byte slice emits two hex chars per byte; %x of a 4-byte slice
	// always yields 8 chars, so the canonical 8-4-4-4-12 layout is preserved.
	return fmt.Sprintf("%x-%x-%x-%x-%x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// readRandom is a tiny indirection so tests can swap the entropy source.
var readRandom = func(p []byte) (int, error) {
	return cryptoRand.Read(p)
}
