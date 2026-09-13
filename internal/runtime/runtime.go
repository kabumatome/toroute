package runtime

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/kabumatome/toroute/internal/config"
	"github.com/kabumatome/toroute/internal/render"
)

func Prepare(cfg config.Config) error {
	for _, dir := range []string{cfg.DataDir, cfg.RuntimeDir} {
		if err := ensureSecureDirectory(dir); err != nil {
			return err
		}
		f, err := os.CreateTemp(dir, ".write-test-*")
		if err != nil {
			return fmt.Errorf("%s is not writable by uid %d: %w", dir, os.Geteuid(), err)
		}
		name := f.Name()
		_ = f.Close()
		_ = os.Remove(name)
	}
	for _, path := range []string{cfg.ControlSocketPath(), cfg.CookiePath(), cfg.TorPIDPath(), cfg.TorrcPath(), cfg.PrivoxyConfigPath()} {
		_ = os.Remove(path)
	}
	torrc, err := render.Torrc(cfg)
	if err != nil {
		return err
	}
	if err := render.WriteAtomic(cfg.TorrcPath(), []byte(torrc), 0600); err != nil {
		return fmt.Errorf("write torrc: %w", err)
	}
	if cfg.HTTPEnabled {
		if err := render.WriteAtomic(cfg.PrivoxyConfigPath(), []byte(render.Privoxy(cfg)), 0600); err != nil {
			return fmt.Errorf("write Privoxy config: %w", err)
		}
	}
	return nil
}

func CheckConfig(cfg config.Config) error {
	// Configuration checks must work with a read-only root filesystem. The
	// configured runtime directory is the explicitly writable tmpfs used by the
	// hardened container profile, whereas os.MkdirTemp("", ...) would fall back
	// to /tmp and fail under read_only=true.
	if err := ensureSecureDirectory(cfg.RuntimeDir); err != nil {
		return fmt.Errorf("prepare configuration-check runtime directory: %w", err)
	}
	base, err := os.MkdirTemp(cfg.RuntimeDir, ".check-*")
	if err != nil {
		return fmt.Errorf("create configuration-check workspace in %s: %w", cfg.RuntimeDir, err)
	}
	defer os.RemoveAll(base)
	copy := cfg
	copy.DataDir = filepath.Join(base, "data")
	copy.RuntimeDir = filepath.Join(base, "run")
	if err := Prepare(copy); err != nil {
		return err
	}
	return Verify(copy)
}

func Verify(cfg config.Config) error {
	if err := runCheckWithTimeout(cfg.ConfigVerifyTimeout, cfg.TorBinary, "--verify-config", "-f", cfg.TorrcPath()); err != nil {
		return fmt.Errorf("Tor configuration failed verification: %w", err)
	}
	if cfg.HTTPEnabled {
		if err := runCheckWithTimeout(cfg.ConfigVerifyTimeout, cfg.PrivoxyBinary, "--config-test", cfg.PrivoxyConfigPath()); err != nil {
			return fmt.Errorf("Privoxy configuration failed verification: %w", err)
		}
	}
	return nil
}

func ensureSecureDirectory(path string) error {
	if err := rejectSymlinkComponents(path); err != nil {
		return err
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	if err := rejectSymlinkComponents(path); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing symlink directory %s", path)
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	if err := os.Chmod(path, 0700); err != nil {
		return fmt.Errorf("secure permissions on %s: %w", path, err)
	}
	return nil
}

func rejectSymlinkComponents(path string) error {
	clean := filepath.Clean(path)
	current := string(filepath.Separator)
	for _, component := range strings.Split(strings.TrimPrefix(clean, string(filepath.Separator)), string(filepath.Separator)) {
		if component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect path component %s: %w", current, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing symlink path component %s", current)
		}
		if !info.IsDir() && current != clean {
			return fmt.Errorf("path component %s is not a directory", current)
		}
	}
	return nil
}

func runCheckWithTimeout(timeout time.Duration, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return runCheck(ctx, name, args...)
}
func runCheck(ctx context.Context, name string, args ...string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	cmd := exec.Command(name, args...)
	configureProcessGroup(cmd)
	output := &limitedBuffer{maximum: 256 << 10}
	cmd.Stdout = output
	cmd.Stderr = output
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return formatCheckResult(err, output)
	case <-ctx.Done():
	}
	_ = signalProcessGroup(cmd, terminateSignal)
	select {
	case <-done:
		return fmt.Errorf("timed out after configuration verification deadline: %w", ctx.Err())
	case <-time.After(250 * time.Millisecond):
	}
	_ = signalProcessGroup(cmd, killSignal)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		return fmt.Errorf("validator process could not be reaped after SIGKILL: %w", ctx.Err())
	}
	return fmt.Errorf("timed out after configuration verification deadline: %w", ctx.Err())
}
func formatCheckResult(err error, output *limitedBuffer) error {
	if err == nil {
		return nil
	}
	message := sanitizeVerificationOutput(output.String())
	if message != "" {
		return fmt.Errorf("%w: %s", err, message)
	}
	return err
}

type limitedBuffer struct {
	mu        sync.Mutex
	buffer    bytes.Buffer
	maximum   int
	truncated bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	original := len(p)
	remaining := b.maximum - b.buffer.Len()
	if remaining > 0 {
		if len(p) > remaining {
			p = p[:remaining]
			b.truncated = true
		}
		_, _ = b.buffer.Write(p)
	} else if len(p) > 0 {
		b.truncated = true
	}
	return original, nil
}
func (b *limitedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	v := b.buffer.String()
	if b.truncated {
		v += "\n[verification output truncated]"
	}
	return v
}

func sanitizeVerificationOutput(value string) string {
	value = strings.Map(func(r rune) rune {
		switch r {
		case '\n', '\t':
			return r
		case '\r', 0x1b:
			return -1
		default:
			if r < 0x20 || r == 0x7f {
				return -1
			}
			return r
		}
	}, value)
	lines := strings.Split(strings.TrimSpace(value), "\n")
	out := make([]string, 0, len(lines))
	redacted := false
	for _, line := range lines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "bridge ") || strings.Contains(lower, "cert=") {
			if !redacted {
				out = append(out, "[bridge configuration details redacted]")
				redacted = true
			}
			continue
		}
		redacted = false
		out = append(out, line)
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}
