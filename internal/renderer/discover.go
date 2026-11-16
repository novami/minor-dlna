// Package renderer finds TVs (UPnP MediaRenderers) on the network and controls playback on them.
package renderer

import (
	"bufio"
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/novami/minor-dlna/internal/ssdp"
	"golang.org/x/net/ipv4"
)

const (
	DeviceType = "urn:schemas-upnp-org:device:MediaRenderer:1"
	avtType    = "urn:schemas-upnp-org:service:AVTransport:1"
	rcType     = "urn:schemas-upnp-org:service:RenderingControl:1"
)

// Device is a renderer that can play our streams.
type Device struct {
	UDN          string `json:"udn"`
	Name         string `json:"name"`
	Manufacturer string `json:"-"`
	Model        string `json:"-"`
	Location     string `json:"-"`
	IP           string `json:"ip"`
	MAC          string `json:"mac"`
	Online       bool   `json:"online"`
	avt, rc      string // control URLs
}

var httpClient = &http.Client{Timeout: 5 * time.Second}

// Search sends M-SEARCH on every LAN interface and describes each renderer that answers within wait.
func Search(ctx context.Context, ifaces []string, wait time.Duration) ([]Device, error) {
	pc, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		return nil, err
	}
	defer pc.Close()
	p := ipv4.NewPacketConn(pc)
	msg := []byte("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + DeviceType + "\r\n\r\n")
	dst := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	sent := false
	for _, ifi := range ssdp.LANInterfaces(ifaces) {
		if p.SetMulticastInterface(&ifi) != nil {
			continue
		}
		for range 2 { // UDP may drop one
			if _, err := p.WriteTo(msg, nil, dst); err == nil {
				sent = true
			}
		}
	}
	if !sent {
		return nil, errors.New("no network interface for discovery")
	}

	locations := map[string]bool{}
	deadline := time.Now().Add(wait)
	buf := make([]byte, 4096)
	for {
		_ = pc.SetReadDeadline(deadline)
		n, _, err := pc.ReadFrom(buf)
		if err != nil {
			break
		}
		resp, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(buf[:n])), nil)
		if err != nil {
			continue
		}
		if loc := resp.Header.Get("Location"); loc != "" {
			locations[loc] = true
		}
		if ctx.Err() != nil {
			break
		}
	}

	var out []Device
	seen := map[string]bool{}
	for loc := range locations {
		d, err := Describe(ctx, loc)
		if err != nil || seen[d.UDN] {
			continue
		}
		seen[d.UDN] = true
		out = append(out, d)
	}
	return out, nil
}

type xmlService struct {
	Type       string `xml:"serviceType"`
	ControlURL string `xml:"controlURL"`
}

type xmlDevice struct {
	Type         string       `xml:"deviceType"`
	Name         string       `xml:"friendlyName"`
	Manufacturer string       `xml:"manufacturer"`
	Model        string       `xml:"modelName"`
	UDN          string       `xml:"UDN"`
	Services     []xmlService `xml:"serviceList>service"`
	Devices      []xmlDevice  `xml:"deviceList>device"`
}

// Describe reads a device description and returns the MediaRenderer in it.
func Describe(ctx context.Context, location string) (Device, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, location, nil)
	if err != nil {
		return Device{}, err
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return Device{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Device{}, fmt.Errorf("description: %s", resp.Status)
	}
	var root struct {
		URLBase string    `xml:"URLBase"`
		Device  xmlDevice `xml:"device"`
	}
	if err := xml.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&root); err != nil {
		return Device{}, err
	}
	base, err := url.Parse(location)
	if err != nil {
		return Device{}, err
	}
	if root.URLBase != "" {
		if b, err := url.Parse(root.URLBase); err == nil {
			base = b
		}
	}
	xd, ok := findRenderer(root.Device)
	if !ok {
		return Device{}, errors.New("not a media renderer")
	}
	d := Device{
		UDN: xd.UDN, Name: strings.TrimSpace(xd.Name), Manufacturer: xd.Manufacturer, Model: xd.Model,
		Location: location, IP: base.Hostname(), Online: true,
	}
	for _, s := range xd.Services {
		u, err := base.Parse(s.ControlURL)
		if err != nil {
			continue
		}
		switch {
		case strings.HasPrefix(s.Type, "urn:schemas-upnp-org:service:AVTransport:"):
			d.avt = u.String()
		case strings.HasPrefix(s.Type, "urn:schemas-upnp-org:service:RenderingControl:"):
			d.rc = u.String()
		}
	}
	if d.avt == "" || d.UDN == "" {
		return Device{}, errors.New("renderer without AVTransport")
	}
	return d, nil
}

func findRenderer(d xmlDevice) (xmlDevice, bool) {
	if strings.HasPrefix(d.Type, "urn:schemas-upnp-org:device:MediaRenderer:") {
		return d, true
	}
	for _, c := range d.Devices {
		if r, ok := findRenderer(c); ok {
			return r, true
		}
	}
	return xmlDevice{}, false
}
