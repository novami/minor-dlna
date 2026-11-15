// Package ssdp announces the device on the LAN and answers discovery requests.
package ssdp

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/ipv4"
)

const (
	maxAge   = 1800
	mcastStr = "239.255.255.250:1900"
)

var mcastAddr = &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}

type Server struct {
	UUID       string
	Port       int      // HTTP port serving the device description
	Path       string   // path of the device description, e.g. "/description.xml"
	ServerName string   // value of the SERVER header
	DeviceType string   // e.g. urn:schemas-upnp-org:device:MediaServer:1
	Services   []string // service types
	Interfaces []string // allowed interface names; empty = auto

	mu     sync.Mutex
	conn   *ipv4.PacketConn
	joined map[int]bool
}

// targets returns all notification types (NT) with their USN.
func (s *Server) targets() [][2]string {
	uuid := "uuid:" + s.UUID
	t := [][2]string{
		{"upnp:rootdevice", uuid + "::upnp:rootdevice"},
		{uuid, uuid},
		{s.DeviceType, uuid + "::" + s.DeviceType},
	}
	for _, st := range s.Services {
		t = append(t, [2]string{st, uuid + "::" + st})
	}
	return t
}

// Run blocks until ctx is cancelled, then sends byebye.
func (s *Server) Run(ctx context.Context) error {
	lc := net.ListenConfig{Control: reuseControl}
	pc, err := lc.ListenPacket(ctx, "udp4", "0.0.0.0:1900")
	if err != nil {
		return fmt.Errorf("ssdp listen: %w", err)
	}
	s.conn = ipv4.NewPacketConn(pc)
	s.joined = map[int]bool{}
	_ = s.conn.SetControlMessage(ipv4.FlagInterface|ipv4.FlagDst, true)
	_ = s.conn.SetMulticastTTL(2)
	_ = s.conn.SetMulticastLoopback(true)
	s.refreshInterfaces()

	go s.readLoop()

	// Initial burst (UDP is lossy), then periodic.
	for range 3 {
		s.notifyAll("ssdp:alive")
		time.Sleep(200 * time.Millisecond)
	}
	tick := time.NewTicker(maxAge / 2 * time.Second)
	refresh := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	defer refresh.Stop()
	for {
		select {
		case <-ctx.Done():
			s.notifyAll("ssdp:byebye")
			return pc.Close()
		case <-refresh.C:
			if s.refreshInterfaces() {
				s.notifyAll("ssdp:alive")
			}
		case <-tick.C:
			s.notifyAll("ssdp:alive")
		}
	}
}

// refreshInterfaces joins the multicast group on new interfaces. Reports whether any were added.
func (s *Server) refreshInterfaces() bool {
	added := false
	for _, ifi := range s.interfaces() {
		s.mu.Lock()
		if !s.joined[ifi.Index] {
			if err := s.conn.JoinGroup(&ifi, mcastAddr); err != nil {
				slog.Warn("ssdp join", "iface", ifi.Name, "err", err)
			} else {
				s.joined[ifi.Index] = true
				added = true
				slog.Info("ssdp listening", "iface", ifi.Name)
			}
		}
		s.mu.Unlock()
	}
	return added
}

// interfaces returns usable LAN interfaces.
func (s *Server) interfaces() []net.Interface {
	all, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []net.Interface
	for _, ifi := range all {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagMulticast == 0 || ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		if len(s.Interfaces) > 0 {
			if !slices.Contains(s.Interfaces, ifi.Name) {
				continue
			}
		} else if skipIface(ifi.Name) {
			continue
		}
		if ifaceIPv4(&ifi) != nil {
			out = append(out, ifi)
		}
	}
	return out
}

// skipIface filters virtual interfaces (VPN, bridges, Apple peer-to-peer links).
func skipIface(name string) bool {
	for _, p := range []string{"utun", "bridge", "awdl", "llw", "anpi", "gif", "stf", "ap", "vmenet", "docker", "veth"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

func ifaceIPv4(ifi *net.Interface) net.IP {
	addrs, err := ifi.Addrs()
	if err != nil {
		return nil
	}
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok {
			if ip4 := n.IP.To4(); ip4 != nil && !ip4.IsLoopback() {
				return ip4
			}
		}
	}
	return nil
}

func (s *Server) location(ip net.IP) string {
	return fmt.Sprintf("http://%s:%d%s", ip, s.Port, s.Path)
}

func (s *Server) notifyAll(nts string) {
	for _, ifi := range s.interfaces() {
		ip := ifaceIPv4(&ifi)
		for _, t := range s.targets() {
			var b strings.Builder
			b.WriteString("NOTIFY * HTTP/1.1\r\n")
			b.WriteString("HOST: " + mcastStr + "\r\n")
			b.WriteString("NT: " + t[0] + "\r\n")
			b.WriteString("NTS: " + nts + "\r\n")
			b.WriteString("USN: " + t[1] + "\r\n")
			if nts == "ssdp:alive" {
				fmt.Fprintf(&b, "CACHE-CONTROL: max-age=%d\r\n", maxAge)
				b.WriteString("LOCATION: " + s.location(ip) + "\r\n")
				b.WriteString("SERVER: " + s.ServerName + "\r\n")
			}
			b.WriteString("\r\n")
			s.mu.Lock()
			if err := s.conn.SetMulticastInterface(&ifi); err == nil {
				_, err = s.conn.WriteTo([]byte(b.String()), nil, mcastAddr)
				if err != nil {
					slog.Debug("ssdp notify", "iface", ifi.Name, "err", err)
				}
			}
			s.mu.Unlock()
		}
	}
}

func (s *Server) readLoop() {
	buf := make([]byte, 2048)
	for {
		n, cm, src, err := s.conn.ReadFrom(buf)
		if err != nil {
			return
		}
		req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(buf[:n])))
		if err != nil || req.Method != "M-SEARCH" || strings.Trim(req.Header.Get("Man"), `"`) != "ssdp:discover" {
			continue
		}
		udp, ok := src.(*net.UDPAddr)
		if !ok {
			continue
		}
		ip := s.replyIP(cm, udp.IP)
		if ip == nil {
			continue
		}
		matches := Match(req.Header.Get("St"), s.targets())
		if len(matches) == 0 {
			continue
		}
		mx, _ := strconv.Atoi(req.Header.Get("Mx"))
		go s.respond(udp, ip, matches, mx)
	}
}

// replyIP picks our address on the interface the request arrived on (falls back to subnet match).
func (s *Server) replyIP(cm *ipv4.ControlMessage, src net.IP) net.IP {
	for _, ifi := range s.interfaces() {
		if cm != nil && cm.IfIndex == ifi.Index {
			return ifaceIPv4(&ifi)
		}
	}
	for _, ifi := range s.interfaces() {
		addrs, _ := ifi.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && n.Contains(src) {
				return n.IP.To4()
			}
		}
	}
	return nil
}

// Match returns targets matching the search target.
func Match(st string, targets [][2]string) [][2]string {
	if st == "ssdp:all" {
		return targets
	}
	for _, t := range targets {
		if t[0] == st {
			return [][2]string{t}
		}
	}
	return nil
}

func (s *Server) respond(dst *net.UDPAddr, ip net.IP, matches [][2]string, mx int) {
	if mx < 1 {
		mx = 1
	}
	time.Sleep(time.Duration(rand.IntN(min(mx, 3)*1000)) * time.Millisecond)
	for _, t := range matches {
		var b strings.Builder
		b.WriteString("HTTP/1.1 200 OK\r\n")
		fmt.Fprintf(&b, "CACHE-CONTROL: max-age=%d\r\n", maxAge)
		b.WriteString("DATE: " + time.Now().UTC().Format(http.TimeFormat) + "\r\n")
		b.WriteString("EXT:\r\n")
		b.WriteString("LOCATION: " + s.location(ip) + "\r\n")
		b.WriteString("SERVER: " + s.ServerName + "\r\n")
		b.WriteString("ST: " + t[0] + "\r\n")
		b.WriteString("USN: " + t[1] + "\r\n")
		b.WriteString("\r\n")
		s.mu.Lock()
		_, err := s.conn.WriteTo([]byte(b.String()), nil, dst)
		s.mu.Unlock()
		if err != nil {
			slog.Debug("ssdp reply", "dst", dst, "err", err)
		}
	}
}
