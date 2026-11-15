// Package upnp implements the UPnP AV MediaServer device: description, ContentDirectory and ConnectionManager.
package upnp

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
)

const (
	DeviceType = "urn:schemas-upnp-org:device:MediaServer:1"
	CDSType    = "urn:schemas-upnp-org:service:ContentDirectory:1"
	CMSType    = "urn:schemas-upnp-org:service:ConnectionManager:1"
	DescPath   = "/description.xml"
)

type Server struct {
	Name    string
	UUID    string
	Version string
	Cat     *library.Catalog
	icons   map[int][]byte
	cdsEv   *eventer
	cmsEv   *eventer
}

func New(name, uuid, version string, cat *library.Catalog) *Server {
	s := &Server{Name: name, UUID: uuid, Version: version, Cat: cat, icons: map[int][]byte{}}
	s.cdsEv = newEventer(func() [][2]string {
		return [][2]string{{"SystemUpdateID", s.updateID()}, {"ContainerUpdateIDs", ""}}
	})
	s.cmsEv = newEventer(func() [][2]string {
		return [][2]string{{"SourceProtocolInfo", dlna.SourceProtocolInfo()}, {"SinkProtocolInfo", ""}, {"CurrentConnectionIDs", "0"}}
	})
	for _, sz := range []int{48, 120} {
		s.icons[sz] = renderIcon(sz)
	}
	return s
}

// Register adds the UPnP endpoints to mux.
func (s *Server) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET "+DescPath, s.description)
	mux.HandleFunc("GET /cds.xml", xmlHandler(cdsSCPD))
	mux.HandleFunc("GET /cms.xml", xmlHandler(cmsSCPD))
	mux.HandleFunc("POST /cds/control", s.control(CDSType, s.cdsAction))
	mux.HandleFunc("POST /cms/control", s.control(CMSType, s.cmsAction))
	mux.HandleFunc("/cds/event", s.cdsEv.handle)
	mux.HandleFunc("/cms/event", s.cmsEv.handle)
	mux.HandleFunc("GET /icon/{size}", s.icon)
}

func (s *Server) description(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
	fmt.Fprintf(w, deviceXML, esc(s.Name), esc(s.Version), s.UUID)
}

func xmlHandler(body string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
		io.WriteString(w, body)
	}
}

func (s *Server) icon(w http.ResponseWriter, r *http.Request) {
	size, _ := strconv.Atoi(strings.TrimSuffix(r.PathValue("size"), ".png"))
	b, ok := s.icons[size]
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Write(b)
}

// NotifyChange tells subscribed clients that the library changed.
func (s *Server) NotifyChange() { s.cdsEv.notifyAll() }

func (s *Server) updateID() string {
	return strconv.FormatUint(uint64(s.Cat.UpdateID(context.Background())), 10)
}

// --- SOAP ---

type upnpError struct {
	code int
	desc string
}

func (e *upnpError) Error() string { return e.desc }

var (
	errInvalidAction = &upnpError{401, "Invalid Action"}
	errInvalidArgs   = &upnpError{402, "Invalid Args"}
	errNoSuchObject  = &upnpError{701, "No such object"}
)

type arg struct{ name, value string }

type actionFunc func(r *http.Request, action string, in map[string]string) ([]arg, error)

type soapEnvelope struct {
	Body struct {
		Action struct {
			XMLName xml.Name
			Args    []struct {
				XMLName xml.Name
				Value   string `xml:",chardata"`
			} `xml:",any"`
		} `xml:",any"`
	} `xml:"Body"`
}

func (s *Server) control(serviceType string, fn actionFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var env soapEnvelope
		if err := xml.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&env); err != nil {
			writeFault(w, errInvalidArgs)
			return
		}
		action := env.Body.Action.XMLName.Local
		if sa := strings.Trim(r.Header.Get("SOAPAction"), `"`); sa != "" {
			if _, a, ok := strings.Cut(sa, "#"); ok {
				action = a
			}
		}
		in := map[string]string{}
		for _, a := range env.Body.Action.Args {
			in[a.XMLName.Local] = a.Value
		}
		out, err := fn(r, action, in)
		if err != nil {
			var ue *upnpError
			if !errors.As(err, &ue) {
				ue = &upnpError{501, "Action Failed"}
			}
			slog.Debug("soap fault", "action", action, "code", ue.code, "remote", r.RemoteAddr)
			writeFault(w, ue)
			return
		}
		var b strings.Builder
		b.WriteString(`<?xml version="1.0" encoding="utf-8"?>`)
		b.WriteString(`<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`)
		b.WriteString(`<u:` + action + `Response xmlns:u="` + serviceType + `">`)
		for _, a := range out {
			b.WriteString("<" + a.name + ">" + esc(a.value) + "</" + a.name + ">")
		}
		b.WriteString(`</u:` + action + `Response></s:Body></s:Envelope>`)
		w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
		w.Header().Set("EXT", "")
		io.WriteString(w, b.String())
	}
}

func writeFault(w http.ResponseWriter, e *upnpError) {
	w.Header().Set("Content-Type", `text/xml; charset="utf-8"`)
	w.WriteHeader(http.StatusInternalServerError)
	fmt.Fprintf(w, `<?xml version="1.0" encoding="utf-8"?>`+
		`<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`+
		`<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>`+
		`<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>%d</errorCode><errorDescription>%s</errorDescription></UPnPError>`+
		`</detail></s:Fault></s:Body></s:Envelope>`, e.code, esc(e.desc))
}

// --- ContentDirectory ---

func (s *Server) cdsAction(r *http.Request, action string, in map[string]string) ([]arg, error) {
	switch action {
	case "Browse":
		return s.browse(r, in)
	case "GetSearchCapabilities":
		return []arg{{"SearchCaps", ""}}, nil
	case "GetSortCapabilities":
		return []arg{{"SortCaps", "dc:title"}}, nil
	case "GetSystemUpdateID":
		return []arg{{"Id", s.updateID()}}, nil
	}
	return nil, errInvalidAction
}

func (s *Server) browse(r *http.Request, in map[string]string) ([]arg, error) {
	id := in["ObjectID"]
	start, err1 := atoiDefault(in["StartingIndex"])
	count, err2 := atoiDefault(in["RequestedCount"])
	if err1 != nil || err2 != nil || start < 0 || count < 0 {
		return nil, errInvalidArgs
	}
	var objs []library.Object
	total := 0
	switch in["BrowseFlag"] {
	case "BrowseMetadata":
		o, err := s.Cat.Metadata(r.Context(), id)
		if err != nil {
			return nil, errNoSuchObject
		}
		objs, total = []library.Object{o}, 1
	case "BrowseDirectChildren":
		var err error
		objs, total, err = s.Cat.Children(r.Context(), id, start, count)
		if errors.Is(err, library.ErrNotFound) {
			return nil, errNoSuchObject
		}
		if err != nil {
			slog.Error("browse", "id", id, "err", err)
			return nil, &upnpError{501, "Action Failed"}
		}
	default:
		return nil, errInvalidArgs
	}
	return []arg{
		{"Result", DIDL(objs, "http://"+r.Host)},
		{"NumberReturned", strconv.Itoa(len(objs))},
		{"TotalMatches", strconv.Itoa(total)},
		{"UpdateID", s.updateID()},
	}, nil
}

func atoiDefault(s string) (int, error) {
	if s = strings.TrimSpace(s); s == "" {
		return 0, nil
	}
	return strconv.Atoi(s)
}

// --- ConnectionManager ---

func (s *Server) cmsAction(_ *http.Request, action string, in map[string]string) ([]arg, error) {
	switch action {
	case "GetProtocolInfo":
		return []arg{{"Source", dlna.SourceProtocolInfo()}, {"Sink", ""}}, nil
	case "GetCurrentConnectionIDs":
		return []arg{{"ConnectionIDs", "0"}}, nil
	case "GetCurrentConnectionInfo":
		if in["ConnectionID"] != "0" {
			return nil, &upnpError{706, "Invalid connection reference"}
		}
		return []arg{
			{"RcsID", "-1"}, {"AVTransportID", "-1"}, {"ProtocolInfo", ""},
			{"PeerConnectionManager", ""}, {"PeerConnectionID", "-1"},
			{"Direction", "Output"}, {"Status", "OK"},
		}, nil
	}
	return nil, errInvalidAction
}

// renderIcon draws a simple play symbol on a dark rounded tile.
func renderIcon(size int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	bg := color.NRGBA{0x1f, 0x29, 0x37, 0xff}
	fg := color.NRGBA{0xf5, 0x9e, 0x0b, 0xff}
	r := float64(size) / 6
	f := float64(size)
	for y := range size {
		for x := range size {
			px, py := float64(x)+0.5, float64(y)+0.5
			// Rounded corners.
			cx, cy := max(r-px, 0, px-(f-r)), max(r-py, 0, py-(f-r))
			if cx*cx+cy*cy > r*r {
				continue
			}
			img.Set(x, y, bg)
			// Triangle pointing right, centred.
			l, rt, top, bot := f*0.36, f*0.72, f*0.26, f*0.74
			if px >= l && px <= rt {
				half := (bot - top) / 2 * (1 - (px-l)/(rt-l))
				if py >= f/2-half && py <= f/2+half {
					img.Set(x, y, fg)
				}
			}
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}
