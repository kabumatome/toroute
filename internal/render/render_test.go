package render

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kabumatome/toroute/internal/config"
)

func cfg(t *testing.T) config.Config {
	t.Helper()
	c := config.Default()
	c.DataDir = filepath.Join(t.TempDir(), "data")
	c.RuntimeDir = filepath.Join(t.TempDir(), "run")
	return c
}

func TestTorrcSecurityBoundary(t *testing.T) {
	c := cfg(t)
	got, err := Torrc(c)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"ClientOnly 1", "SafeSocks 1", "ControlPort 0", "CookieAuthentication 1", "SafeLogging 1", "IsolateClientAddr IsolateSOCKSAuth"} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %s\n%s", want, got)
		}
	}
	for _, bad := range []string{"ORPort ", "HiddenServiceDir", "HashedControlPassword"} {
		if strings.Contains(got, bad) {
			t.Fatalf("contains %s", bad)
		}
	}
}

func TestCountryRendering(t *testing.T) {
	c := cfg(t)
	c.ExitCountries = []string{"us", "jp"}
	c.StrictExit = true
	c.ExcludeExitCountries = []string{"cn"}
	got, err := Torrc(c)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"ExitNodes {jp},{us}", "StrictNodes 1", "ExcludeExitNodes {cn}"} {
		if !strings.Contains(got, w) {
			t.Fatalf("missing %s", w)
		}
	}
}

func TestBridgeRedactionAndValidation(t *testing.T) {
	c := cfg(t)
	p := filepath.Join(t.TempDir(), "bridges")
	line := "obfs4 192.0.2.10:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=REDACT_ME iat-mode=0\n"
	if err := os.WriteFile(p, []byte(line), 0600); err != nil {
		t.Fatal(err)
	}
	c.BridgesFile = p
	raw, err := Torrc(c)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(raw, "REDACT_ME") {
		t.Fatal("raw missing bridge")
	}
	redacted, err := RedactedTorrc(c)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(redacted, "REDACT_ME") || !strings.Contains(redacted, "Bridge [REDACTED]") {
		t.Fatalf("%s", redacted)
	}
	if err := os.WriteFile(p, []byte("obfs4 example.com:443 bad cert=x iat-mode=2\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Torrc(c); err == nil {
		t.Fatal("invalid bridge accepted")
	}
}

func TestAppendAllowlist(t *testing.T) {
	c := cfg(t)
	p := filepath.Join(t.TempDir(), "append")
	if err := os.WriteFile(p, []byte("AvoidDiskWrites 1\nMaxCircuitDirtiness 600\n"), 0600); err != nil {
		t.Fatal(err)
	}
	c.TorrcAppendFile = p
	got, err := Torrc(c)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "MaxCircuitDirtiness 600") {
		t.Fatal(got)
	}
	for _, line := range []string{"SocksPort 0.0.0.0:9999", "Nickname public", "UnknownOption 1", "AvoidDiskWrites 0", "AvoidDiskWrites 1\nAvoidDiskWrites 1"} {
		if err := os.WriteFile(p, []byte(line+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Torrc(c); err == nil {
			t.Fatalf("accepted %q", line)
		}
	}
}

func TestPrivoxyNeutralAdapter(t *testing.T) {
	c := cfg(t)
	c.HTTPEnabled = true
	c.SocksAddress = "0.0.0.0:9050"
	got := Privoxy(c)
	for _, w := range []string{"toggle 0", "enable-remote-toggle 0", "forward-socks5t / 127.0.0.1:9050 .", "debug 4096"} {
		if !strings.Contains(got, w) {
			t.Fatalf("missing %s", w)
		}
	}
	for _, bad := range []string{"debug 1\n", "debug 512", "debug 1024", "debug 8192"} {
		if strings.Contains(got, bad) {
			t.Fatalf("unsafe logging %s", bad)
		}
	}
}

func TestWriteAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "x")
	if err := WriteAtomic(path, []byte("ok"), 0600); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil || string(b) != "ok" {
		t.Fatalf("%q %v", b, err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatalf("mode %o", info.Mode().Perm())
	}
}
