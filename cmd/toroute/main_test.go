package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

func capture(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	err := fn()
	w.Close()
	os.Stdout = old
	b, _ := io.ReadAll(r)
	return string(b), err
}
func TestHelpHasNoSideEffect(t *testing.T) {
	for _, args := range [][]string{{"run", "--help"}, {"check-config", "--help"}, {"newnym", "--help"}, {"print-config", "--help"}, {"status", "--help"}, {"exec", "--help"}} {
		out, err := capture(t, func() error { return run(args) })
		if err != nil || !strings.Contains(out, "Usage:") {
			t.Fatalf("%v %q %v", args, out, err)
		}
	}
}
func TestRejectTrailingArgs(t *testing.T) {
	for _, args := range [][]string{{"run", "x"}, {"version", "x"}, {"print-config", "x"}, {"status", "x"}, {"help", "x"}} {
		if err := run(args); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}
func TestPrintConfigJSON(t *testing.T) {
	out, err := capture(t, func() error { return run([]string{"print-config", "--format", "json"}) })
	if err != nil || !strings.Contains(out, `"socks_address"`) {
		t.Fatalf("%q %v", out, err)
	}
}
func TestCompatRejectsDangerousAndOverwrite(t *testing.T) {
	if err := run([]string{"compat", "dperson", "-e"}); err == nil {
		t.Fatal("-e accepted")
	}
	t.Setenv("TOROUTE_EXIT_COUNTRIES", "jp")
	if err := run([]string{"compat", "dperson", "-l", "us"}); err == nil {
		t.Fatal("overwrite accepted")
	}
}
func TestBasicCommandErrorsAndVersion(t *testing.T) {
	for _, args := range [][]string{{"unknown"}, {"exec"}, {"print-config", "--format", "bad"}, {"compat"}} {
		if err := run(args); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
	out, err := capture(t, func() error { return run([]string{"version"}) })
	if err != nil || !strings.Contains(out, "toroute dev") {
		t.Fatalf("out=%q err=%v", out, err)
	}
	out, err = capture(t, func() error { return run([]string{"help"}) })
	if err != nil || !strings.Contains(out, "toroute healthcheck") {
		t.Fatalf("out=%q err=%v", out, err)
	}
}

func TestPrivoxyConfigRequiresExplicitEnable(t *testing.T) {
	if err := run([]string{"print-config", "--format", "privoxy"}); err == nil {
		t.Fatal("Privoxy config printed while HTTP adapter was disabled")
	}
}
