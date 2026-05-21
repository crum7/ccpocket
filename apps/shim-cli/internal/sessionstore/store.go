// Package sessionstore persists the mapping between the Anthropic Claude Code
// VSCode extension's session ids and the CC Pocket Bridge's session ids.
//
// Why it exists: the extension assigns every chat its own internal session id
// and passes that id back to the shim via `--resume` on every spawn after the
// first. The Bridge has its own session-id namespace and doesn't know about
// the extension's ids. Without a mapping, the shim's only fallback is the
// Bridge's `continue: true` flag — which picks the *most recent* session for
// a project. When the user has multiple chats open in parallel, that means a
// resume from chat A can land on chat B's session and the two contexts merge.
//
// The store keeps one row per extension session id: the matching Bridge
// session id, the projectPath it lives under, and the last-update timestamp.
// We write atomically (write-to-tmp + rename) so concurrent shim processes
// (one per active chat) don't corrupt each other; we accept that a racing
// pair of updates may lose one entry, which only causes a one-time
// continue:true fallback for that chat — not a crash.
package sessionstore

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Mapping captures a single ext-id -> bridge-id record.
type Mapping struct {
	ExtID           string    `json:"ext_id"`
	BridgeSessionID string    `json:"bridge_session_id"`
	ProjectPath     string    `json:"project_path,omitempty"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// fileSchema is the on-disk JSON shape. Wrapped in a versioned envelope so we
// can migrate the format later without breaking older shims.
type fileSchema struct {
	Version  int                `json:"version"`
	Sessions map[string]Mapping `json:"sessions"`
}

// Store is the public handle. A new instance reads (or creates) the on-disk
// store. All operations are safe to call from multiple goroutines.
type Store struct {
	path string
	mu   sync.Mutex
}

// DefaultPath returns the canonical store location, `$HOME/.config/ccpocket-shim/sessions.json`.
// On error (no HOME), returns "" — caller should treat as "no store available".
func DefaultPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "ccpocket-shim", "sessions.json")
}

// Open returns a Store bound to `path`. If `path` is empty, all operations
// are silent no-ops — convenient when no $HOME is available.
func Open(path string) *Store {
	return &Store{path: path}
}

// Get returns the mapping for `extID` (and true) or zero-value (and false).
// Safe to call before the file exists.
func (s *Store) Get(extID string) (Mapping, bool) {
	if s.path == "" || extID == "" {
		return Mapping{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := s.load()
	if err != nil {
		return Mapping{}, false
	}
	m, ok := data.Sessions[extID]
	return m, ok
}

// Put writes (or overwrites) the mapping for `extID`. No-op when extID or
// bridgeSessionID is empty. Performs an atomic rename so a concurrent reader
// never sees a half-written file.
func (s *Store) Put(extID, bridgeSessionID, projectPath string) error {
	if s.path == "" || extID == "" || bridgeSessionID == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := s.load()
	if err != nil {
		return fmt.Errorf("load store: %w", err)
	}
	if data.Sessions == nil {
		data.Sessions = make(map[string]Mapping)
	}
	data.Sessions[extID] = Mapping{
		ExtID:           extID,
		BridgeSessionID: bridgeSessionID,
		ProjectPath:     projectPath,
		UpdatedAt:       time.Now().UTC(),
	}

	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("mkdir store dir: %w", err)
	}

	// Atomic write: tmp file in the same directory, then rename. This avoids
	// the half-written-file race when two shim processes update the store
	// concurrently. One write may win and overwrite the other's update; that
	// only costs one extra continue:true fallback for the loser.
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".sessions-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create tmp: %w", err)
	}
	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	data.Version = 1
	if err := enc.Encode(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
		return fmt.Errorf("encode store: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmp.Name())
		return fmt.Errorf("close tmp: %w", err)
	}
	if err := os.Rename(tmp.Name(), s.path); err != nil {
		_ = os.Remove(tmp.Name())
		return fmt.Errorf("rename tmp -> %s: %w", s.path, err)
	}
	return nil
}

// load reads and parses the store file. A missing file yields an empty
// schema, not an error. The caller MUST hold s.mu.
func (s *Store) load() (fileSchema, error) {
	f, err := os.Open(s.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return fileSchema{Version: 1, Sessions: map[string]Mapping{}}, nil
		}
		return fileSchema{}, err
	}
	defer f.Close()
	raw, err := io.ReadAll(f)
	if err != nil {
		return fileSchema{}, err
	}
	if len(raw) == 0 {
		return fileSchema{Version: 1, Sessions: map[string]Mapping{}}, nil
	}
	var data fileSchema
	if err := json.Unmarshal(raw, &data); err != nil {
		// Treat malformed file as empty rather than failing every spawn.
		return fileSchema{Version: 1, Sessions: map[string]Mapping{}}, nil
	}
	if data.Sessions == nil {
		data.Sessions = make(map[string]Mapping)
	}
	return data, nil
}
