package renderer

import (
	"context"
	"net"
	"syscall"

	"golang.org/x/net/route"
)

// lookupMAC reads the hardware address of ip from the kernel ARP table (filled by talking to the TV).
// In-process: macOS hides the table from an arp child process without local network access.
func lookupMAC(_ context.Context, ip string) string {
	want := net.ParseIP(ip).To4()
	if want == nil {
		return ""
	}
	rib, err := route.FetchRIB(syscall.AF_INET, route.RIBTypeRoute, 0)
	if err != nil {
		return ""
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return ""
	}
	for _, m := range msgs {
		rm, ok := m.(*route.RouteMessage)
		if !ok || len(rm.Addrs) <= syscall.RTAX_GATEWAY {
			continue
		}
		dst, ok1 := rm.Addrs[syscall.RTAX_DST].(*route.Inet4Addr)
		ll, ok2 := rm.Addrs[syscall.RTAX_GATEWAY].(*route.LinkAddr)
		if ok1 && ok2 && len(ll.Addr) == 6 && net.IP(dst.IP[:]).Equal(want) {
			return net.HardwareAddr(ll.Addr).String()
		}
	}
	return ""
}
