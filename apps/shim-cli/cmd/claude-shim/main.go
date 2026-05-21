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
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/bridge"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/logger"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/sdk"
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

	switch {
	case verbs[0] == "auth" && verbs[1] == "status":
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

func main() {
	log := logger.New()
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

	st := &state{
		sessionID:      sessionID,
		projectPath:    projectPath,
		permissionMode: permissionMode,
		continueMode:   args.Continue,
		resumeID:       args.Resume,
		model:          args.Model,
		client:         client,
		log:            log,
		stdout:         stdout,
		startTime:      time.Now(),
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
				Usage:            map[string]any{},
				ModelUsage:       map[string]any{},
				PermissionDenies: []any{},
			})
		}
	} else if c := st.finishedExit.Load(); c != 0 {
		setExit(int(c))
	}
	os.Exit(exitCode)
}

// state is shared between the stdin and bridge goroutines.
type state struct {
	sessionID      string
	projectPath    string
	permissionMode string
	continueMode   bool
	resumeID       string
	model          string
	client         *bridge.Client
	log            *logger.Logger
	stdout         *sdk.Writer
	startTime      time.Time

	startedMu sync.Mutex
	started   bool
	// pendingFirstInput holds the first user prompt while we wait for the
	// Bridge's `session_created` reply (which carries the canonical sessionId).
	pendingFirstInput string

	initOnce sync.Once // gates the lazy system/init emission on first user input

	// Streaming-turn state. The extension's stream parser requires the full
	// SSE sequence `message_start` → `content_block_start` → multiple
	// `content_block_delta` → `content_block_stop` → `message_delta` →
	// `message_stop`. We wrap Bridge `stream_delta` events with the
	// start/stop markers around each turn so the extension can consume them.
	streamingTurn    bool
	streamMessageID  string
	streamModel      string
	streamMu         sync.Mutex

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
		resp["commands"] = []any{}
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

	// Lazily emit system/init on the first user turn, mirroring the real
	// claude binary's behavior (the binary stays silent until stdin delivers
	// a user envelope, then prints `system/init` immediately before the
	// assistant response). Emitting it eagerly at startup confused the
	// extension's init handshake.
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
		}); err != nil {
			s.log.Errorf("write system/init: %v", err)
		}
	})

	// Walk content blocks: collect text, forward tool_result responses.
	var textParts []string
	for _, c := range msg.Content {
		switch c.Type {
		case "text":
			if c.Text != "" {
				textParts = append(textParts, c.Text)
			}
		case "tool_result":
			s.log.Debugf("stdin: tool_result for %s (not yet forwarded)", c.ToolUseID)
			// MVP: tool_result forwarding is a phase-2 concern (we auto-approve
			// on the Bridge side, so the extension shouldn't normally produce
			// these). We log and drop them.
		}
	}
	combined := strings.Join(textParts, "\n")
	if combined == "" {
		return nil
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
		opts := bridge.StartOpts{
			ProjectPath:    s.projectPath,
			SessionID:      s.resumeID,
			Continue:       s.continueMode,
			PermissionMode: s.permissionMode,
			Model:          s.model,
		}
		if err := s.client.Start(opts); err != nil {
			s.pendingFirstInput = ""
			s.startedMu.Unlock()
			return fmt.Errorf("bridge start: %w", err)
		}
		s.started = true
		s.log.Infof("bridge: started session for %s (mode=%s) — buffering first input until session_created", s.projectPath, s.permissionMode)
		s.startedMu.Unlock()
		return nil
	}
	s.startedMu.Unlock()

	return s.client.Input(s.sessionID, combined)
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

// flushPendingFirstInput sends the buffered first prompt once the Bridge has
// confirmed a session_created (which carries the canonical sessionId we must
// now use). No-op when nothing is buffered.
func (s *state) flushPendingFirstInput() {
	s.startedMu.Lock()
	pending := s.pendingFirstInput
	s.pendingFirstInput = ""
	s.startedMu.Unlock()
	if pending == "" {
		return
	}
	s.log.Infof("bridge: flushing buffered first input to session %s (%d chars)", s.sessionID, len(pending))
	if err := s.client.Input(s.sessionID, pending); err != nil {
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
	if err := s.stdout.Write(wire.MessageStart(id, s.sessionID, model)); err != nil {
		return err
	}
	if err := s.stdout.Write(wire.ContentBlockStart(s.sessionID, 0)); err != nil {
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
	if err := s.stdout.Write(wire.ContentBlockStop(s.sessionID, 0)); err != nil {
		return err
	}
	if err := s.stdout.Write(wire.MessageDelta(s.sessionID, stopReason)); err != nil {
		return err
	}
	if err := s.stdout.Write(wire.MessageStop(s.sessionID)); err != nil {
		return err
	}
	s.streamingTurn = false
	return nil
}

// generateMessageID mints a random `msg_…` style id similar to what the
// Anthropic API emits. We just need something unique per streaming turn.
func generateMessageID() string {
	var b [12]byte
	_, _ = cryptoRand.Read(b[:])
	return "msg_" + hex.EncodeToString(b[:])
}

// dispatchBridge translates a single Bridge message into stdout envelopes.
func (s *state) dispatchBridge(m *bridge.Message) error {
	switch m.Type {
	case "system":
		// session_created updates the session id we report.
		subtype := m.StringField("subtype")
		if subtype == "session_created" {
			if sid := m.StringField("sessionId"); sid != "" && sid != s.sessionID {
				s.log.Infof("bridge: session id %s -> %s", s.sessionID, sid)
				s.sessionID = sid
			}
			s.flushPendingFirstInput()
		}
		return nil

	case "session_created":
		if sid := m.StringField("sessionId"); sid != "" {
			s.sessionID = sid
		}
		s.flushPendingFirstInput()
		return nil

	case "assistant":
		// If we've been streaming, the extension already accumulated the
		// full text via content_block_delta events — emitting a separate
		// assistant envelope would create a duplicate message bubble in
		// the UI. Just close the stream cleanly and skip.
		if s.streamingTurn {
			return s.endStreamingTurn("end_turn")
		}
		return s.handleAssistant(m)

	case "stream_delta":
		text := m.StringField("text")
		if text == "" {
			return nil
		}
		if err := s.ensureStreamingTurn(""); err != nil {
			return err
		}
		return s.stdout.Write(wire.ContentBlockDelta(text, s.sessionID, 0))

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
		return s.client.Approve(s.sessionID, toolUseID)

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
		out := wire.Result{
			Type:             "result",
			Subtype:          subtype,
			SessionID:        s.sessionID,
			TotalCostUSD:     cost,
			DurationMS:       dur,
			IsError:          isError,
			Usage:            map[string]any{},
			ModelUsage:       map[string]any{},
			PermissionDenies: []any{},
		}
		if isError {
			out.Result = m.StringField("error")
		}
		return s.stdout.Write(out)

	case "error":
		errMsg := m.StringField("message")
		errCode := m.StringField("errorCode")
		s.log.Errorf("bridge error: %s (%s)", errMsg, errCode)
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
			Usage:            map[string]any{},
			ModelUsage:       map[string]any{},
			PermissionDenies: []any{},
		})

	default:
		s.log.Debugf("bridge: unhandled message type %q", m.Type)
		return nil
	}
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

	out := wire.AssistantOut{
		Type: "assistant",
		Message: wire.AssistantInner{
			ID:      inner.ID,
			Role:    "assistant",
			Type:    "message",
			Model:   inner.Model,
			Content: cleaned,
		},
		SessionID: s.sessionID,
		UUID:      m.StringField("messageUuid"),
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
		Usage:            map[string]any{},
		ModelUsage:       map[string]any{},
		PermissionDenies: []any{},
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
