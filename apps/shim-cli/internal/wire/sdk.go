// Package wire contains stream-json envelope types exchanged between the
// Anthropic Claude Code VSCode extension and the shim over stdin/stdout.
//
// Only the fields the shim actually reads or writes are typed explicitly.
// Extra incoming fields are tolerated via `json.RawMessage` where needed.
package wire

import "encoding/json"

// ----- Inbound (extension -> shim, on stdin) ------------------------------

// StdinEnvelope is the lowest-common-denominator shape of stdin envelopes.
// The shim peeks at `Type` first, then re-decodes into the matching struct.
//
// `RequestID` and `Request` are populated when the envelope is a
// `type:"control_request"` from the extension's control channel (e.g. the
// `subtype:"initialize"` handshake the extension issues immediately after
// spawning the CLI and blocks on for up to 60 s).
type StdinEnvelope struct {
	Type      string          `json:"type"`
	SessionID string          `json:"session_id,omitempty"`
	Message   json.RawMessage `json:"message,omitempty"`
	RequestID string          `json:"request_id,omitempty"`
	Request   json.RawMessage `json:"request,omitempty"`
}

// ControlRequest is the inner payload of a `type:"control_request"` envelope.
// We only inspect `Subtype` to dispatch; everything else is opaque.
type ControlRequest struct {
	Subtype string `json:"subtype"`
}

// UserMessage is the inner `message` of a `type:"user"` envelope.
type UserMessage struct {
	Role    string            `json:"role"`
	Content []UserContentItem `json:"content"`
}

// UserContentItem is a single content block inside a user message.
// Supports text inputs ({type:"text", text:"…"}), tool results
// ({type:"tool_result", tool_use_id:"…", content:"…"}), and images
// (Anthropic-SDK style: {type:"image", source:{type:"base64", media_type:"image/png", data:"<base64>"}}).
type UserContentItem struct {
	Type       string          `json:"type"`
	Text       string          `json:"text,omitempty"`
	ToolUseID  string          `json:"tool_use_id,omitempty"`
	ToolResult json.RawMessage `json:"content,omitempty"`
	Source     *ImageSource    `json:"source,omitempty"`
}

// ImageSource is the Anthropic-style image source descriptor. The
// extension pastes screenshots as base64 with media_type set to image/png
// (or image/jpeg). We forward both fields to bridge as {base64, mimeType}.
type ImageSource struct {
	Type      string `json:"type"`       // "base64"
	MediaType string `json:"media_type"` // e.g. "image/png"
	Data      string `json:"data"`       // base64-encoded payload
}

// ----- Outbound (shim -> extension, on stdout) ----------------------------

// SystemInit is the one-shot init message the shim writes on startup.
type SystemInit struct {
	Type            string   `json:"type"`    // "system"
	Subtype         string   `json:"subtype"` // "init"
	SessionID       string   `json:"session_id"`
	Model           string   `json:"model,omitempty"`
	CWD             string   `json:"cwd,omitempty"`
	Tools           []string `json:"tools"`
	MCPServers      []string `json:"mcp_servers"`
	APIKeySrc       string   `json:"apiKeySource,omitempty"`
	Permissions     string   `json:"permissionMode,omitempty"`
	UUID            string   `json:"uuid"`
	ParentToolUseID *string  `json:"parent_tool_use_id"`
}

// AssistantOut wraps an assistant message emitted on stdout.
// `UUID` and `ParentToolUseID` are always emitted (even as empty/null)
// because the extension's webview keys message tracking by uuid.
type AssistantOut struct {
	Type            string         `json:"type"` // "assistant"
	Message         AssistantInner `json:"message"`
	SessionID       string         `json:"session_id"`
	UUID            string         `json:"uuid"`
	ParentToolUseID *string        `json:"parent_tool_use_id"`
}

// AssistantInner is the Anthropic-style assistant message envelope.
type AssistantInner struct {
	ID      string         `json:"id,omitempty"`
	Role    string         `json:"role"`
	Type    string         `json:"type,omitempty"`
	Model   string         `json:"model,omitempty"`
	Content []ContentBlock `json:"content"`
}

// ContentBlock is a single block in an assistant message (text or tool_use).
type ContentBlock struct {
	Type  string         `json:"type"`              // "text" | "tool_use"
	Text  string         `json:"text,omitempty"`
	ID    string         `json:"id,omitempty"`
	Name  string         `json:"name,omitempty"`
	Input map[string]any `json:"input,omitempty"`
}

// UserOut wraps a user message emitted on stdout (used to deliver tool results
// from the Bridge back into the extension's transcript).
type UserOut struct {
	Type      string      `json:"type"`              // "user"
	Message   UserMessage `json:"message"`
	SessionID string      `json:"session_id,omitempty"`
}

// StreamEvent represents a `type:"stream_event"` envelope on stdout.
// We use it to deliver `content_block_delta` text deltas in real time.
//
// The extension's webview tracks messages by their `uuid` and uses
// `parent_tool_use_id` for nesting. Always emit both — even if our
// values are placeholders — so the webview doesn't drop or misroute
// events. Missing uuid was suspected of causing mid-stream tab
// switches to render events into the wrong chat tab.
type StreamEvent struct {
	Type            string         `json:"type"` // "stream_event"
	Event           map[string]any `json:"event"`
	SessionID       string         `json:"session_id,omitempty"`
	UUID            string         `json:"uuid"`
	ParentToolUseID *string        `json:"parent_tool_use_id"`
}

// Result is the terminal envelope emitted before exit.
//
// Field set is wider than what we actually populate because the VSCode
// extension reaches into `permission_denials` / `model_usage` / `usage` with
// `.join()` / property lookups; missing fields trigger
// `TypeError: Cannot read properties of undefined` in the extension's
// renderer. We always emit empty defaults to keep the extension happy.
type Result struct {
	Type             string         `json:"type"`             // "result"
	Subtype          string         `json:"subtype"`          // "success" | "error"
	SessionID        string         `json:"session_id,omitempty"`
	TotalCostUSD     float64        `json:"total_cost_usd"`
	DurationMS       int64          `json:"duration_ms"`
	DurationAPIMS    int64          `json:"duration_api_ms"`
	IsError          bool           `json:"is_error"`
	NumTurns         int            `json:"num_turns"`
	Result           string         `json:"result,omitempty"`
	StopReason       string         `json:"stop_reason,omitempty"`
	Usage            map[string]any `json:"usage"`
	ModelUsage       map[string]any `json:"modelUsage"`
	PermissionDenies []any          `json:"permission_denials"`
	TerminalReason   string         `json:"terminal_reason,omitempty"`
	UUID             string         `json:"uuid"`
	ParentToolUseID  *string        `json:"parent_tool_use_id"`
}

// ControlResponse is the envelope the shim writes back on stdout when the
// extension issues a `control_request`. The extension's `await this.request(V)`
// resolves once a matching `request_id` arrives with `subtype:"success"`.
type ControlResponse struct {
	Type     string             `json:"type"`     // "control_response"
	Response ControlResponseEnv `json:"response"`
}

// ControlResponseEnv is the nested `.response` field that carries the actual
// result data. The inner `.response` (any) is what the extension's getter
// methods (supportedCommands/Models/Agents) consume.
type ControlResponseEnv struct {
	Subtype   string         `json:"subtype"`              // "success" | "error"
	RequestID string         `json:"request_id"`
	Response  map[string]any `json:"response,omitempty"`
	Error     string         `json:"error,omitempty"`
}

// ContentBlockDelta builds a stream_event for a text delta. The `index` is
// required by the extension's stream parser (it uses it to locate the matching
// content block created by content_block_start). For text-only MVP we always
// emit index 0.
func ContentBlockDelta(text string, sessionID, eventUUID string, index int) StreamEvent {
	return StreamEvent{
		Type: "stream_event",
		Event: map[string]any{
			"type":  "content_block_delta",
			"index": index,
			"delta": map[string]any{"type": "text_delta", "text": text},
		},
		SessionID: sessionID,
		UUID:      eventUUID,
	}
}

// MessageStart builds the SSE-style `message_start` stream event the extension
// expects BEFORE any content_block_* events. Without this, the extension's
// renderer crashes on the first content_block_delta with
// `V.content.at(-1).type` of undefined.
func MessageStart(messageID, sessionID, model, eventUUID string) StreamEvent {
	return StreamEvent{
		Type: "stream_event",
		Event: map[string]any{
			"type": "message_start",
			"message": map[string]any{
				"id":            messageID,
				"type":          "message",
				"role":          "assistant",
				"model":         model,
				"content":       []any{},
				"stop_reason":   nil,
				"stop_sequence": nil,
				"usage":         map[string]any{},
			},
		},
		SessionID: sessionID,
		UUID:      eventUUID,
	}
}

// ContentBlockStart opens a content block (typically a text block). Always
// emitted once per block before any content_block_delta for that index.
func ContentBlockStart(sessionID, eventUUID string, index int) StreamEvent {
	return StreamEvent{
		Type: "stream_event",
		Event: map[string]any{
			"type":          "content_block_start",
			"index":         index,
			"content_block": map[string]any{"type": "text", "text": ""},
		},
		SessionID: sessionID,
		UUID:      eventUUID,
	}
}

// ContentBlockStop closes a content block.
func ContentBlockStop(sessionID, eventUUID string, index int) StreamEvent {
	return StreamEvent{
		Type: "stream_event",
		Event: map[string]any{
			"type":  "content_block_stop",
			"index": index,
		},
		SessionID: sessionID,
		UUID:      eventUUID,
	}
}

// MessageDelta + MessageStop close the streaming turn.
func MessageDelta(sessionID, stopReason, eventUUID string) StreamEvent {
	return StreamEvent{
		Type: "stream_event",
		Event: map[string]any{
			"type":  "message_delta",
			"delta": map[string]any{"stop_reason": stopReason, "stop_sequence": nil},
			"usage": map[string]any{},
		},
		SessionID: sessionID,
		UUID:      eventUUID,
	}
}

func MessageStop(sessionID, eventUUID string) StreamEvent {
	return StreamEvent{
		Type:      "stream_event",
		Event:     map[string]any{"type": "message_stop"},
		SessionID: sessionID,
		UUID:      eventUUID,
	}
}
