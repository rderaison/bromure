package main

// Forward mode (`bromure-client-tunnel forward`): the unprivileged half, run
// by the app (Electron main) as the user. It asks the helper for a TUN routed
// to the remote's workspace subnet, then runs the userspace stack on it,
// opening each flow through the app's socket (appdial). The app reads one
// status line on stdout (`OK <ifname>` or `ERR <why>`); the tunnel lasts until
// the app closes our stdin (or we're signalled), and the helper tears it down
// the moment our connection to it closes.

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func forwardMain(args []string) int {
	log.SetFlags(0)
	log.SetPrefix("bromure-client-tunnel: ")
	fs := flag.NewFlagSet("forward", flag.ContinueOnError)
	cidr := fs.String("cidr", "", "the remote's workspace subnet (a private /24)")
	appSock := fs.String("app-socket", "", "the app's flow socket")
	helper := fs.String("helper", helperSocket, "the root helper's socket")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	status := func(format string, a ...any) { fmt.Fprintf(os.Stdout, format+"\n", a...) }
	// Not ptrace-able by other processes of the user, no core dumps.
	syscall.Syscall(syscall.SYS_PRCTL, syscall.PR_SET_DUMPABLE, 0, 0)

	canon, ok := privateSlash24(*cidr)
	if !ok || *appSock == "" {
		status("ERR usage: forward --cidr <private /24> --app-socket <path>")
		return 2
	}
	network, mask, _ := parseCIDR(canon)

	conn, tun, name, err := requestTun(*helper, canon)
	if err != nil {
		status("ERR %s", err)
		return 1
	}
	defer conn.Close() // closing it is what tears the tunnel down

	dialTCP := func(ip string, port int) (upstream, error) {
		return appDial(*appSock, fmt.Sprintf("forward %s %d", ip, port))
	}
	dialUDP := func(ip string) (upstream, error) { return appDial(*appSock, "forward-udp "+ip) }
	fw := newForwarder(tun, network, mask, dialTCP, dialUDP)
	status("OK %s", name)

	done := make(chan string, 3)
	go func() {
		err := fw.run()
		done <- fmt.Sprintf("tun: %v", err)
	}()
	go func() { io.Copy(io.Discard, os.Stdin); done <- "" }() // the app went away
	go func() { var b [1]byte; conn.Read(b[:]); done <- "the helper closed the tunnel" }()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() { <-sig; done <- "" }()
	if why := <-done; why != "" {
		log.Print(why)
		return 1
	}
	return 0
}

// requestTun asks the helper for a TUN routed to cidr; it returns the
// connection to hold, the TUN, and its name.
func requestTun(path, cidr string) (*net.UnixConn, *os.File, string, error) {
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) {
			return nil, nil, "", errors.New("the tunnel helper isn't installed or running (it comes with the .deb: sudo apt install bromure-client)")
		}
		return nil, nil, "", fmt.Errorf("the tunnel helper isn't reachable: %v", err)
	}
	if _, err := fmt.Fprintf(c, "SETUP %s\n", cidr); err != nil {
		c.Close()
		return nil, nil, "", fmt.Errorf("the tunnel helper: %v", err)
	}
	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, 512)
	oob := make([]byte, syscall.CmsgSpace(4))
	n, oobn, _, _, err := c.ReadMsgUnix(buf, oob)
	c.SetReadDeadline(time.Time{})
	if err != nil || n == 0 {
		c.Close()
		return nil, nil, "", errors.New("the tunnel helper closed the connection")
	}
	msg := strings.TrimSpace(string(buf[:n]))
	var fd = -1
	if msgs, err := syscall.ParseSocketControlMessage(oob[:oobn]); err == nil {
		for _, m := range msgs {
			if fds, err := syscall.ParseUnixRights(&m); err == nil && len(fds) > 0 {
				fd = fds[0]
				for _, extra := range fds[1:] {
					syscall.Close(extra)
				}
			}
		}
	}
	name, ok := strings.CutPrefix(msg, "OK ")
	if !ok || fd < 0 {
		if fd >= 0 {
			syscall.Close(fd)
		}
		c.Close()
		why, _ := strings.CutPrefix(msg, "ERR ")
		return nil, nil, "", fmt.Errorf("the tunnel helper refused: %s", why)
	}
	syscall.CloseOnExec(fd)
	return c, os.NewFile(uintptr(fd), name), name, nil
}

// appDial opens one stream through the app: the verb on a line, the app's
// `OK` (its SSH channel is open) or `ERR <why>`, then raw bytes.
func appDial(path, verb string) (upstream, error) {
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(c, verb+"\n"); err != nil {
		c.Close()
		return nil, err
	}
	c.SetReadDeadline(time.Now().Add(30 * time.Second))
	var line []byte
	var one [1]byte
	for {
		n, err := c.Read(one[:]) // byte by byte: nothing after the line is consumed
		if n == 1 {
			if one[0] == '\n' {
				break
			}
			if len(line) < 512 {
				line = append(line, one[0])
			}
		}
		if err != nil {
			c.Close()
			return nil, fmt.Errorf("app: %v", err)
		}
	}
	c.SetReadDeadline(time.Time{})
	if s := string(line); s != "OK" {
		c.Close()
		return nil, fmt.Errorf("app: %s", strings.TrimPrefix(s, "ERR "))
	}
	return c, nil
}
