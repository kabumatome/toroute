//go:build !linux

package control

import "os"

func openCookieNoFollow(path string) (*os.File, error) { return os.Open(path) }
func fileOwnedByCurrentUser(os.FileInfo) bool          { return true }
