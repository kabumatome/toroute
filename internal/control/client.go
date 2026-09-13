package control

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	serverKey = "Tor safe cookie authentication server-to-controller hash"
	clientKey = "Tor safe cookie authentication controller-to-server hash"
)

type Client struct {
	SocketPath, CookiePath string
	Timeout                time.Duration
}
type Status struct {
	Ready          bool     `json:"ready"`
	Progress       int      `json:"bootstrap_progress"`
	Tag            string   `json:"bootstrap_tag,omitempty"`
	Summary        string   `json:"bootstrap_summary,omitempty"`
	TorVersion     string   `json:"tor_version,omitempty"`
	SocksListeners []string `json:"socks_listeners,omitempty"`
}

func (c Client) Do(ctx context.Context, command string) ([]string, error) {
	if c.Timeout <= 0 {
		return nil, errors.New("control timeout must be positive")
	}
	if strings.ContainsAny(command, "\r\n\x00") {
		return nil, errors.New("control command contains control characters")
	}
	d := net.Dialer{Timeout: c.Timeout}
	conn, err := d.DialContext(ctx, "unix", c.SocketPath)
	if err != nil {
		return nil, fmt.Errorf("connect control socket: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(c.Timeout))
	r := bufio.NewReaderSize(conn, 64*1024)
	if err := writeCommand(conn, "PROTOCOLINFO 1"); err != nil {
		return nil, err
	}
	protocol, err := readReply(r)
	if err != nil {
		return nil, fmt.Errorf("PROTOCOLINFO: %w", err)
	}
	methods, cookiePath, err := parseProtocolInfo(protocol)
	if err != nil {
		return nil, err
	}
	if !methods["SAFECOOKIE"] {
		return nil, errors.New("Tor did not offer SAFECOOKIE authentication")
	}
	if cookiePath != "" && cookiePath != c.CookiePath {
		return nil, fmt.Errorf("Tor reported unexpected cookie path %q", cookiePath)
	}
	cookie, err := readCookieFile(c.CookiePath)
	if err != nil {
		return nil, err
	}
	clientNonce := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, clientNonce); err != nil {
		return nil, fmt.Errorf("generate client nonce: %w", err)
	}
	if err := writeCommand(conn, "AUTHCHALLENGE SAFECOOKIE "+strings.ToUpper(hex.EncodeToString(clientNonce))); err != nil {
		return nil, err
	}
	challenge, err := readReply(r)
	if err != nil {
		return nil, fmt.Errorf("AUTHCHALLENGE: %w", err)
	}
	serverHash, serverNonce, err := parseChallenge(challenge)
	if err != nil {
		return nil, err
	}
	payload := bytes.Join([][]byte{cookie, clientNonce, serverNonce}, nil)
	expected := hmacSHA256([]byte(serverKey), payload)
	if subtle.ConstantTimeCompare(expected, serverHash) != 1 {
		return nil, errors.New("SAFECOOKIE server hash mismatch")
	}
	response := hmacSHA256([]byte(clientKey), payload)
	if err := writeCommand(conn, "AUTHENTICATE "+strings.ToUpper(hex.EncodeToString(response))); err != nil {
		return nil, err
	}
	if _, err := readReply(r); err != nil {
		return nil, fmt.Errorf("AUTHENTICATE: %w", err)
	}
	if err := writeCommand(conn, command); err != nil {
		return nil, err
	}
	return readReply(r)
}

func (c Client) Status(ctx context.Context) (Status, error) {
	lines, err := c.Do(ctx, "GETINFO version status/bootstrap-phase net/listeners/socks")
	if err != nil {
		return Status{}, err
	}
	return parseStatus(lines)
}
func (c Client) NewNym(ctx context.Context) error {
	lines, err := c.Do(ctx, "SIGNAL NEWNYM")
	if err != nil {
		return err
	}
	for _, line := range lines {
		if line == "250 OK" {
			return nil
		}
	}
	return errors.New("Tor did not acknowledge NEWNYM")
}

func parseStatus(lines []string) (Status, error) {
	var s Status
	seen := map[string]bool{}
	for _, line := range lines {
		body := stripCode(line)
		switch {
		case strings.HasPrefix(body, "version="):
			if seen["version"] {
				return Status{}, errors.New("duplicate version field")
			}
			seen["version"] = true
			s.TorVersion = strings.TrimPrefix(body, "version=")
			if s.TorVersion == "" {
				return Status{}, errors.New("empty Tor version")
			}
		case strings.HasPrefix(body, "status/bootstrap-phase="):
			if seen["bootstrap"] {
				return Status{}, errors.New("duplicate bootstrap field")
			}
			seen["bootstrap"] = true
			phase := strings.TrimPrefix(body, "status/bootstrap-phase=")
			progressText := parseField(phase, "PROGRESS")
			progress, e := strconv.Atoi(progressText)
			if e != nil || progress < 0 || progress > 100 {
				return Status{}, fmt.Errorf("invalid bootstrap progress %q", progressText)
			}
			s.Progress = progress
			s.Tag = parseField(phase, "TAG")
			summary, e := parseQuotedFieldStrict(phase, "SUMMARY")
			if e != nil {
				return Status{}, e
			}
			s.Summary = summary
		case strings.HasPrefix(body, "net/listeners/socks="):
			if seen["listeners"] {
				return Status{}, errors.New("duplicate SOCKS listener field")
			}
			seen["listeners"] = true
			listeners, e := parseQuotedList(strings.TrimPrefix(body, "net/listeners/socks="))
			if e != nil {
				return Status{}, e
			}
			for _, address := range listeners {
				host, port, e := net.SplitHostPort(address)
				if e != nil {
					return Status{}, fmt.Errorf("non-TCP SOCKS listener %q", address)
				}
				if !strings.EqualFold(host, "localhost") && net.ParseIP(host) == nil {
					return Status{}, fmt.Errorf("non-IP SOCKS listener %q", address)
				}
				n, e := strconv.Atoi(port)
				if e != nil || n < 1 || n > 65535 {
					return Status{}, fmt.Errorf("invalid SOCKS listener port %q", address)
				}
			}
			s.SocksListeners = listeners
		}
	}
	for _, key := range []string{"version", "bootstrap", "listeners"} {
		if !seen[key] {
			return Status{}, fmt.Errorf("status response omitted %s", key)
		}
	}
	s.Ready = s.Progress == 100 && len(s.SocksListeners) > 0
	return s, nil
}

func writeCommand(w io.Writer, command string) error {
	_, err := io.WriteString(w, command+"\r\n")
	return err
}

func readReply(r *bufio.Reader) ([]string, error) {
	const maxBytes = 4 << 20
	const maxLines = 4096
	var lines []string
	code := ""
	total := 0
	count := 0
	read := func() (string, error) {
		line, n, err := readLineLimited(r)
		if err != nil {
			return "", err
		}
		total += n
		count++
		if total > maxBytes {
			return "", errors.New("control reply exceeded byte limit")
		}
		if count > maxLines {
			return "", errors.New("control reply exceeded line limit")
		}
		return line, nil
	}
	for {
		line, err := read()
		if err != nil {
			return nil, err
		}
		if len(line) < 4 || !threeDigits(line[:3]) || strings.ContainsRune(line, '\x00') {
			return nil, fmt.Errorf("malformed control reply %q", line)
		}
		if code == "" {
			code = line[:3]
		}
		if line[:3] != code {
			return nil, fmt.Errorf("mixed reply codes %s and %s", code, line[:3])
		}
		lines = append(lines, line)
		switch line[3] {
		case ' ':
			if code[0] != '2' {
				return lines, fmt.Errorf("Tor control error code %s", code)
			}
			return lines, nil
		case '-':
		case '+':
			for {
				data, err := read()
				if err != nil {
					return nil, err
				}
				if data == "." {
					break
				}
				if strings.HasPrefix(data, "..") {
					data = data[1:]
				}
				if strings.ContainsRune(data, '\x00') {
					return nil, errors.New("control data contained NUL")
				}
				lines = append(lines, data)
			}
		default:
			return nil, fmt.Errorf("unknown reply separator in %q", line)
		}
	}
}

func readLineLimited(r *bufio.Reader) (string, int, error) {
	const maxLine = 1 << 20
	buf := make([]byte, 0, 4096)
	wire := 0
	for {
		part, err := r.ReadSlice('\n')
		wire += len(part)
		if len(buf)+len(part) > maxLine {
			return "", wire, errors.New("control reply line exceeded byte limit")
		}
		buf = append(buf, part...)
		if err == nil {
			break
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return "", wire, err
		}
	}
	if len(buf) < 2 || buf[len(buf)-2] != '\r' || buf[len(buf)-1] != '\n' {
		return "", wire, errors.New("control reply line must end with CRLF")
	}
	return string(buf[:len(buf)-2]), wire, nil
}
func threeDigits(s string) bool {
	return len(s) == 3 && s[0] >= '0' && s[0] <= '9' && s[1] >= '0' && s[1] <= '9' && s[2] >= '0' && s[2] <= '9'
}

func parseProtocolInfo(lines []string) (map[string]bool, string, error) {
	methods := map[string]bool{}
	cookie := ""
	seenAuth := false
	for _, line := range lines {
		body := stripCode(line)
		if !strings.HasPrefix(body, "AUTH ") {
			continue
		}
		if seenAuth {
			return nil, "", errors.New("duplicate AUTH line")
		}
		seenAuth = true
		fields := strings.Fields(body)
		for _, field := range fields[1:] {
			if strings.HasPrefix(field, "METHODS=") {
				for _, method := range strings.Split(strings.TrimPrefix(field, "METHODS="), ",") {
					if method != "" {
						methods[method] = true
					}
				}
			}
			if strings.HasPrefix(field, "COOKIEFILE=") {
				raw := strings.TrimPrefix(field, "COOKIEFILE=")
				value, err := strconv.Unquote(raw)
				if err != nil {
					return nil, "", fmt.Errorf("invalid quoted COOKIEFILE: %w", err)
				}
				cookie = value
			}
		}
	}
	if !seenAuth {
		return nil, "", errors.New("PROTOCOLINFO omitted AUTH line")
	}
	return methods, cookie, nil
}

func parseChallenge(lines []string) ([]byte, []byte, error) {
	for _, line := range lines {
		body := stripCode(line)
		if !strings.HasPrefix(body, "AUTHCHALLENGE ") {
			continue
		}
		sh := parseField(body, "SERVERHASH")
		sn := parseField(body, "SERVERNONCE")
		serverHash, err := hex.DecodeString(sh)
		if err != nil || len(serverHash) != 32 {
			return nil, nil, errors.New("invalid SERVERHASH")
		}
		serverNonce, err := hex.DecodeString(sn)
		if err != nil || len(serverNonce) != 32 {
			return nil, nil, errors.New("invalid SERVERNONCE")
		}
		return serverHash, serverNonce, nil
	}
	return nil, nil, errors.New("missing AUTHCHALLENGE response")
}

func readCookieFile(path string) ([]byte, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("stat control cookie: %w", err)
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return nil, errors.New("control cookie must be a regular non-symlink file")
	}
	if before.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("control cookie permissions too open: %04o", before.Mode().Perm())
	}
	f, err := openCookieNoFollow(path)
	if err != nil {
		return nil, fmt.Errorf("open control cookie without symlink following: %w", err)
	}
	defer f.Close()
	after, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !after.Mode().IsRegular() || !os.SameFile(before, after) {
		return nil, errors.New("control cookie changed while opening")
	}
	if !fileOwnedByCurrentUser(after) {
		return nil, errors.New("control cookie is not owned by current user")
	}
	if after.Size() != 32 {
		return nil, fmt.Errorf("control cookie must be exactly 32 bytes, got %d", after.Size())
	}
	cookie, err := io.ReadAll(io.LimitReader(f, 33))
	if err != nil {
		return nil, err
	}
	if len(cookie) != 32 {
		return nil, fmt.Errorf("control cookie changed while reading; got %d bytes", len(cookie))
	}
	return cookie, nil
}

func hmacSHA256(key, data []byte) []byte {
	m := hmac.New(sha256.New, key)
	_, _ = m.Write(data)
	return m.Sum(nil)
}
func stripCode(line string) string {
	if len(line) >= 4 && threeDigits(line[:3]) {
		return line[4:]
	}
	return line
}

func parseField(s, key string) string {
	re := regexp.MustCompile(`(?:^|\s)` + regexp.QuoteMeta(key) + `=([^\s]+)`)
	m := re.FindStringSubmatch(s)
	if len(m) == 2 {
		return strings.Trim(m[1], `"`)
	}
	return ""
}

func parseQuotedFieldStrict(s, key string) (string, error) {
	marker := key + `="`
	i := strings.Index(s, marker)
	if i < 0 {
		return "", fmt.Errorf("missing quoted %s", key)
	}
	q := s[i+len(key)+1:]
	end := quotedEnd(q)
	if end > len(q) || end == len(q) && (len(q) < 2 || q[len(q)-1] != '"') {
		return "", fmt.Errorf("unterminated quoted %s", key)
	}
	value, err := strconv.Unquote(q[:end])
	if err != nil {
		return "", err
	}
	return value, nil
}
func quotedEnd(s string) int {
	escaped := false
	for i := 1; i < len(s); i++ {
		if escaped {
			escaped = false
			continue
		}
		if s[i] == '\\' {
			escaped = true
			continue
		}
		if s[i] == '"' {
			return i + 1
		}
	}
	return len(s)
}
func parseQuotedList(s string) ([]string, error) {
	var out []string
	for len(strings.TrimSpace(s)) > 0 {
		s = strings.TrimSpace(s)
		if !strings.HasPrefix(s, `"`) {
			return nil, fmt.Errorf("expected quoted listener, got %q", s)
		}
		end := quotedEnd(s)
		if end == len(s) && (len(s) < 2 || s[len(s)-1] != '"') {
			return nil, errors.New("unterminated quoted listener")
		}
		value, err := strconv.Unquote(s[:end])
		if err != nil {
			return nil, err
		}
		if value == "" || strings.ContainsAny(value, "\r\n\x00") {
			return nil, errors.New("invalid listener value")
		}
		out = append(out, value)
		s = s[end:]
	}
	return out, nil
}
