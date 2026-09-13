package supervisor

import (
	"github.com/kabumatome/toroute/internal/config"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func script(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "script")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0700); err != nil {
		t.Fatal(err)
	}
	return p
}
func baseCfg(t *testing.T) config.Config {
	c := config.Default()
	root := t.TempDir()
	c.DataDir = filepath.Join(root, "data")
	c.RuntimeDir = filepath.Join(root, "run")
	c.ConfigVerifyTimeout = time.Second
	c.ShutdownTimeout = 200 * time.Millisecond
	return c
}
func TestUnexpectedTorExit(t *testing.T) {
	c := baseCfg(t)
	c.TorBinary = script(t, `if [ "$1" = "--verify-config" ]; then exit 0; fi
exit 0
`)
	err := Run(c)
	if err == nil || !strings.Contains(err.Error(), "exited unexpectedly") {
		t.Fatalf("%v", err)
	}
}
func TestPrivoxyExitStopsTor(t *testing.T) {
	c := baseCfg(t)
	c.ShutdownTimeout = 2 * time.Second
	root := t.TempDir()
	ready := filepath.Join(root, "ready")
	marker := filepath.Join(root, "stopped")
	c.TorBinary = script(t, `if [ "$1" = "--verify-config" ]; then exit 0; fi
trap 'echo yes > "`+marker+`"; exit 0' TERM
echo ready > "`+ready+`"
while :; do sleep 1; done
`)
	c.HTTPEnabled = true
	c.PrivoxyBinary = script(t, `if [ "$1" = "--config-test" ]; then exit 0; fi
while [ ! -f "`+ready+`" ]; do sleep 0.01; done
exit 7
`)
	err := Run(c)
	if err == nil || !strings.Contains(err.Error(), "privoxy") {
		t.Fatalf("%v", err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		if _, e := os.Stat(marker); e == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Tor not stopped after Privoxy exit")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestTerminateStartedBounded(t *testing.T) {
	cmd := newChildCommand(script(t, `while :; do sleep 1; done
`))
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_ = terminateStarted(cmd, 50*time.Millisecond)
	if time.Since(start) > 3*time.Second {
		t.Fatalf("elapsed=%s", time.Since(start))
	}
}
