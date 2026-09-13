package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaults(t *testing.T) {
	cfg, warnings, err := LoadFromEnviron(nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(warnings) != 0 || cfg.SocksAddress != "0.0.0.0:9050" || cfg.HTTPEnabled {
		t.Fatalf("cfg=%+v warnings=%v", cfg, warnings)
	}
}

func TestUnknownAndEmptyCriticalValuesFail(t *testing.T) {
	for _, env := range [][]string{{"TOROUTE_UNKNOWN=1"}, {"TOROUTE_HTTP_ENABLED="}, {"TOROUTE_SOCKS_ADDRESS="}, {"TOROUTE_CONFIG_VERIFY_TIMEOUT="}} {
		if _, _, err := LoadFromEnviron(env); err == nil {
			t.Fatalf("accepted %v", env)
		}
	}
}

func TestCountriesAndConflicts(t *testing.T) {
	cfg, _, err := LoadFromEnviron([]string{"TOROUTE_EXIT_COUNTRIES=JP,us,jp", "TOROUTE_EXCLUDE_EXIT_COUNTRIES=cn;ru"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cfg.ExitCountries, ",") != "jp,us" {
		t.Fatalf("%v", cfg.ExitCountries)
	}
	if _, _, err := LoadFromEnviron([]string{"TOROUTE_EXIT_COUNTRIES=jp", "TOROUTE_EXCLUDE_EXIT_COUNTRIES=JP"}); err == nil {
		t.Fatal("expected overlap failure")
	}
}

func TestListenerCollision(t *testing.T) {
	for _, env := range [][]string{
		{"TOROUTE_HTTP_ENABLED=true", "TOROUTE_HTTP_ADDRESS=127.0.0.1:9050", "TOROUTE_SOCKS_ADDRESS=0.0.0.0:9050"},
		{"TOROUTE_HTTP_ENABLED=true", "TOROUTE_HTTP_ADDRESS=localhost:9050", "TOROUTE_SOCKS_ADDRESS=127.0.0.1:9050"},
	} {
		if _, _, err := LoadFromEnviron(env); err == nil {
			t.Fatalf("accepted collision %v", env)
		}
	}
}

func TestLegacyLocation(t *testing.T) {
	if _, _, err := LoadFromEnviron([]string{"LOCATION=JP"}); err == nil {
		t.Fatal("legacy accepted without opt-in")
	}
	cfg, warnings, err := LoadFromEnviron([]string{"TOROUTE_ENABLE_LEGACY_ENV=true", "LOCATION=JP"})
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.StrictExit || strings.Join(cfg.ExitCountries, ",") != "jp" || len(warnings) != 1 {
		t.Fatalf("cfg=%+v warnings=%v", cfg, warnings)
	}
	for _, env := range [][]string{{"TOR_SocksPort="}, {"USERID="}, {"TOROUTE_ENABLE_LEGACY_ENV=true", "LOCATION=jp", "TOROUTE_STRICT_EXIT=false"}} {
		if _, _, err := LoadFromEnviron(env); err == nil {
			t.Fatalf("accepted %v", env)
		}
	}
}

func TestManagedDirectories(t *testing.T) {
	for _, value := range []string{"/", "/run", "/var/lib", "/tmp"} {
		if _, _, err := LoadFromEnviron([]string{"TOROUTE_DATA_DIR=" + value}); err == nil {
			t.Fatalf("accepted %s", value)
		}
	}
	if _, _, err := LoadFromEnviron([]string{"TOROUTE_DATA_DIR=/var/lib/toroute", "TOROUTE_RUNTIME_DIR=/var/lib/toroute/run"}); err == nil {
		t.Fatal("accepted overlap")
	}
}

func TestReadLinesRejectsSymlinkAndLargeLine(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real")
	link := filepath.Join(dir, "link")
	if err := os.WriteFile(real, []byte("one\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadLines(link, 100, 100); err == nil {
		t.Fatal("symlink accepted")
	}
	large := filepath.Join(dir, "large")
	if err := os.WriteFile(large, []byte(strings.Repeat("x", 101)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadLines(large, 100, 1000); err == nil {
		t.Fatal("large file accepted")
	}
}

func TestReadSecretLinesRejectsOpenPermissions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret")
	if err := os.WriteFile(path, []byte("secret\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecretLines(path, 100, 100); err != nil {
		t.Fatalf("private secret rejected: %v", err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecretLines(path, 100, 100); err == nil {
		t.Fatal("group/world-readable secret accepted")
	}
}

func TestBinaryPathOverridesAreNotEnvironmentAPI(t *testing.T) {
	for _, key := range []string{"TOROUTE_TOR_BINARY", "TOROUTE_PRIVOXY_BINARY", "TOROUTE_OBFS4PROXY_BINARY"} {
		if _, _, err := LoadFromEnviron([]string{key + "=/tmp/fake"}); err == nil {
			t.Fatalf("accepted %s", key)
		}
	}
}
