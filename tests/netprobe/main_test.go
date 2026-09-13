package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

func TestProbeExpectedSuccess(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if err := probe(ln.Addr().String(), time.Second, "success"); err != nil {
		t.Fatal(err)
	}
}

func TestProbeExpectedFailure(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := ln.Addr().String()
	_ = ln.Close()
	if err := probe(address, 100*time.Millisecond, "failure"); err != nil {
		t.Fatal(err)
	}
}

func TestProbeReportsExpectationMismatch(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if err := probe(ln.Addr().String(), time.Second, "failure"); err == nil || !strings.Contains(err.Error(), "unexpected connection success") {
		t.Fatalf("err=%v", err)
	}
}
