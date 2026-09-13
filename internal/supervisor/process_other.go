//go:build !linux

package supervisor

import (
	"os"
	"os/exec"
)

func configureProcessGroup(*exec.Cmd) {}
func signalProcessGroup(cmd *exec.Cmd, signal os.Signal) error {
	if cmd == nil || cmd.Process == nil {
		return nil
	}
	return cmd.Process.Signal(signal)
}
