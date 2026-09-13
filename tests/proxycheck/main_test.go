package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func readConnectRequest(r *bufio.Reader) (string, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(r, header); err != nil {
		return "", err
	}
	if header[0] != 0x05 || header[1] != 0x01 || header[2] != 0x00 {
		return "", fmt.Errorf("invalid CONNECT request %x", header)
	}
	var host string
	switch header[3] {
	case 0x01:
		buf := make([]byte, 4)
		if _, err := io.ReadFull(r, buf); err != nil {
			return "", err
		}
		host = net.IP(buf).String()
	case 0x04:
		buf := make([]byte, 16)
		if _, err := io.ReadFull(r, buf); err != nil {
			return "", err
		}
		host = net.IP(buf).String()
	case 0x03:
		length, err := r.ReadByte()
		if err != nil {
			return "", err
		}
		buf := make([]byte, int(length))
		if _, err := io.ReadFull(r, buf); err != nil {
			return "", err
		}
		host = string(buf)
	default:
		return "", fmt.Errorf("unknown address type %d", header[3])
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(r, portBytes); err != nil {
		return "", err
	}
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(portBytes)))), nil
}

func TestSOCKSConnectRequestUsesDomainName(t *testing.T) {
	request, err := socksConnectRequest("check.torproject.org:443")
	if err != nil {
		t.Fatal(err)
	}
	address, err := readConnectRequest(bufio.NewReader(bytes.NewReader(request)))
	if err != nil {
		t.Fatal(err)
	}
	if address != "check.torproject.org:443" {
		t.Fatalf("address=%q", address)
	}
	if request[3] != 0x03 {
		t.Fatalf("expected domain-name address type, got %d", request[3])
	}
}

func TestSOCKSConnectRequestSupportsIPv4AndIPv6(t *testing.T) {
	for _, address := range []string{"127.0.0.1:80", "[2001:db8::1]:443"} {
		request, err := socksConnectRequest(address)
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := readConnectRequest(bufio.NewReader(bytes.NewReader(request)))
		if err != nil {
			t.Fatal(err)
		}
		if decoded != address {
			t.Fatalf("decoded=%q want=%q", decoded, address)
		}
	}
}

func TestReadSOCKS5Reply(t *testing.T) {
	good := []byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x23, 0x28}
	if err := readSOCKS5Reply(bytes.NewReader(good)); err != nil {
		t.Fatal(err)
	}
	bad := append([]byte(nil), good...)
	bad[1] = 0x05
	if err := readSOCKS5Reply(bytes.NewReader(bad)); err == nil || !strings.Contains(err.Error(), "failed") {
		t.Fatalf("err=%v", err)
	}
}

func TestDialSOCKS5CompletesHandshake(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	serverErr := make(chan error, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer conn.Close()
		greeting := make([]byte, 3)
		if _, err := io.ReadFull(conn, greeting); err != nil {
			serverErr <- err
			return
		}
		if !bytes.Equal(greeting, []byte{0x05, 0x01, 0x00}) {
			serverErr <- io.ErrUnexpectedEOF
			return
		}
		if _, err := conn.Write([]byte{0x05, 0x00}); err != nil {
			serverErr <- err
			return
		}
		address, err := readConnectRequest(bufio.NewReader(conn))
		if err != nil {
			serverErr <- err
			return
		}
		if address != "example.com:443" {
			serverErr <- io.ErrUnexpectedEOF
			return
		}
		reply := []byte{0x05, 0x00, 0x00, 0x03, byte(len("bound.invalid"))}
		reply = append(reply, "bound.invalid"...)
		var port [2]byte
		binary.BigEndian.PutUint16(port[:], 12345)
		reply = append(reply, port[:]...)
		_, err = conn.Write(reply)
		serverErr <- err
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := dialSOCKS5(ctx, ln.Addr().String(), "example.com:443")
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	if err := <-serverErr; err != nil {
		t.Fatal(err)
	}
}

func TestValidation(t *testing.T) {
	for _, address := range []string{"", "host", "host:0", "host:65536", "\n:80"} {
		if err := validateEndpoint(address); err == nil {
			t.Fatalf("accepted %q", address)
		}
	}
	if err := validateEndpoint("toroute:9050"); err != nil {
		t.Fatal(err)
	}
}

func TestHTTPSRequestThroughSOCKS5AndHTTPConnect(t *testing.T) {
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"IsTor":true,"IP":"203.0.113.10"}`)
	}))
	defer target.Close()
	tlsConfig := target.Client().Transport.(*http.Transport).TLSClientConfig.Clone()

	for _, mode := range []string{"socks5", "http"} {
		t.Run(mode, func(t *testing.T) {
			proxyAddress, stop := startTestProxy(t, mode)
			defer stop()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			out, err := runWithTLSConfig(ctx, options{
				ProxyMode: mode, ProxyAddress: proxyAddress, TargetURL: target.URL,
				ExpectTor: true, Timeout: 3 * time.Second,
			}, tlsConfig)
			if err != nil {
				t.Fatal(err)
			}
			if out.IsTor == nil || !*out.IsTor || out.ExitIP != "203.0.113.10" || !out.RemoteDNS {
				t.Fatalf("out=%+v", out)
			}
		})
	}
}

func startTestProxy(t *testing.T, mode string) (string, func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var targetAddress string
		reader := bufio.NewReader(conn)
		switch mode {
		case "socks5":
			greeting := make([]byte, 3)
			if _, err := io.ReadFull(reader, greeting); err != nil || !bytes.Equal(greeting, []byte{0x05, 0x01, 0x00}) {
				return
			}
			if _, err := conn.Write([]byte{0x05, 0x00}); err != nil {
				return
			}
			targetAddress, err = readConnectRequest(reader)
			if err != nil {
				return
			}
		case "http":
			req, err := http.ReadRequest(reader)
			if err != nil || req.Method != http.MethodConnect {
				return
			}
			targetAddress = req.Host
		default:
			return
		}
		upstream, err := net.DialTimeout("tcp", targetAddress, time.Second)
		if err != nil {
			return
		}
		defer upstream.Close()
		if mode == "socks5" {
			_, _ = conn.Write([]byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0})
		} else {
			_, _ = io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
		}
		copyDone := make(chan struct{}, 2)
		go func() { _, _ = io.Copy(upstream, reader); copyDone <- struct{}{} }()
		go func() { _, _ = io.Copy(conn, upstream); copyDone <- struct{}{} }()
		<-copyDone
	}()
	return ln.Addr().String(), func() {
		_ = ln.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
		}
	}
}
