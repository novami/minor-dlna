package renderer

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// SOAPError is a UPnP fault returned by the renderer.
type SOAPError struct {
	Code int
	Desc string
}

func (e *SOAPError) Error() string { return fmt.Sprintf("upnp error %d: %s", e.Code, e.Desc) }

// LG answers these only once playback starts or the seek lands, which takes well over 10 s for a big file.
var (
	slowActions = map[string]bool{"SetAVTransportURI": true, "Play": true, "Seek": true}
	slowClient  = &http.Client{Timeout: 60 * time.Second}
)

// call invokes action on a UPnP service and returns the output arguments.
func call(ctx context.Context, controlURL, service, action string, args [][2]string) (map[string]string, error) {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`)
	b.WriteString(`<u:` + action + ` xmlns:u="` + service + `">`)
	for _, a := range args {
		b.WriteString("<" + a[0] + ">")
		_ = xml.EscapeText(&b, []byte(a[1]))
		b.WriteString("</" + a[0] + ">")
	}
	b.WriteString(`</u:` + action + `></s:Body></s:Envelope>`)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, controlURL, strings.NewReader(b.String()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	req.Header.Set("SOAPAction", `"`+service+"#"+action+`"`)
	client := httpClient
	if slowActions[action] {
		client = slowClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", action, err)
	}
	defer resp.Body.Close()
	out, fault, err := parseResponse(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("%s: %s: %w", action, resp.Status, err)
	}
	if fault != nil {
		return nil, fault
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", action, resp.Status)
	}
	return out, nil
}

// parseResponse collects the leaf elements of the body: output arguments, or errorCode/errorDescription of a fault.
func parseResponse(r io.Reader) (map[string]string, *SOAPError, error) {
	dec := xml.NewDecoder(r)
	out := map[string]string{}
	var name string
	var text strings.Builder
	isFault := false
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, nil, err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			if t.Name.Local == "Fault" {
				isFault = true
			}
			name = t.Name.Local
			text.Reset()
		case xml.CharData:
			text.Write(t)
		case xml.EndElement:
			if name == t.Name.Local {
				out[name] = text.String()
			}
			name = ""
		}
	}
	if isFault {
		e := &SOAPError{Desc: out["errorDescription"]}
		fmt.Sscan(out["errorCode"], &e.Code)
		if e.Desc == "" {
			e.Desc = out["faultstring"]
		}
		return nil, e, nil
	}
	return out, nil, nil
}
