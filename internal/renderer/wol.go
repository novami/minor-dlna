package renderer

import (
	"bytes"
	"errors"
	"net"
)

// Wake sends a Wake-on-LAN magic packet for mac to the global broadcast and to the broadcast of every LAN interface.
func Wake(mac string, ifaces []net.Interface) error {
	hw, err := net.ParseMAC(mac)
	if err != nil || len(hw) != 6 {
		return errors.New("invalid MAC address")
	}
	pkt := append(bytes.Repeat([]byte{0xff}, 6), bytes.Repeat(hw, 16)...)
	targets := []net.IP{net.IPv4bcast}
	for _, ifi := range ifaces {
		addrs, _ := ifi.Addrs()
		for _, a := range addrs {
			n, ok := a.(*net.IPNet)
			if !ok || n.IP.To4() == nil {
				continue
			}
			ip, mask := n.IP.To4(), net.IP(n.Mask).To4()
			if mask == nil {
				continue
			}
			b := make(net.IP, 4)
			for i := range b {
				b[i] = ip[i] | ^mask[i]
			}
			targets = append(targets, b)
		}
	}
	pc, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		return err
	}
	defer pc.Close()
	var sent bool
	for _, t := range targets {
		for _, port := range []int{9, 7} {
			if _, err := pc.WriteTo(pkt, &net.UDPAddr{IP: t, Port: port}); err == nil {
				sent = true
			}
		}
	}
	if !sent {
		return errors.New("magic packet not sent")
	}
	return nil
}
