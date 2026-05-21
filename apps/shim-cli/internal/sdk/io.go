// Package sdk implements the stream-json IO that the VSCode extension expects.
//
// stdin is line-delimited JSON sent by the extension. stdout is the same shape,
// emitted by the shim. We use a 4 MiB scanner buffer to comfortably handle
// large tool results and base64 image attachments.
package sdk

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"sync"
)

// MaxLineBytes caps a single envelope line (4 MiB). Large enough for tool
// results that include diffs or short base64 image attachments.
const MaxLineBytes = 4 * 1024 * 1024

// Reader streams JSON envelopes off stdin one line at a time.
type Reader struct {
	scanner *bufio.Scanner
}

// NewReader returns a Reader bound to the given io.Reader (typically os.Stdin).
func NewReader(r io.Reader) *Reader {
	s := bufio.NewScanner(r)
	buf := make([]byte, 0, 64*1024)
	s.Buffer(buf, MaxLineBytes)
	return &Reader{scanner: s}
}

// Next reads the next line. Returns the raw bytes (not including the newline)
// and io.EOF when stdin closes.
func (r *Reader) Next() ([]byte, error) {
	if !r.scanner.Scan() {
		err := r.scanner.Err()
		if err == nil {
			err = io.EOF
		}
		return nil, err
	}
	// Copy so subsequent calls don't overwrite returned data.
	src := r.scanner.Bytes()
	out := make([]byte, len(src))
	copy(out, src)
	return out, nil
}

// Writer serializes envelopes to stdout. All writes are line-delimited JSON
// and serialized through a mutex so multiple goroutines can emit safely.
type Writer struct {
	mu  sync.Mutex
	w   io.Writer
}

// NewWriter returns a Writer bound to the given io.Writer (typically os.Stdout).
func NewWriter(w io.Writer) *Writer {
	return &Writer{w: w}
}

// Default returns a Writer bound to os.Stdout.
func Default() *Writer {
	return NewWriter(os.Stdout)
}

// Write encodes v as JSON, appends a newline, and writes the result atomically.
func (w *Writer) Write(v any) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = w.w.Write(data)
	return err
}
