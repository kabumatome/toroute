package control

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadReply(t *testing.T) {
	lines, err := readReply(bufio.NewReader(strings.NewReader("250-version=0.4\r\n250 OK\r\n")))
	if err != nil || len(lines) != 2 {
		t.Fatalf("%v %v", lines, err)
	}
}
func TestReadReplyRejectsLFAndLimits(t *testing.T) {
	if _, err := readReply(bufio.NewReader(strings.NewReader("250 OK\n"))); err == nil {
		t.Fatal("LF accepted")
	}
	var b strings.Builder
	b.WriteString("250+X=\r\n")
	for i := 0; i < 4096; i++ {
		b.WriteString("\r\n")
	}
	b.WriteString(".\r\n250 OK\r\n")
	if _, err := readReply(bufio.NewReader(strings.NewReader(b.String()))); err == nil {
		t.Fatal("line limit bypassed")
	}
}
func TestParseProtocolInfo(t *testing.T) {
	m, p, err := parseProtocolInfo([]string{`250-PROTOCOLINFO 1`, `250-AUTH METHODS=SAFECOOKIE COOKIEFILE="/run/x"`, `250 OK`})
	if err != nil || !m["SAFECOOKIE"] || p != "/run/x" {
		t.Fatalf("%v %q %v", m, p, err)
	}
	for _, lines := range [][]string{{`250 OK`}, {`250-AUTH METHODS=SAFECOOKIE COOKIEFILE=/x`, `250 OK`}, {`250-AUTH METHODS=SAFECOOKIE COOKIEFILE="/x"`, `250-AUTH METHODS=SAFECOOKIE COOKIEFILE="/x"`, `250 OK`}} {
		if _, _, err := parseProtocolInfo(lines); err == nil {
			t.Fatalf("accepted %v", lines)
		}
	}
}
func TestParseStatus(t *testing.T) {
	lines := []string{`250-version=0.4.9.11`, `250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done"`, `250-net/listeners/socks="127.0.0.1:9050"`, `250 OK`}
	s, err := parseStatus(lines)
	if err != nil || !s.Ready || s.Progress != 100 {
		t.Fatalf("%+v %v", s, err)
	}
	for _, bad := range [][]string{{`250-version=0.4`, `250 OK`}, {`250-version=0.4`, `250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=101 TAG=x SUMMARY="x"`, `250-net/listeners/socks="127.0.0.1:9050"`, `250 OK`}, {`250-version=0.4`, `250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=x SUMMARY="x"`, `250-net/listeners/socks="unix:/run/s"`, `250 OK`}} {
		if _, err := parseStatus(bad); err == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
}
func TestCookieFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "cookie")
	data := bytes.Repeat([]byte{1}, 32)
	if err := os.WriteFile(p, data, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := readCookieFile(p)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("%v %v", got, err)
	}
	if err := os.Chmod(p, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readCookieFile(p); err == nil {
		t.Fatal("open perms accepted")
	}
}
func TestHMAC(t *testing.T) {
	key := []byte("k")
	data := []byte("d")
	a := hmacSHA256(key, data)
	m := hmac.New(sha256.New, key)
	m.Write(data)
	if !hmac.Equal(a, m.Sum(nil)) {
		t.Fatal("mismatch")
	}
}

func TestClientSafeCookieRoundTrip(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "control.sock")
	cookiePath := filepath.Join(dir, "cookie")
	cookie := bytes.Repeat([]byte{7}, 32)
	if err := os.WriteFile(cookiePath, cookie, 0600); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	serverErr := make(chan error, 1)
	go func() {
		conn, e := ln.Accept()
		if e != nil {
			serverErr <- e
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		read := func() (string, error) {
			s, e := r.ReadString('\n')
			return strings.TrimSuffix(strings.TrimSuffix(s, "\n"), "\r"), e
		}
		if _, e = read(); e != nil {
			serverErr <- e
			return
		}
		ioWrite(conn, "250-PROTOCOLINFO 1\r\n250-AUTH METHODS=SAFECOOKIE COOKIEFILE=\""+cookiePath+"\"\r\n250 OK\r\n")
		challenge, e := read()
		if e != nil {
			serverErr <- e
			return
		}
		parts := strings.Fields(challenge)
		clientNonce, _ := hex.DecodeString(parts[2])
		serverNonce := bytes.Repeat([]byte{9}, 32)
		payload := bytes.Join([][]byte{cookie, clientNonce, serverNonce}, nil)
		serverHash := hmacSHA256([]byte(serverKey), payload)
		ioWrite(conn, "250 AUTHCHALLENGE SERVERHASH="+strings.ToUpper(hex.EncodeToString(serverHash))+" SERVERNONCE="+strings.ToUpper(hex.EncodeToString(serverNonce))+"\r\n")
		if _, e = read(); e != nil {
			serverErr <- e
			return
		}
		ioWrite(conn, "250 OK\r\n")
		cmd, e := read()
		if e != nil {
			serverErr <- e
			return
		}
		if cmd != "SIGNAL NEWNYM" {
			serverErr <- context.Canceled
			return
		}
		ioWrite(conn, "250 OK\r\n")
		serverErr <- nil
	}()
	c := Client{SocketPath: sock, CookiePath: cookiePath, Timeout: 2 * time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.NewNym(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-serverErr; err != nil {
		t.Fatal(err)
	}
}
func ioWrite(conn net.Conn, s string) { _, _ = conn.Write([]byte(s)) }
