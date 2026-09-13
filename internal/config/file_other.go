//go:build !linux

package config

import "os"

func openFileNoFollow(path string) (*os.File, error) { return os.Open(path) }
func fileOwnedByCurrentUser(os.FileInfo) bool        { return true }
