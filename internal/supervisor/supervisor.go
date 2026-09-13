package supervisor

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/kabumatome/toroute/internal/config"
	hruntime "github.com/kabumatome/toroute/internal/runtime"
)

const forceReapTimeout = 2 * time.Second

type child struct {
	name string
	cmd  *exec.Cmd
}
type childResult struct {
	index int
	err   error
}

func Run(cfg config.Config) error {
	if err := hruntime.Prepare(cfg); err != nil {
		return err
	}
	if err := hruntime.Verify(cfg); err != nil {
		return err
	}
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	children := []child{{name: "tor", cmd: newChildCommand(cfg.TorBinary, "-f", cfg.TorrcPath())}}
	children[0].cmd.Stdout, children[0].cmd.Stderr = os.Stdout, os.Stderr
	if err := children[0].cmd.Start(); err != nil {
		return fmt.Errorf("start Tor: %w", err)
	}
	if cfg.HTTPEnabled {
		p := child{name: "privoxy", cmd: newChildCommand(cfg.PrivoxyBinary, "--no-daemon", cfg.PrivoxyConfigPath())}
		p.cmd.Stdout, p.cmd.Stderr = os.Stdout, os.Stderr
		if err := p.cmd.Start(); err != nil {
			if stopErr := terminateStarted(children[0].cmd, cfg.ShutdownTimeout); stopErr != nil {
				return fmt.Errorf("start Privoxy: %w; additionally failed to stop Tor: %v", err, stopErr)
			}
			return fmt.Errorf("start Privoxy: %w", err)
		}
		children = append(children, p)
	}
	results := make(chan childResult, len(children))
	for i := range children {
		go func(index int) { results <- childResult{index: index, err: children[index].cmd.Wait()} }(i)
	}
	exited := make([]bool, len(children))
	remaining := len(children)
	var first childResult
	signaled := false
	select {
	case sig := <-signals:
		signaled = true
		signalChildren(children, exited, sig)
	case first = <-results:
		exited[first.index] = true
		remaining--
		signalChildren(children, exited, syscall.SIGTERM)
	}
	grace := time.NewTimer(cfg.ShutdownTimeout)
	defer grace.Stop()
	for remaining > 0 {
		select {
		case result := <-results:
			if !exited[result.index] {
				exited[result.index] = true
				remaining--
			}
		case <-signals:
			signalChildren(children, exited, syscall.SIGKILL)
		case <-grace.C:
			signalChildren(children, exited, syscall.SIGKILL)
			if !waitForChildren(results, exited, &remaining, forceReapTimeout) {
				return errors.New("child processes could not be reaped after SIGKILL")
			}
			if signaled {
				return nil
			}
			return errors.New("child processes did not stop before shutdown timeout")
		}
	}
	if signaled {
		return nil
	}
	name := children[first.index].name
	if first.err == nil {
		return fmt.Errorf("%s exited unexpectedly with status 0", name)
	}
	var exitErr *exec.ExitError
	if errors.As(first.err, &exitErr) {
		return fmt.Errorf("%s exited: %w", name, exitErr)
	}
	return fmt.Errorf("%s failed: %w", name, first.err)
}
func newChildCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	configureProcessGroup(cmd)
	return cmd
}
func signalChildren(children []child, exited []bool, sig os.Signal) {
	for i := range children {
		if !exited[i] {
			_ = signalProcessGroup(children[i].cmd, sig)
		}
	}
}
func waitForChildren(results <-chan childResult, exited []bool, remaining *int, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for *remaining > 0 {
		select {
		case result := <-results:
			if !exited[result.index] {
				exited[result.index] = true
				*remaining--
			}
		case <-timer.C:
			return false
		}
	}
	return true
}
func terminateStarted(cmd *exec.Cmd, timeout time.Duration) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	_ = signalProcessGroup(cmd, syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
		return nil
	case <-timer.C:
	}
	if err := signalProcessGroup(cmd, syscall.SIGKILL); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	select {
	case <-done:
		return errors.New("process required SIGKILL after shutdown timeout")
	case <-time.After(forceReapTimeout):
		return errors.New("process could not be reaped after SIGKILL")
	}
}
