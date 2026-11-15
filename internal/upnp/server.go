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
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/transcode"
)

const (
	DeviceType = "urn:schemas-upnp-org:device:MediaServer:1"
	CDSType    = "urn:schemas-upnp-org:service:ContentDirectory:1"
	CMSType    = "urn:schemas-upnp-org:service:ConnectionManager:1"
	DescPath   = "/description.xml"
)

type Server struct {
	// DTS and CanTranscode feed the per-client playback decision.
	DTS          bool
	CanTranscode bool

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
	for _, sz := range []int{48, 120, 256} {
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

func (s *Server) renderOpts(r *http.Request) RenderOpts {
	return RenderOpts{Profile: transcode.Detect(r.UserAgent(), s.DTS), Transcode: s.CanTranscode}
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
		{"Result", DIDL(objs, "http://"+r.Host, s.renderOpts(r))},
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

// renderIcon draws the app icon (see assets/icon.svg): orange gradient tile, play symbol and cast waves.
// Rendered at runtime so the binary needs no image assets; 4×4 supersampling for smooth edges.
func renderIcon(size int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	const ss = 4
	scale := 1024 / float64(size*ss)
	for y := range size {
		for x := range size {
			var r, g, b, a float64
			for sy := range ss {
				for sx := range ss {
					u := (float64(x*ss+sx) + 0.5) * scale
					v := (float64(y*ss+sy) + 0.5) * scale
					if !inRoundRect(u, v, 1024, 230) {
						continue
					}
					cr, cg, cb := iconBackground(u, v)
					if w := iconForeground(u, v); w > 0 {
						cr, cg, cb = cr+(1-cr)*w, cg+(1-cg)*w, cb+(1-cb)*w
					}
					r, g, b, a = r+cr, g+cg, b+cb, a+1
				}
			}
			if a == 0 {
				continue
			}
			img.SetNRGBA(x, y, color.NRGBA{uint8(r / a * 255), uint8(g / a * 255), uint8(b / a * 255), uint8(a / (ss * ss) * 255)})
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func inRoundRect(u, v, size, rad float64) bool {
	dx := max(rad-u, 0, u-(size-rad))
	dy := max(rad-v, 0, v-(size-rad))
	return dx*dx+dy*dy <= rad*rad
}

// iconBackground is the diagonal gradient #FFB020 → #FF7A00 → #F0441C with a soft top-left glow.
func iconBackground(u, v float64) (r, g, b float64) {
	stops := [][4]float64{{0, 0xFF, 0xB0, 0x20}, {0.55, 0xFF, 0x7A, 0x00}, {1, 0xF0, 0x44, 0x1C}}
	t := (u + v) / 2048
	for i := 1; i < len(stops); i++ {
		if t <= stops[i][0] || i == len(stops)-1 {
			p, q := stops[i-1], stops[i]
			f := min(max((t-p[0])/(q[0]-p[0]), 0), 1)
			r, g, b = (p[1]+(q[1]-p[1])*f)/255, (p[2]+(q[2]-p[2])*f)/255, (p[3]+(q[3]-p[3])*f)/255
			break
		}
	}
	d := math.Hypot(u-307, v-205)
	if glow := 0.28 * (1 - d/768); glow > 0 {
		r, g, b = r+(1-r)*glow, g+(1-g)*glow, b+(1-b)*glow
	}
	return
}

// iconForeground returns white coverage: rounded play triangle and two cast arcs (outer one 60 %).
func iconForeground(u, v float64) float64 {
	tri := [3][2]float64{{251, 307}, {251, 717}, {538, 512}}
	if inTriangle(u, v, tri) || distToTriangle(u, v, tri) <= 22 {
		return 1
	}
	const cx, cy = 345.0, 512.0
	for i, rad := range []float64{297, 397} {
		d := math.Hypot(u-cx, v-cy)
		ang := math.Atan2(v-cy, u-cx)
		onArc := math.Abs(d-rad) <= 28 && math.Abs(ang) <= math.Pi/4
		e := rad * math.Sqrt2 / 2
		caps := math.Hypot(u-(cx+e), v-(cy-e)) <= 28 || math.Hypot(u-(cx+e), v-(cy+e)) <= 28
		if onArc || caps {
			return []float64{1, 0.6}[i]
		}
	}
	return 0
}

func inTriangle(u, v float64, t [3][2]float64) bool {
	sign := func(a, b [2]float64) float64 { return (u-b[0])*(a[1]-b[1]) - (a[0]-b[0])*(v-b[1]) }
	d1, d2, d3 := sign(t[0], t[1]), sign(t[1], t[2]), sign(t[2], t[0])
	neg := d1 < 0 || d2 < 0 || d3 < 0
	pos := d1 > 0 || d2 > 0 || d3 > 0
	return !(neg && pos)
}

func distToTriangle(u, v float64, t [3][2]float64) float64 {
	best := math.MaxFloat64
	for i := range 3 {
		a, b := t[i], t[(i+1)%3]
		dx, dy := b[0]-a[0], b[1]-a[1]
		f := min(max(((u-a[0])*dx+(v-a[1])*dy)/(dx*dx+dy*dy), 0), 1)
		best = min(best, math.Hypot(u-(a[0]+f*dx), v-(a[1]+f*dy)))
	}
	return best
}
