// Package wsclient is a minimal stdlib-only WebSocket client (RFC 6455).
//
// Why we don't pull in a third-party library: the shim only needs
// client-side text frames against a single Bridge URL, with no compression
// extensions, no autobahn fancy edge cases. ~300 LOC of stdlib code keeps
// `go.mod` empty and `go build` reproducible offline.
//
// Supported:
//   - ws:// and wss:// schemes
//   - text frames (UTF-8 payloads), fragmented or not
//   - server-initiated ping; we reply pong automatically
//   - server-initiated close frames
//   - graceful client-initiated close
//
// Not supported: per-message-deflate, binary frames, subprotocol negotiation,
// extensions.
package wsclient

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Opcodes per RFC 6455 §5.2.
const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

// Conn is a single client-side WebSocket connection.
type Conn struct {
	netConn    net.Conn
	readBuf    *bufio.Reader
	writeMu    sync.Mutex
	closeOnce  sync.Once
	closed     bool
	closedMu   sync.Mutex
	pingHandler func() // optional; called when a ping arrives
}

// Dial opens a WebSocket connection to the given URL.
//
// urlStr accepts ws:// or wss:// schemes. The HTTP Upgrade handshake is
// performed inline; on success, the returned *Conn is ready for ReadMessage /
// WriteText.
func Dial(urlStr string) (*Conn, error) {
	u, err := url.Parse(urlStr)
	if err != nil {
		return nil, fmt.Errorf("invalid url: %w", err)
	}
	var (
		netConn net.Conn
		host    = u.Host
	)
	switch u.Scheme {
	case "ws":
		if !strings.Contains(host, ":") {
			host += ":80"
		}
		netConn, err = net.DialTimeout("tcp", host, 15*time.Second)
	case "wss":
		if !strings.Contains(host, ":") {
			host += ":443"
		}
		netConn, err = tls.Dial("tcp", host, &tls.Config{ServerName: u.Hostname()})
	default:
		return nil, fmt.Errorf("unsupported scheme: %s", u.Scheme)
	}
	if err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}

	// Generate a fresh 16-byte nonce per RFC 6455 §4.1.
	nonceBytes := make([]byte, 16)
	if _, err := rand.Read(nonceBytes); err != nil {
		_ = netConn.Close()
		return nil, fmt.Errorf("nonce: %w", err)
	}
	key := base64.StdEncoding.EncodeToString(nonceBytes)

	requestPath := u.RequestURI()
	if requestPath == "" {
		requestPath = "/"
	}
	req := strings.Builder{}
	req.WriteString("GET " + requestPath + " HTTP/1.1\r\n")
	req.WriteString("Host: " + u.Host + "\r\n")
	req.WriteString("Upgrade: websocket\r\n")
	req.WriteString("Connection: Upgrade\r\n")
	req.WriteString("Sec-WebSocket-Key: " + key + "\r\n")
	req.WriteString("Sec-WebSocket-Version: 13\r\n")
	req.WriteString("\r\n")
	if _, err := io.WriteString(netConn, req.String()); err != nil {
		_ = netConn.Close()
		return nil, fmt.Errorf("write handshake: %w", err)
	}

	br := bufio.NewReader(netConn)
	resp, err := http.ReadResponse(br, &http.Request{Method: "GET"})
	if err != nil {
		_ = netConn.Close()
		return nil, fmt.Errorf("read handshake: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusSwitchingProtocols {
		_ = netConn.Close()
		return nil, fmt.Errorf("handshake refused: %s", resp.Status)
	}
	if !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") ||
		!strings.EqualFold(resp.Header.Get("Connection"), "upgrade") {
		_ = netConn.Close()
		return nil, errors.New("handshake missing Upgrade/Connection headers")
	}

	// Validate Sec-WebSocket-Accept = base64(sha1(key + magic)).
	const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	h := sha1.New()
	h.Write([]byte(key + magic))
	expected := base64.StdEncoding.EncodeToString(h.Sum(nil))
	if got := resp.Header.Get("Sec-WebSocket-Accept"); got != expected {
		_ = netConn.Close()
		return nil, fmt.Errorf("handshake bad accept: got %q want %q", got, expected)
	}

	return &Conn{netConn: netConn, readBuf: br}, nil
}

// ReadMessage blocks until a complete TEXT message arrives. Control frames
// (ping/pong/close) are handled transparently.
//
// Returns (payload, nil) on success, (nil, io.EOF) on close, or another error
// on protocol violations.
func (c *Conn) ReadMessage() ([]byte, error) {
	var assembled []byte
	for {
		final, opcode, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch opcode {
		case opPing:
			// Reply pong with the same payload.
			if err := c.writeFrame(opPong, payload, true); err != nil {
				return nil, err
			}
			if c.pingHandler != nil {
				c.pingHandler()
			}
			continue
		case opPong:
			// No-op; we don't send pings of our own.
			continue
		case opClose:
			// Echo close (if not already closed) then return EOF.
			c.markClosed()
			_ = c.writeFrame(opClose, payload, true)
			_ = c.netConn.Close()
			return nil, io.EOF
		case opText, opBinary, opContinuation:
			assembled = append(assembled, payload...)
			if final {
				return assembled, nil
			}
		default:
			return nil, fmt.Errorf("unknown opcode 0x%x", opcode)
		}
	}
}

// WriteText sends a single TEXT frame containing the given payload.
func (c *Conn) WriteText(p []byte) error {
	c.closedMu.Lock()
	if c.closed {
		c.closedMu.Unlock()
		return errors.New("wsclient: write on closed connection")
	}
	c.closedMu.Unlock()
	return c.writeFrame(opText, p, true)
}

// Close sends a normal-closure close frame and tears down the TCP socket.
func (c *Conn) Close() error {
	var err error
	c.closeOnce.Do(func() {
		c.markClosed()
		// 1000 = normal closure.
		body := []byte{0x03, 0xE8}
		_ = c.writeFrame(opClose, body, true)
		err = c.netConn.Close()
	})
	return err
}

func (c *Conn) markClosed() {
	c.closedMu.Lock()
	c.closed = true
	c.closedMu.Unlock()
}

// readFrame reads exactly one frame off the wire.
//
// Returns (final, opcode, payload, err). The frame is unmasked before return
// (servers send unmasked frames; we mask outgoing frames in writeFrame).
func (c *Conn) readFrame() (bool, byte, []byte, error) {
	h, err := c.readBuf.ReadByte()
	if err != nil {
		return false, 0, nil, err
	}
	final := h&0x80 != 0
	opcode := h & 0x0F
	// RSV1-3 must be zero (we don't negotiate extensions).
	if h&0x70 != 0 {
		return false, 0, nil, errors.New("RSV bits set; extensions not supported")
	}

	mLen, err := c.readBuf.ReadByte()
	if err != nil {
		return false, 0, nil, err
	}
	masked := mLen&0x80 != 0
	payloadLen := uint64(mLen & 0x7F)

	switch payloadLen {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(c.readBuf, ext[:]); err != nil {
			return false, 0, nil, err
		}
		payloadLen = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(c.readBuf, ext[:]); err != nil {
			return false, 0, nil, err
		}
		payloadLen = binary.BigEndian.Uint64(ext[:])
	}

	if payloadLen > MaxPayloadBytes {
		return false, 0, nil, fmt.Errorf("frame too large: %d", payloadLen)
	}

	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(c.readBuf, maskKey[:]); err != nil {
			return false, 0, nil, err
		}
	}

	payload := make([]byte, payloadLen)
	if payloadLen > 0 {
		if _, err := io.ReadFull(c.readBuf, payload); err != nil {
			return false, 0, nil, err
		}
		if masked {
			for i := range payload {
				payload[i] ^= maskKey[i%4]
			}
		}
	}
	return final, opcode, payload, nil
}

// MaxPayloadBytes caps a single frame payload at 16 MiB to defend against a
// hostile peer trying to OOM us. The Bridge never sends frames anywhere near
// this size in practice.
const MaxPayloadBytes = 16 * 1024 * 1024

// writeFrame sends a single frame. Per RFC 6455 §5.3, client frames MUST be
// masked.
func (c *Conn) writeFrame(opcode byte, payload []byte, final bool) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	var header [14]byte
	n := 0
	header[0] = opcode
	if final {
		header[0] |= 0x80
	}

	payloadLen := len(payload)
	switch {
	case payloadLen <= 125:
		header[1] = byte(payloadLen) | 0x80 // mask bit
		n = 2
	case payloadLen <= 0xFFFF:
		header[1] = 126 | 0x80
		binary.BigEndian.PutUint16(header[2:4], uint16(payloadLen))
		n = 4
	default:
		header[1] = 127 | 0x80
		binary.BigEndian.PutUint64(header[2:10], uint64(payloadLen))
		n = 10
	}

	// 4-byte mask key.
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return fmt.Errorf("mask: %w", err)
	}
	copy(header[n:n+4], mask[:])
	n += 4

	if _, err := c.netConn.Write(header[:n]); err != nil {
		return err
	}
	if payloadLen == 0 {
		return nil
	}
	masked := make([]byte, payloadLen)
	for i := range payload {
		masked[i] = payload[i] ^ mask[i%4]
	}
	_, err := c.netConn.Write(masked)
	return err
}
