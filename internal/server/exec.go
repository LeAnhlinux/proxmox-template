package server

import "os/exec"

// execCommand is a thin wrapper around os/exec for testability
func execCommand(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}
