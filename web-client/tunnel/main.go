// bromure-client-tunnel — the Bromure Client's system-wide network tunnel on
// Linux: a connected remote's workspace subnet (192.168.x.0/24) reachable at
// its literal addresses from any of the user's processes (curl, ssh, a
// browser), as the macOS fat client's utun tunnel does.
//
//	bromure-client-tunnel helper     root, socket-activated by systemd
//	                                 (daemon_linux.go)
//	bromure-client-tunnel forward    the user's side, run by the app
//	                                 (forward_linux.go, forwarder.go, tcpflow.go)
//
// Ships in the bromure-client .deb (resources/bromure-client-tunnel).
package main

import (
	"fmt"
	"os"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "helper":
		os.Exit(helperMain(os.Args[2:]))
	case "forward":
		os.Exit(forwardMain(os.Args[2:]))
	case "version", "--version":
		fmt.Println(version)
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: bromure-client-tunnel helper [--listen PATH] | forward --cidr CIDR --app-socket PATH | version")
	os.Exit(2)
}
