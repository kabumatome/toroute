package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const maxResponseBytes = 1 << 20

type options struct {
	ProxyMode    string
	ProxyAddress string
	TargetURL    string
	ExpectTor    bool
	Timeout      time.Duration
}

type result struct {
	SchemaVersion  int    `json:"schema_version"`
	ProxyMode      string `json:"proxy_mode"`
	ProxyAddress   string `json:"proxy_address"`
	TargetURL      string `json:"target_url"`
	StatusCode     int    `json:"status_code"`
	IsTor          *bool  `json:"is_tor,omitempty"`
	ExitIP         string `json:"exit_ip,omitempty"`
	ElapsedMillis  int64  `json:"elapsed_milliseconds"`
	RemoteDNS      bool   `json:"remote_dns"`
	ResponseLength int    `json:"response_length"`
}

type torCheckResponse struct {
	IsTor bool   `json:"IsTor"`
	IP    string `json:"IP"`
}

func main() {
	cfg := options{}
	flag.StringVar(&cfg.ProxyMode, "proxy", "socks5", "proxy mode: socks5 or http")
	flag.StringVar(&cfg.ProxyAddress, "proxy-address", "toroute:9050", "proxy host:port")
	flag.StringVar(&cfg.TargetURL, "url", "https://check.torproject.org/api/ip", "HTTPS URL to request")
	flag.BoolVar(&cfg.ExpectTor, "expect-tor", true, "require the Tor check API to report IsTor=true")
	flag.DurationVar(&cfg.Timeout, "timeout", 75*time.Second, "overall request timeout")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "proxycheck does not accept positional arguments")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), cfg.Timeout)
	defer cancel()
	out, err := run(ctx, cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "proxycheck:", err)
		os.Exit(1)
	}
	encoded, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "proxycheck: encode result:", err)
		os.Exit(1)
	}
	fmt.Println(string(encoded))
}

func run(ctx context.Context, cfg options) (result, error) {
	return runWithTLSConfig(ctx, cfg, nil)
}

func runWithTLSConfig(ctx context.Context, cfg options, tlsConfig *tls.Config) (result, error) {
	if cfg.Timeout <= 0 || cfg.Timeout > 10*time.Minute {
		return result{}, errors.New("timeout must be greater than zero and at most 10 minutes")
	}
	if err := validateEndpoint(cfg.ProxyAddress); err != nil {
		return result{}, fmt.Errorf("proxy address: %w", err)
	}
	target, err := url.Parse(cfg.TargetURL)
	if err != nil {
		return result{}, fmt.Errorf("parse target URL: %w", err)
	}
	if target.Scheme != "https" || target.Hostname() == "" || target.User != nil || target.Fragment != "" {
		return result{}, errors.New("target URL must be an absolute HTTPS URL without credentials or fragment")
	}

	if tlsConfig == nil {
		tlsConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	} else {
		tlsConfig = tlsConfig.Clone()
		if tlsConfig.MinVersion < tls.VersionTLS12 {
			tlsConfig.MinVersion = tls.VersionTLS12
		}
	}
	transport := &http.Transport{
		DisableCompression:  false,
		DisableKeepAlives:   true,
		ForceAttemptHTTP2:   false,
		TLSHandshakeTimeout: 30 * time.Second,
		TLSClientConfig:     tlsConfig,
	}
	remoteDNS := false
	switch cfg.ProxyMode {
	case "socks5":
		remoteDNS = true
		transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
			if network != "tcp" && network != "tcp4" && network != "tcp6" {
				return nil, fmt.Errorf("unsupported network %q", network)
			}
			return dialSOCKS5(ctx, cfg.ProxyAddress, address)
		}
	case "http":
		remoteDNS = true
		proxyURL := &url.URL{Scheme: "http", Host: cfg.ProxyAddress}
		transport.Proxy = http.ProxyURL(proxyURL)
	case "":
		return result{}, errors.New("proxy mode must not be empty")
	default:
		return result{}, fmt.Errorf("unsupported proxy mode %q", cfg.ProxyMode)
	}
	defer transport.CloseIdleConnections()

	client := &http.Client{
		Transport: transport,
		Timeout:   cfg.Timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return errors.New("too many redirects")
			}
			if req.URL.Scheme != "https" {
				return errors.New("redirected to a non-HTTPS URL")
			}
			return nil
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return result{}, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Accept", "application/json,text/plain;q=0.9,*/*;q=0.1")
	req.Header.Set("User-Agent", "ToRoute-proxycheck/1")

	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return result{}, fmt.Errorf("request through %s proxy: %w", cfg.ProxyMode, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil {
		return result{}, fmt.Errorf("read response: %w", err)
	}
	if len(body) > maxResponseBytes {
		return result{}, fmt.Errorf("response exceeded %d bytes", maxResponseBytes)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return result{}, fmt.Errorf("unexpected HTTP status %s", resp.Status)
	}

	out := result{
		SchemaVersion:  1,
		ProxyMode:      cfg.ProxyMode,
		ProxyAddress:   cfg.ProxyAddress,
		TargetURL:      target.String(),
		StatusCode:     resp.StatusCode,
		ElapsedMillis:  time.Since(started).Milliseconds(),
		RemoteDNS:      remoteDNS,
		ResponseLength: len(body),
	}
	if cfg.ExpectTor {
		var check torCheckResponse
		if err := json.Unmarshal(body, &check); err != nil {
			return result{}, fmt.Errorf("decode Tor check response: %w", err)
		}
		if !check.IsTor {
			return result{}, fmt.Errorf("Tor check reported IsTor=false (IP=%q)", check.IP)
		}
		if net.ParseIP(check.IP) == nil {
			return result{}, fmt.Errorf("Tor check returned invalid IP %q", check.IP)
		}
		out.IsTor = &check.IsTor
		out.ExitIP = check.IP
	}
	return out, nil
}

func validateEndpoint(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if host == "" || strings.ContainsAny(host, "\r\n\x00") {
		return errors.New("host must not be empty or contain control characters")
	}
	value, err := strconv.Atoi(port)
	if err != nil || value < 1 || value > 65535 {
		return errors.New("port must be 1..65535")
	}
	return nil
}

func dialSOCKS5(ctx context.Context, proxyAddress, targetAddress string) (net.Conn, error) {
	if err := validateEndpoint(targetAddress); err != nil {
		return nil, fmt.Errorf("target address: %w", err)
	}
	dialer := net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", proxyAddress)
	if err != nil {
		return nil, fmt.Errorf("connect to SOCKS5 proxy: %w", err)
	}
	ok := false
	defer func() {
		if !ok {
			_ = conn.Close()
		}
	}()
	if deadline, exists := ctx.Deadline(); exists {
		_ = conn.SetDeadline(deadline)
	}
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		return nil, fmt.Errorf("write SOCKS5 greeting: %w", err)
	}
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(conn, greeting); err != nil {
		return nil, fmt.Errorf("read SOCKS5 greeting: %w", err)
	}
	if greeting[0] != 0x05 || greeting[1] != 0x00 {
		return nil, fmt.Errorf("SOCKS5 proxy rejected no-auth method: %x", greeting)
	}
	request, err := socksConnectRequest(targetAddress)
	if err != nil {
		return nil, err
	}
	if _, err := conn.Write(request); err != nil {
		return nil, fmt.Errorf("write SOCKS5 CONNECT: %w", err)
	}
	if err := readSOCKS5Reply(conn); err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	ok = true
	return conn, nil
}

func socksConnectRequest(address string) ([]byte, error) {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("split target address: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, errors.New("invalid target port")
	}
	request := []byte{0x05, 0x01, 0x00}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			request = append(request, 0x01)
			request = append(request, v4...)
		} else {
			request = append(request, 0x04)
			request = append(request, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return nil, errors.New("target hostname exceeds 255 bytes")
		}
		request = append(request, 0x03, byte(len(host)))
		request = append(request, host...)
	}
	var portBytes [2]byte
	binary.BigEndian.PutUint16(portBytes[:], uint16(port))
	request = append(request, portBytes[:]...)
	return request, nil
}

func readSOCKS5Reply(r io.Reader) error {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return fmt.Errorf("read SOCKS5 reply header: %w", err)
	}
	if header[0] != 0x05 || header[2] != 0x00 {
		return fmt.Errorf("malformed SOCKS5 reply header: %x", header)
	}
	if header[1] != 0x00 {
		return fmt.Errorf("SOCKS5 CONNECT failed with status 0x%02x", header[1])
	}
	var addressLength int
	switch header[3] {
	case 0x01:
		addressLength = net.IPv4len
	case 0x04:
		addressLength = net.IPv6len
	case 0x03:
		length := []byte{0}
		if _, err := io.ReadFull(r, length); err != nil {
			return fmt.Errorf("read SOCKS5 domain length: %w", err)
		}
		addressLength = int(length[0])
	default:
		return fmt.Errorf("unknown SOCKS5 address type 0x%02x", header[3])
	}
	if addressLength == 0 {
		return errors.New("SOCKS5 reply contained an empty address")
	}
	remaining := make([]byte, addressLength+2)
	if _, err := io.ReadFull(r, remaining); err != nil {
		return fmt.Errorf("read SOCKS5 bound address: %w", err)
	}
	return nil
}
