package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/kabumatome/toroute/internal/config"
	"github.com/kabumatome/toroute/internal/control"
	"github.com/kabumatome/toroute/internal/render"
	hruntime "github.com/kabumatome/toroute/internal/runtime"
	"github.com/kabumatome/toroute/internal/supervisor"
)

var (
	version   = "dev"
	commit    = "unknown"
	buildDate = "unknown"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "toroute: error: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		args = []string{"run"}
	}
	if isLegacyTopLevelOption(args[0]) {
		return compat(append([]string{"dperson"}, args...))
	}
	command, rest := args[0], args[1:]
	switch command {
	case "run":
		if handled, err := noArgHelp("run", rest); handled {
			return err
		}
		cfg, warnings, err := config.Load()
		if err != nil {
			return err
		}
		for _, w := range warnings {
			fmt.Fprintf(os.Stderr, "toroute: warning: %s\n", w)
		}
		if len(cfg.ExitCountries) > 0 {
			fmt.Fprintln(os.Stderr, "toroute: warning: exit-country constraints reduce the anonymity set and can reduce availability")
		}
		return supervisor.Run(cfg)
	case "check-config":
		if handled, err := noArgHelp("check-config", rest); handled {
			return err
		}
		cfg, _, err := config.Load()
		if err != nil {
			return err
		}
		return hruntime.CheckConfig(cfg)
	case "print-config":
		return printConfig(rest)
	case "status", "healthcheck":
		return status(command, rest)
	case "newnym":
		if handled, err := noArgHelp("newnym", rest); handled {
			return err
		}
		cfg, _, err := config.Load()
		if err != nil {
			return err
		}
		c := control.Client{SocketPath: cfg.ControlSocketPath(), CookiePath: cfg.CookiePath(), Timeout: cfg.ControlTimeout}
		ctx, cancel := context.WithTimeout(context.Background(), cfg.ControlTimeout)
		defer cancel()
		if err := c.NewNym(ctx); err != nil {
			return err
		}
		fmt.Println("NEWNYM accepted for future streams; an exit-IP change is not guaranteed")
		return nil
	case "exec":
		return execCommand(rest)
	case "compat":
		return compat(rest)
	case "version", "--version", "-v":
		if command == "version" {
			if handled, err := noArgHelp("version", rest); handled {
				return err
			}
		} else if len(rest) != 0 {
			return fmt.Errorf("%s does not accept arguments", command)
		}
		fmt.Printf("toroute %s (commit=%s built=%s)\n", version, commit, buildDate)
		return nil
	case "help", "--help", "-h":
		if len(rest) != 0 {
			return errors.New("help does not accept arguments; run a command with --help")
		}
		usage()
		return nil
	default:
		return fmt.Errorf("unknown command %q", command)
	}
}
func noArgHelp(command string, args []string) (bool, error) {
	if len(args) == 1 && isHelp(args[0]) {
		commandUsage(command)
		return true, nil
	}
	if len(args) != 0 {
		return true, fmt.Errorf("%s does not accept arguments", command)
	}
	return false, nil
}
func isHelp(v string) bool { return v == "-h" || v == "--help" }

func printConfig(args []string) error {
	if len(args) == 1 && isHelp(args[0]) {
		commandUsage("print-config")
		return nil
	}
	fs := flag.NewFlagSet("print-config", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	format := fs.String("format", "torrc", "torrc, privoxy, or json")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			commandUsage("print-config")
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("print-config does not accept positional arguments: %q", fs.Args())
	}
	cfg, _, err := config.Load()
	if err != nil {
		return err
	}
	switch *format {
	case "torrc":
		v, err := render.RedactedTorrc(cfg)
		if err != nil {
			return err
		}
		fmt.Print(v)
	case "privoxy":
		if !cfg.HTTPEnabled {
			return errors.New("HTTP proxy is disabled")
		}
		fmt.Print(render.Privoxy(cfg))
	case "json":
		safe := map[string]any{"socks_address": cfg.SocksAddress, "http_enabled": cfg.HTTPEnabled, "http_address": cfg.HTTPAddress, "data_dir": cfg.DataDir, "runtime_dir": cfg.RuntimeDir, "exit_countries": cfg.ExitCountries, "strict_exit": cfg.StrictExit, "exclude_exit_countries": cfg.ExcludeExitCountries, "bridges_configured": cfg.BridgesFile != "", "torrc_append_configured": cfg.TorrcAppendFile != "", "log_level": cfg.LogLevel}
		b, err := json.MarshalIndent(safe, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(b))
	default:
		return fmt.Errorf("unknown format %q", *format)
	}
	return nil
}

func status(command string, args []string) error {
	if len(args) == 1 && isHelp(args[0]) {
		commandUsage(command)
		return nil
	}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	jsonOut := fs.Bool("json", false, "emit JSON")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			commandUsage(command)
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("%s does not accept positional arguments: %q", command, fs.Args())
	}
	cfg, _, err := config.Load()
	if err != nil {
		return err
	}
	c := control.Client{SocketPath: cfg.ControlSocketPath(), CookiePath: cfg.CookiePath(), Timeout: cfg.ControlTimeout}
	ctx, cancel := context.WithTimeout(context.Background(), cfg.ControlTimeout)
	defer cancel()
	s, err := c.Status(ctx)
	if err != nil {
		return err
	}
	if *jsonOut {
		b, err := json.Marshal(s)
		if err != nil {
			return err
		}
		fmt.Println(string(b))
	} else {
		fmt.Printf("ready=%t bootstrap=%d tag=%s tor=%s socks=%s\n", s.Ready, s.Progress, s.Tag, s.TorVersion, strings.Join(s.SocksListeners, ","))
	}
	if command == "healthcheck" && !s.Ready {
		return fmt.Errorf("not ready: bootstrap progress is %d", s.Progress)
	}
	return nil
}

func execCommand(args []string) error {
	if len(args) == 1 && isHelp(args[0]) {
		commandUsage("exec")
		return nil
	}
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) == 0 {
		return errors.New("exec requires a command")
	}
	path, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("find executable %q: %w", args[0], err)
	}
	return syscall.Exec(path, args, os.Environ())
}

func compat(args []string) error {
	if len(args) == 1 && isHelp(args[0]) {
		commandUsage("compat")
		return nil
	}
	if len(args) == 0 || args[0] != "dperson" {
		return errors.New("usage: toroute compat dperson [legacy options]")
	}
	if len(args) == 2 && isHelp(args[1]) {
		commandUsage("compat")
		return nil
	}
	fs := flag.NewFlagSet("compat dperson", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	location := fs.String("l", "", "legacy exit country")
	newnym := fs.Bool("n", false, "request NEWNYM")
	bandwidth := fs.String("b", "", "unsupported")
	password := fs.String("p", "", "unsupported")
	service := fs.String("s", "", "unsupported")
	enableExit := fs.Bool("e", false, "unsupported")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("legacy trailing commands are unsupported; use toroute exec -- <command>")
	}
	if *bandwidth != "" || *password != "" || *service != "" || *enableExit {
		return errors.New("-b, -e, -p and -s are intentionally unsupported because they enable server roles or expose control credentials")
	}
	if *newnym && *location != "" {
		return errors.New("-n cannot be combined with -l")
	}
	if *location != "" {
		for _, key := range []string{"LOCATION", "TOROUTE_EXIT_COUNTRIES", "TOROUTE_STRICT_EXIT"} {
			if _, ok := os.LookupEnv(key); ok {
				return fmt.Errorf("%s is already set; compat -l will not overwrite configuration", key)
			}
		}
		if err := os.Setenv("TOROUTE_EXIT_COUNTRIES", *location); err != nil {
			return err
		}
		if err := os.Setenv("TOROUTE_STRICT_EXIT", "true"); err != nil {
			return err
		}
	}
	if *newnym {
		return run([]string{"newnym"})
	}
	return run([]string{"run"})
}
func isLegacyTopLevelOption(arg string) bool {
	switch arg {
	case "-b", "-e", "-l", "-n", "-p", "-s":
		return true
	}
	return false
}
func commandUsage(command string) {
	switch command {
	case "run":
		fmt.Println("Usage: toroute run")
	case "check-config":
		fmt.Println("Usage: toroute check-config")
	case "print-config":
		fmt.Println("Usage: toroute print-config [--format torrc|privoxy|json]")
	case "status", "healthcheck":
		fmt.Printf("Usage: toroute %s [--json]\n", command)
	case "newnym":
		fmt.Println("Usage: toroute newnym")
	case "exec":
		fmt.Println("Usage: toroute exec [--] <command> [args...]")
	case "compat":
		fmt.Println("Usage: toroute compat dperson [-l CC] [-n]")
	case "version":
		fmt.Println("Usage: toroute version")
	default:
		usage()
	}
}
func usage() {
	fmt.Print(`ToRoute - security-focused containerized Tor client

Usage:
  toroute run
  toroute check-config
  toroute print-config [--format torrc|privoxy|json]
  toroute status [--json]
  toroute healthcheck [--json]
  toroute newnym
  toroute exec [--] <command> [args...]
  toroute compat dperson [-l CC] [-n]
  toroute version
`)
}
