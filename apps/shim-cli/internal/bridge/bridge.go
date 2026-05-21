// Package bridge speaks the CC Pocket Bridge WebSocket protocol.
//
// See packages/bridge/src/websocket.ts and parser.ts for the canonical
// definitions. We only model the subset the shim actually exchanges:
//
//   Outbound (shim -> bridge): start, input, approve, stop_session, interrupt
//   Inbound (bridge -> shim):  system, session_created, assistant, stream_delta,
//                              tool_result, permission_request, result,
//                              error, status
//
// Unknown inbound message types are surfaced as RawMessage so callers can
// inspect them without us blocking on schema drift.
package bridge

import (
	"encoding/json"
	"fmt"
	"net/url"

	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/logger"
	"github.com/K9i-0/ccpocket/apps/shim-cli/internal/wsclient"
)

// Client is a thin typed wrapper around wsclient.Conn.
type Client struct {
	conn *wsclient.Conn
	log  *logger.Logger
}

// Dial opens a connection to the Bridge at baseURL, appending ?token= when
// non-empty.
func Dial(baseURL, token string, log *logger.Logger) (*Client, error) {
	target := baseURL
	if token != "" {
		u, err := url.Parse(baseURL)
		if err != nil {
			return nil, fmt.Errorf("bridge url: %w", err)
		}
		q := u.Query()
		q.Set("token", token)
		u.RawQuery = q.Encode()
		target = u.String()
	}
	log.Infof("bridge: dialing %s", baseURL)
	c, err := wsclient.Dial(target)
	if err != nil {
		return nil, err
	}
	log.Infof("bridge: connected")
	return &Client{conn: c, log: log}, nil
}

// Close gracefully closes the underlying socket.
func (c *Client) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

// ----- Outbound message constructors -------------------------------------

// StartOpts captures the subset of `start` parameters the shim forwards.
type StartOpts struct {
	ProjectPath    string
	SessionID      string
	Continue       bool
	PermissionMode string
	Model          string
}

// Start sends a Bridge `start` request.
func (c *Client) Start(opts StartOpts) error {
	msg := map[string]any{
		"type":        "start",
		"projectPath": opts.ProjectPath,
	}
	if opts.SessionID != "" {
		msg["sessionId"] = opts.SessionID
	}
	if opts.Continue {
		msg["continue"] = true
	}
	if opts.PermissionMode != "" {
		msg["permissionMode"] = opts.PermissionMode
	}
	if opts.Model != "" {
		msg["model"] = opts.Model
	}
	return c.send(msg)
}

// Input forwards a user text input.
func (c *Client) Input(sessionID, text string) error {
	msg := map[string]any{
		"type": "input",
		"text": text,
	}
	if sessionID != "" {
		msg["sessionId"] = sessionID
	}
	return c.send(msg)
}

// Approve auto-approves a pending permission request.
func (c *Client) Approve(sessionID, id string) error {
	msg := map[string]any{
		"type": "approve",
		"id":   id,
	}
	if sessionID != "" {
		msg["sessionId"] = sessionID
	}
	return c.send(msg)
}

// Interrupt asks the Bridge to interrupt the current turn.
func (c *Client) Interrupt(sessionID string) error {
	msg := map[string]any{"type": "interrupt"}
	if sessionID != "" {
		msg["sessionId"] = sessionID
	}
	return c.send(msg)
}

// ListSessions asks the Bridge to push an up-to-date session_list. The shim
// needs this to learn the claudeSessionId that gets paired with a Bridge
// session id only after Claude emits its first system event — the
// connection-time session_list is stale for sessions just created.
func (c *Client) ListSessions() error {
	return c.send(map[string]any{"type": "list_sessions"})
}

// StopSession asks the Bridge to terminate the session.
func (c *Client) StopSession(sessionID string) error {
	msg := map[string]any{
		"type":      "stop_session",
		"sessionId": sessionID,
	}
	return c.send(msg)
}

func (c *Client) send(payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	c.log.Debugf("bridge -> %s", truncate(string(data), 400))
	return c.conn.WriteText(data)
}

// ----- Inbound message decoding ------------------------------------------

// Message is the loosely typed envelope of any Bridge -> client message.
// Specific subtypes are decoded via Decode* helpers below.
type Message struct {
	Type    string          `json:"type"`
	Raw     json.RawMessage `json:"-"`
	Decoded map[string]json.RawMessage
}

// ReadMessage reads the next Bridge envelope.
func (c *Client) ReadMessage() (*Message, error) {
	data, err := c.conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	c.log.Debugf("bridge <- %s", truncate(string(data), 400))
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, fmt.Errorf("decode bridge message: %w", err)
	}
	var t string
	if rt, ok := fields["type"]; ok {
		_ = json.Unmarshal(rt, &t)
	}
	return &Message{Type: t, Raw: append([]byte(nil), data...), Decoded: fields}, nil
}

// StringField extracts a top-level string field. Returns "" if missing.
func (m *Message) StringField(name string) string {
	raw, ok := m.Decoded[name]
	if !ok {
		return ""
	}
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

// NumberField extracts a top-level numeric field. Returns 0 if missing.
func (m *Message) NumberField(name string) float64 {
	raw, ok := m.Decoded[name]
	if !ok {
		return 0
	}
	var f float64
	_ = json.Unmarshal(raw, &f)
	return f
}

// Field returns the raw JSON value of a top-level field, or nil if missing.
func (m *Message) Field(name string) json.RawMessage {
	return m.Decoded[name]
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
