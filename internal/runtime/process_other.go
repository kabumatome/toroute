//go:build !linux

package runtime

import (
	"os"
	"os/exec"
)

var (
	terminateSignal os.Signal = os.Interrupt
	killSignal      os.Signal = os.Kill
)

func configureProcessGroup(*exec.Cmd) {}
func signalProcessGroup(cmd *exec.Cmd, signal os.Signal) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	return cmd.Process.Signal(signal)
}
