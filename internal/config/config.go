package config

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const Prefix = "TOROUTE_"

type Config struct {
	SocksAddress         string
	HTTPEnabled          bool
	HTTPAddress          string
	DataDir              string
	RuntimeDir           string
	ExitCountries        []string
	StrictExit           bool
	ExcludeExitCountries []string
	BridgesFile          string
	TorrcAppendFile      string
	LogLevel             string
	ShutdownTimeout      time.Duration
	ControlTimeout       time.Duration
	ConfigVerifyTimeout  time.Duration
	TorBinary            string
	PrivoxyBinary        string
	Obfs4ProxyBinary     string
	EnableLegacyEnv      bool
}

func Default() Config {
	return Config{
		SocksAddress:        "0.0.0.0:9050",
		HTTPAddress:         "0.0.0.0:8118",
		DataDir:             "/var/lib/toroute",
		RuntimeDir:          "/run/toroute",
		LogLevel:            "notice",
		ShutdownTimeout:     15 * time.Second,
		ControlTimeout:      5 * time.Second,
		ConfigVerifyTimeout: 20 * time.Second,
		TorBinary:           "/usr/bin/tor",
		PrivoxyBinary:       "/usr/sbin/privoxy",
		Obfs4ProxyBinary:    "/usr/bin/obfs4proxy",
	}
}

var knownEnv = map[string]struct{}{
	"TOROUTE_SOCKS_ADDRESS": {}, "TOROUTE_HTTP_ENABLED": {}, "TOROUTE_HTTP_ADDRESS": {},
	"TOROUTE_DATA_DIR": {}, "TOROUTE_RUNTIME_DIR": {}, "TOROUTE_EXIT_COUNTRIES": {},
	"TOROUTE_STRICT_EXIT": {}, "TOROUTE_EXCLUDE_EXIT_COUNTRIES": {}, "TOROUTE_BRIDGES_FILE": {},
	"TOROUTE_TORRC_APPEND_FILE": {}, "TOROUTE_LOG_LEVEL": {}, "TOROUTE_SHUTDOWN_TIMEOUT": {},
	"TOROUTE_CONTROL_TIMEOUT": {}, "TOROUTE_CONFIG_VERIFY_TIMEOUT": {}, "TOROUTE_ENABLE_LEGACY_ENV": {},
}

func Load() (Config, []string, error) {
	return LoadFromEnviron(os.Environ())
}

func LoadFromEnviron(items []string) (Config, []string, error) {
	cfg := Default()
	env := environMap(items)
	for key := range env {
		if strings.HasPrefix(key, Prefix) {
			if _, ok := knownEnv[key]; !ok {
				return Config{}, nil, fmt.Errorf("unknown environment variable %s", key)
			}
		}
	}

	setRequiredString := func(key string, target *string) error {
		value, ok := env[key]
		if !ok {
			return nil
		}
		if value == "" {
			return fmt.Errorf("%s must not be empty when set", key)
		}
		*target = value
		return nil
	}
	for key, target := range map[string]*string{
		"TOROUTE_SOCKS_ADDRESS": &cfg.SocksAddress, "TOROUTE_HTTP_ADDRESS": &cfg.HTTPAddress,
		"TOROUTE_DATA_DIR": &cfg.DataDir, "TOROUTE_RUNTIME_DIR": &cfg.RuntimeDir,
	} {
		if err := setRequiredString(key, target); err != nil {
			return Config{}, nil, err
		}
	}
	if value, ok := env["TOROUTE_LOG_LEVEL"]; ok {
		if value == "" {
			return Config{}, nil, errors.New("TOROUTE_LOG_LEVEL must not be empty when set")
		}
		cfg.LogLevel = strings.ToLower(value)
	}
	// Optional file/list settings accept explicit empty as unset to support
	// Compose expansion without silently defaulting scalar safety settings.
	cfg.BridgesFile = env["TOROUTE_BRIDGES_FILE"]
	cfg.TorrcAppendFile = env["TOROUTE_TORRC_APPEND_FILE"]

	var err error
	if cfg.HTTPEnabled, err = parseBoolEnv(env, "TOROUTE_HTTP_ENABLED", false); err != nil {
		return Config{}, nil, err
	}
	if cfg.StrictExit, err = parseBoolEnv(env, "TOROUTE_STRICT_EXIT", false); err != nil {
		return Config{}, nil, err
	}
	if cfg.EnableLegacyEnv, err = parseBoolEnv(env, "TOROUTE_ENABLE_LEGACY_ENV", false); err != nil {
		return Config{}, nil, err
	}
	if cfg.ShutdownTimeout, err = parseDurationEnv(env, "TOROUTE_SHUTDOWN_TIMEOUT", cfg.ShutdownTimeout, time.Second, 5*time.Minute); err != nil {
		return Config{}, nil, err
	}
	if cfg.ControlTimeout, err = parseDurationEnv(env, "TOROUTE_CONTROL_TIMEOUT", cfg.ControlTimeout, 100*time.Millisecond, time.Minute); err != nil {
		return Config{}, nil, err
	}
	if cfg.ConfigVerifyTimeout, err = parseDurationEnv(env, "TOROUTE_CONFIG_VERIFY_TIMEOUT", cfg.ConfigVerifyTimeout, time.Second, 5*time.Minute); err != nil {
		return Config{}, nil, err
	}
	if cfg.ExitCountries, err = parseCountries(env["TOROUTE_EXIT_COUNTRIES"]); err != nil {
		return Config{}, nil, fmt.Errorf("TOROUTE_EXIT_COUNTRIES: %w", err)
	}
	if cfg.ExcludeExitCountries, err = parseCountries(env["TOROUTE_EXCLUDE_EXIT_COUNTRIES"]); err != nil {
		return Config{}, nil, fmt.Errorf("TOROUTE_EXCLUDE_EXIT_COUNTRIES: %w", err)
	}

	for _, key := range []string{"BW", "EXITNODE", "PASSWORD", "SERVICE", "TORUSER", "USERID", "GROUPID", "USER_UID", "USER_GID"} {
		if _, present := env[key]; present {
			return Config{}, nil, fmt.Errorf("legacy variable %s is intentionally unsupported because it changes role or security boundaries", key)
		}
	}
	for key := range env {
		if strings.HasPrefix(key, "TOR_") {
			return Config{}, nil, fmt.Errorf("generic legacy variable %s is unsupported; use the typed TOROUTE_* API", key)
		}
	}
	warnings := []string{}
	if location, present := env["LOCATION"]; present {
		if location == "" {
			return Config{}, nil, errors.New("legacy variable LOCATION must not be empty when set")
		}
		if !cfg.EnableLegacyEnv {
			return Config{}, nil, errors.New("legacy LOCATION was detected; use TOROUTE_EXIT_COUNTRIES or explicitly enable limited migration mode")
		}
		if _, typed := env["TOROUTE_EXIT_COUNTRIES"]; typed {
			return Config{}, nil, errors.New("LOCATION and TOROUTE_EXIT_COUNTRIES cannot be set together")
		}
		if _, strict := env["TOROUTE_STRICT_EXIT"]; strict {
			return Config{}, nil, errors.New("LOCATION and TOROUTE_STRICT_EXIT cannot be set together")
		}
		cfg.ExitCountries, err = parseCountries(location)
		if err != nil {
			return Config{}, nil, fmt.Errorf("LOCATION: %w", err)
		}
		cfg.StrictExit = true
		warnings = append(warnings, "LOCATION is deprecated; use TOROUTE_EXIT_COUNTRIES and TOROUTE_STRICT_EXIT")
	}

	if err := cfg.Validate(); err != nil {
		return Config{}, nil, err
	}
	return cfg, warnings, nil
}

func (c Config) Validate() error {
	if err := validateListenAddress(c.SocksAddress); err != nil {
		return fmt.Errorf("SOCKS address: %w", err)
	}
	if err := validateListenAddress(c.HTTPAddress); err != nil {
		return fmt.Errorf("HTTP address: %w", err)
	}
	if c.HTTPEnabled && listenAddressesConflict(c.HTTPAddress, c.SocksAddress) {
		return errors.New("HTTP and SOCKS listeners conflict; use different ports or non-overlapping addresses")
	}
	for name, value := range map[string]string{
		"data directory": c.DataDir, "runtime directory": c.RuntimeDir, "Tor binary": c.TorBinary,
		"Privoxy binary": c.PrivoxyBinary, "obfs4proxy binary": c.Obfs4ProxyBinary,
	} {
		if err := validateAbsolutePath(value); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	if err := validateManagedDirectory(c.DataDir); err != nil {
		return fmt.Errorf("data directory: %w", err)
	}
	if err := validateManagedDirectory(c.RuntimeDir); err != nil {
		return fmt.Errorf("runtime directory: %w", err)
	}
	if c.BridgesFile != "" {
		if err := validateAbsolutePath(c.BridgesFile); err != nil {
			return fmt.Errorf("bridges file: %w", err)
		}
	}
	if c.TorrcAppendFile != "" {
		if err := validateAbsolutePath(c.TorrcAppendFile); err != nil {
			return fmt.Errorf("torrc append file: %w", err)
		}
	}
	if c.DataDir == c.RuntimeDir || pathsOverlap(c.DataDir, c.RuntimeDir) {
		return errors.New("data and runtime directories must be separate and non-overlapping")
	}
	if len(c.ControlSocketPath()) > 100 {
		return errors.New("runtime directory is too long for a portable Unix socket path")
	}
	switch c.LogLevel {
	case "err", "warn", "notice", "info", "debug":
	default:
		return fmt.Errorf("invalid log level %q", c.LogLevel)
	}
	if c.StrictExit && len(c.ExitCountries) == 0 {
		return errors.New("strict exit selection requires at least one exit country")
	}
	preferred := map[string]bool{}
	for _, code := range c.ExitCountries {
		preferred[code] = true
	}
	for _, code := range c.ExcludeExitCountries {
		if preferred[code] {
			return fmt.Errorf("country %q cannot be both preferred and excluded", code)
		}
	}
	return nil
}

func (c Config) TorrcPath() string         { return filepath.Join(c.RuntimeDir, "torrc") }
func (c Config) PrivoxyConfigPath() string { return filepath.Join(c.RuntimeDir, "privoxy.conf") }
func (c Config) ControlSocketPath() string { return filepath.Join(c.RuntimeDir, "control.sock") }
func (c Config) CookiePath() string        { return filepath.Join(c.RuntimeDir, "control.authcookie") }
func (c Config) TorPIDPath() string        { return filepath.Join(c.RuntimeDir, "tor.pid") }

func parseBoolEnv(env map[string]string, key string, def bool) (bool, error) {
	value, ok := env[key]
	if !ok {
		return def, nil
	}
	if value == "" {
		return false, fmt.Errorf("%s must not be empty when set", key)
	}
	switch value {
	case "true":
		return true, nil
	case "false":
		return false, nil
	default:
		return false, fmt.Errorf("%s must be exactly true or false", key)
	}
}

func parseDurationEnv(env map[string]string, key string, def, min, max time.Duration) (time.Duration, error) {
	value, ok := env[key]
	if !ok {
		return def, nil
	}
	if value == "" {
		return 0, fmt.Errorf("%s must not be empty when set", key)
	}
	d, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", key, err)
	}
	if d < min || d > max {
		return 0, fmt.Errorf("%s must be between %s and %s", key, min, max)
	}
	return d, nil
}

func parseCountries(value string) ([]string, error) {
	if strings.TrimSpace(value) == "" {
		return nil, nil
	}
	parts := strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ';' || r == ' ' })
	if len(parts) > 32 {
		return nil, errors.New("too many countries; maximum is 32")
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		code := strings.ToLower(strings.Trim(strings.TrimSpace(part), "{}"))
		if !validCountries[code] {
			return nil, fmt.Errorf("%q is not a supported ISO 3166-1 alpha-2 country code", code)
		}
		if !seen[code] {
			seen[code] = true
			out = append(out, code)
		}
	}
	sort.Strings(out)
	return out, nil
}

func validateListenAddress(value string) error {
	if strings.ContainsAny(value, "\r\n\x00\t ") {
		return errors.New("contains whitespace or control characters")
	}
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		return fmt.Errorf("must be host:port: %w", err)
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return errors.New("port must be 1..65535")
	}
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	if net.ParseIP(host) == nil {
		return errors.New("host must be an IP literal or localhost")
	}
	return nil
}

func listenAddressesConflict(a, b string) bool {
	ha, pa, ea := net.SplitHostPort(a)
	hb, pb, eb := net.SplitHostPort(b)
	if ea != nil || eb != nil || pa != pb {
		return false
	}
	norm := func(host string) string {
		switch strings.ToLower(host) {
		case "localhost":
			return "loopback"
		case "0.0.0.0", "::":
			return "wildcard"
		}
		ip := net.ParseIP(host)
		if ip == nil {
			return host
		}
		if ip.IsLoopback() {
			return "loopback"
		}
		return ip.String()
	}
	na, nb := norm(ha), norm(hb)
	return na == "wildcard" || nb == "wildcard" || na == nb
}

func validateAbsolutePath(value string) error {
	if value == "" {
		return errors.New("must not be empty")
	}
	if strings.ContainsAny(value, "\r\n\x00\t ") {
		return errors.New("contains whitespace or control characters")
	}
	for _, r := range value {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || strings.ContainsRune("/._-", r)) {
			return fmt.Errorf("contains unsupported character %q", r)
		}
	}
	if !filepath.IsAbs(value) {
		return errors.New("must be absolute")
	}
	if filepath.Clean(value) != value {
		return errors.New("must be a clean path without . or ..")
	}
	return nil
}

func validateManagedDirectory(value string) error {
	clean := filepath.Clean(value)
	if clean == "/" {
		return errors.New("cannot be /")
	}
	trimmed := strings.TrimPrefix(clean, "/")
	if trimmed == "" || !strings.Contains(trimmed, "/") {
		return errors.New("must be a dedicated subdirectory, not a top-level directory")
	}
	protected := map[string]bool{"/bin": true, "/boot": true, "/dev": true, "/etc": true, "/home": true, "/lib": true, "/lib64": true, "/media": true, "/mnt": true, "/opt": true, "/proc": true, "/root": true, "/run": true, "/sbin": true, "/srv": true, "/sys": true, "/tmp": true, "/usr": true, "/var": true, "/var/lib": true}
	if protected[clean] {
		return fmt.Errorf("%s is a shared system directory", clean)
	}
	return nil
}

func pathsOverlap(a, b string) bool {
	relAB, e1 := filepath.Rel(a, b)
	relBA, e2 := filepath.Rel(b, a)
	inside := func(rel string, err error) bool {
		return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
	}
	return inside(relAB, e1) || inside(relBA, e2)
}

func environMap(items []string) map[string]string {
	out := make(map[string]string, len(items))
	for _, item := range items {
		if i := strings.IndexByte(item, '='); i >= 0 {
			out[item[:i]] = item[i+1:]
		}
	}
	return out
}

func ReadLines(path string, maxBytes int64, maxLine int) ([]string, error) {
	return readLines(path, maxBytes, maxLine, false)
}

func ReadSecretLines(path string, maxBytes int64, maxLine int) ([]string, error) {
	return readLines(path, maxBytes, maxLine, true)
}

func readLines(path string, maxBytes int64, maxLine int, requirePrivate bool) ([]string, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() {
		return nil, errors.New("must be a regular non-symlink file")
	}
	if before.Size() > maxBytes {
		return nil, fmt.Errorf("file exceeds %d bytes", maxBytes)
	}
	f, err := openFileNoFollow(path)
	if err != nil {
		return nil, fmt.Errorf("open without following symlinks: %w", err)
	}
	defer f.Close()
	after, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !after.Mode().IsRegular() || !os.SameFile(before, after) {
		return nil, errors.New("file changed while opening")
	}
	if requirePrivate {
		if after.Mode().Perm()&0077 != 0 {
			return nil, fmt.Errorf("secret file permissions too open: %04o", after.Mode().Perm())
		}
		if !fileOwnedByCurrentUser(after) {
			return nil, errors.New("secret file is not owned by current user")
		}
	}
	if after.Size() > maxBytes {
		return nil, fmt.Errorf("file exceeds %d bytes", maxBytes)
	}
	data, err := io.ReadAll(io.LimitReader(f, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("file exceeded %d bytes while reading", maxBytes)
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), maxLine)
	var lines []string
	for scanner.Scan() {
		if strings.ContainsRune(scanner.Text(), '\x00') {
			return nil, errors.New("file contains NUL")
		}
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return lines, nil
}

var validCountries = func() map[string]bool {
	codes := strings.Fields(`ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg eh er es et fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sj sk sl sm sn so sr ss st sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug um us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw`)
	m := make(map[string]bool, len(codes))
	for _, code := range codes {
		m[code] = true
	}
	return m
}()
