// Package logger provides a stderr-only leveled logger for the shim.
//
// Output goes ONLY to stderr — the shim's stdout is reserved for the
// stream-json protocol that the Anthropic Claude Code VSCode extension reads.
package logger

import (
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

// Level represents a log severity.
type Level int

const (
	LevelDebug Level = iota
	LevelInfo
	LevelWarn
	LevelError
)

func (l Level) String() string {
	switch l {
	case LevelDebug:
		return "DEBUG"
	case LevelInfo:
		return "INFO"
	case LevelWarn:
		return "WARN"
	case LevelError:
		return "ERROR"
	default:
		return "?"
	}
}

func parseLevel(s string) Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return LevelDebug
	case "warn", "warning":
		return LevelWarn
	case "error":
		return LevelError
	default:
		return LevelInfo
	}
}

// Logger is the shim's leveled stderr logger.
type Logger struct {
	mu    sync.Mutex
	level Level
	out   *log.Logger
}

// New returns a Logger whose minimum level is taken from CCPOCKET_SHIM_LOG
// (default: info).
func New() *Logger {
	lvl := parseLevel(os.Getenv("CCPOCKET_SHIM_LOG"))
	return &Logger{
		level: lvl,
		out:   log.New(os.Stderr, "", 0),
	}
}

// SetLevel overrides the logger's minimum level.
func (l *Logger) SetLevel(lvl Level) {
	l.mu.Lock()
	l.level = lvl
	l.mu.Unlock()
}

func (l *Logger) log(lvl Level, format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if lvl < l.level {
		return
	}
	ts := time.Now().Format("15:04:05.000")
	msg := fmt.Sprintf(format, args...)
	l.out.Printf("%s [%s] [shim] %s", ts, lvl.String(), msg)
}

// Debugf logs at DEBUG level.
func (l *Logger) Debugf(format string, args ...any) { l.log(LevelDebug, format, args...) }

// Infof logs at INFO level.
func (l *Logger) Infof(format string, args ...any) { l.log(LevelInfo, format, args...) }

// Warnf logs at WARN level.
func (l *Logger) Warnf(format string, args ...any) { l.log(LevelWarn, format, args...) }

// Errorf logs at ERROR level.
func (l *Logger) Errorf(format string, args ...any) { l.log(LevelError, format, args...) }
