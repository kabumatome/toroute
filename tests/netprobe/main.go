package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	timeout := flag.Duration("timeout", 3*time.Second, "connection deadline")
	expect := flag.String("expect", "success", "success or failure")
	listen := flag.String("listen", "", "listen address instead of dialing")
	flag.Parse()
	if *listen != "" {
		ln, err := net.Listen("tcp", *listen)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer ln.Close()
		for {
			conn, err := ln.Accept()
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			_ = conn.Close()
		}
	}
	if flag.NArg() != 1 || (*expect != "success" && *expect != "failure") || *timeout <= 0 {
		fmt.Fprintln(os.Stderr, "usage: netprobe [--timeout 3s] --expect success|failure HOST:PORT, or netprobe --listen :PORT")
		os.Exit(2)
	}
	if err := probe(flag.Arg(0), *timeout, *expect); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func probe(address string, timeout time.Duration, expect string) error {
	conn, err := net.DialTimeout("tcp", address, timeout)
	if err == nil {
		_ = conn.Close()
	}
	succeeded := err == nil
	if (expect == "success") == succeeded {
		return nil
	}
	if err != nil {
		return fmt.Errorf("unexpected connection failure to %s: %w", address, err)
	}
	return fmt.Errorf("unexpected connection success to %s", address)
}
