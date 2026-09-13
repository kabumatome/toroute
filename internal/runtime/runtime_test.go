package runtime

import (
	"context"
	"github.com/kabumatome/toroute/internal/config"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testCfg(t *testing.T) config.Config {
	t.Helper()
	c := config.Default()
	root := t.TempDir()
	c.DataDir = filepath.Join(root, "data")
	c.RuntimeDir = filepath.Join(root, "run")
	return c
}
func TestPrepare(t *testing.T) {
	c := testCfg(t)
	if err := Prepare(c); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{c.TorrcPath()} {
		info, err := os.Stat(p)
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("%s %v %v", p, info, err)
		}
	}
}
func TestPrepareRejectsSymlink(t *testing.T) {
	c := testCfg(t)
	real := filepath.Join(t.TempDir(), "real")
	os.MkdirAll(real, 0700)
	os.Symlink(real, c.DataDir)
	if err := Prepare(c); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("%v", err)
	}
}
func TestRunCheckTimeoutKillsGroup(t *testing.T) {
	script := filepath.Join(t.TempDir(), "slow")
	os.WriteFile(script, []byte("#!/bin/sh\n(sleep 30) &\nwait\n"), 0700)
	start := time.Now()
	err := runCheckWithTimeout(50*time.Millisecond, script)
	if err == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("err=%v elapsed=%s", err, time.Since(start))
	}
}
func TestLimitedBufferConcurrent(t *testing.T) {
	b := &limitedBuffer{maximum: 100}
	done := make(chan struct{})
	for i := 0; i < 8; i++ {
		go func() {
			for j := 0; j < 100; j++ {
				b.Write([]byte("abcdef"))
			}
			done <- struct{}{}
		}()
	}
	for i := 0; i < 8; i++ {
		<-done
	}
	if len(b.String()) < 100 {
		t.Fatalf("%d", len(b.String()))
	}
}
func TestSanitize(t *testing.T) {
	got := sanitizeVerificationOutput("ok\nBridge obfs4 secret cert=x\n\x1b[31mbad\r")
	if strings.Contains(got, "secret") || strings.ContainsRune(got, 0x1b) {
		t.Fatal(got)
	}
}
func TestRunCheckCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := runCheck(ctx, "/bin/true"); err == nil {
		t.Fatal("expected canceled")
	}
}

func TestPrepareRejectsParentSymlink(t *testing.T) {
	root := t.TempDir()
	realParent := filepath.Join(root, "real")
	linkParent := filepath.Join(root, "link")
	if err := os.MkdirAll(realParent, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realParent, linkParent); err != nil {
		t.Fatal(err)
	}
	cfg := testCfg(t)
	cfg.DataDir = filepath.Join(linkParent, "data")
	if err := Prepare(cfg); err == nil || !strings.Contains(err.Error(), "symlink path component") {
		t.Fatalf("err=%v", err)
	}
}

func TestCheckConfigUsesRuntimeDirInsteadOfSystemTemp(t *testing.T) {
	cfg := testCfg(t)
	if err := os.MkdirAll(cfg.RuntimeDir, 0700); err != nil {
		t.Fatal(err)
	}
	sentinel := cfg.ControlSocketPath()
	if err := os.WriteFile(sentinel, []byte("live-control-sentinel"), 0600); err != nil {
		t.Fatal(err)
	}
	validator := filepath.Join(t.TempDir(), "tor-validator")
	if err := os.WriteFile(validator, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	cfg.TorBinary = validator
	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), "missing-system-temp"))

	if err := CheckConfig(cfg); err != nil {
		t.Fatalf("check-config should use the configured runtime directory: %v", err)
	}
	got, err := os.ReadFile(sentinel)
	if err != nil {
		t.Fatalf("live runtime sentinel was removed: %v", err)
	}
	if string(got) != "live-control-sentinel" {
		t.Fatalf("live runtime sentinel changed: %q", got)
	}
	entries, err := os.ReadDir(cfg.RuntimeDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".check-") {
			t.Fatalf("temporary check workspace was not removed: %s", entry.Name())
		}
	}
}
